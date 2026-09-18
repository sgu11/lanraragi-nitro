package LANraragi::Utils::AdaptiveOffsetState;

use v5.36;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Mojo::JSON qw(encode_json decode_json);
use List::Util qw(min);
use Time::HiRes ();
use LANraragi::Model::Config;
use LANraragi::Utils::Archive qw(extract_single_file get_filelist);
use LANraragi::Utils::Path qw(get_archive_path);
use LANraragi::Utils::RedisScript qw(evalsha_cached release_owned_lease);
use LANraragi::Utils::AdaptiveOffsetClient;
use LANraragi::Utils::AdaptiveOffsetAdapter;
use LANraragi::Utils::AdaptiveOffsetVote;

# App-owned acquisition and ephemeral cache. Never overwrite legacy/manual
# archive fields and never carry an anchor into another archive.
sub enabled () { return length($ENV{ADAPTIVE_OFFSET_WORKER_URL} // '') > 0; }

sub _signature ($file) {
    my @stat = Time::HiRes::stat($file);
    die "archive_unavailable\n" unless @stat;
    return join(':', @stat[0, 1, 7, 9, 10]);
}

sub _identity ($redis, $id) {
    die "invalid_archive_id\n" unless $id =~ /\A[0-9a-f]{40}\z/ && $redis->exists($id);
    my ($file_field, $revision, $page_count) = $redis->hmget($id, qw(file firstspreadstart_revision pagecount));
    my $file = get_archive_path($redis, $id);
    my $signature = _signature($file);
    my $hash = sha256_hex(encode_json([$id, $file_field, $revision // '0', $page_count // '0', $signature,
        LANraragi::Utils::AdaptiveOffsetVote::ALGORITHM_VERSION]));
    return {id => $id, file => $file, file_field => $file_field // '', revision => $revision // '0',
        signature => $signature, page_count => $page_count // '0', hash => $hash, key => "LRR_ADAPTIVE_OFFSET:$id:$hash"};
}

sub _resolved ($redis, $identity, $raw) {
    my ($reason, $value, $revision, $file, $count) = $redis->hmget($identity->{id},
        qw(firstspreadstart_reason firstspreadstart firstspreadstart_revision file pagecount));
    die "stale_archive\n" unless ($revision // '0') eq $identity->{revision} && ($file // '') eq $identity->{file_field}
      && ($count // '0') eq $identity->{page_count};
    return {%$raw, archiveId => $identity->{id}, contentRevision => $identity->{hash},
        first_spread_start => ($reason // '') eq 'user_slide' ? $value : ($raw->{first_spread_start} // 'UNKNOWN'),
        provenance => ($reason // '') eq 'user_slide' ? 'user_slide' : 'detector'};
}

sub read_state ($redis, $id, $enqueue = 0) {
    return {status => 'disabled'} unless enabled();
    my $identity = _identity($redis, $id);
    if (my $cached = $redis->get($identity->{key})) {
        my $raw = decode_json($cached);
        die "invalid_worker_cache\n" unless ($raw->{contentRevision} // '') eq $identity->{hash};
        return _resolved($redis, $identity, $raw);
    }
    return _resolved($redis, $identity, {status => 'error'}) if $redis->exists("$identity->{key}:error");
    if ($enqueue && $redis->set("$identity->{key}:pending", $identity->{hash}, 'NX', 'EX', 90)) {
        eval { LANraragi::Model::Config->get_minion->enqueue(detect_first_spread_start => [$id] => {priority => 0}); };
        if ($@) {
            release_owned_lease($redis, "$identity->{key}:pending", $identity->{hash});
            die "detector_queue_unavailable\n";
        }
    }
    return _resolved($redis, $identity, {status => 'pending'});
}

sub _store ($redis, $identity, $result) {
    my $script = <<'LUA';
local id, revision, file, count, key, payload = unpack(ARGV)
if redis.call('EXISTS', id) == 0 then return 0 end
if (redis.call('HGET', id, 'firstspreadstart_revision') or '0') ~= revision then return 0 end
if (redis.call('HGET', id, 'file') or '') ~= file then return 0 end
if (redis.call('HGET', id, 'pagecount') or '0') ~= count then return 0 end
redis.call('SET', key, payload, 'EX', 1800)
redis.call('DEL', key .. ':pending', key .. ':error')
return 1
LUA
    return evalsha_cached($redis, 'store_shared_adaptive_offset', $script,
        @{$identity}{qw(id revision file_field page_count key)}, encode_json($result));
}

sub detect_and_store ($id) {
    die "worker_disabled\n" unless enabled();
    my $redis = LANraragi::Model::Config->get_redis;
    my ($identity, $result);
    eval {
        $identity = _identity($redis, $id);
        if (my $cached = $redis->get($identity->{key})) {
            $result = _resolved($redis, $identity, decode_json($cached));
        } else {
            my @files = get_filelist($identity->{file}, $id);
            die "archive_empty\n" unless @files;
            die "page_count_mismatch\n" if $identity->{page_count} > 0 && @files != $identity->{page_count};
            my $client = LANraragi::Utils::AdaptiveOffsetClient->new($ENV{ADAPTIVE_OFFSET_WORKER_URL});
            my (@pending, @evidence);
            my $size = 0;
            for my $index (0 .. min(11, $#files)) {
                my $bytes = extract_single_file($identity->{file}, $files[$index]);
                die "image_size_limit\n" unless defined $bytes && length($bytes) && length($bytes) <= 8 * 1024 * 1024;
                if ($size + length($bytes) > 48 * 1024 * 1024 - 65536 - 8) {
                    push @evidence, @{$client->detect_pages(\@pending, $identity->{hash})};
                    @pending = ();
                    $size = 0;
                }
                push @pending, {index => $index, bytes => $bytes};
                $size += length($bytes);
            }
            push @evidence, @{$client->detect_pages(\@pending, $identity->{hash})};
            $result = LANraragi::Utils::AdaptiveOffsetAdapter::vote_archive($client, \@evidence, $identity->{hash}, scalar @files);
            $result->{status} = 'ready';
            $result->{contentRevision} = $identity->{hash};
            $result->{algorithmVersion} = LANraragi::Utils::AdaptiveOffsetVote::ALGORITHM_VERSION;
            $result->{archiveId} = $id;
            $_->{archiveId} = $id for @{$result->{segments}};
            die "stale_archive\n" if _signature($identity->{file}) ne $identity->{signature};
            die "stale_archive\n" unless _store($redis, $identity, $result);
            $result = _resolved($redis, $identity, $result);
        }
    };
    if ($@) {
        my $stale = "$@" =~ /stale_archive/ ? 1 : 0;
        # Controlled failure only; no paths or input bytes in Minion/API output.
        $result = {status => 'error', error => $stale ? 'stale_archive' : 'worker_evidence_unavailable', stale => $stale};
        $redis->set("$identity->{key}:error", '1', 'EX', 10) if $identity && !$stale;
    }
    $redis->quit;
    return $result;
}

1;
