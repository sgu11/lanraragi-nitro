package LANraragi::Controller::Api::Duplicates;
use Mojo::Base 'Mojolicious::Controller';

use Mojo::JSON qw(decode_json);
use LANraragi::Utils::Redis qw(redis_decode);
use LANraragi::Utils::Database;

# Preset name -> server-side max_score cap.
my %PRESETS = (
    strict     => 12,
    medium     => 25,
    loose      => 40,
    very_loose => 55,
);

# Indirection seams for tests.
sub _get_redis        { LANraragi::Model::Config->get_redis }
sub _get_redis_config { LANraragi::Model::Config->get_redis_config }

sub pairs {
    my $self = shift;
    my $req  = $self->req;

    my $max_score = $req->param('max_score');
    my $preset    = $req->param('preset');
    my $offset    = ($req->param('offset') // 0) + 0;
    my $limit     = ($req->param('limit')  // 50) + 0;
    $limit = 200 if $limit > 200;

    # Explicit max_score overrides preset (REST convention).
    my $cap;
    if (defined $max_score && length $max_score) {
        $cap = $max_score + 0;
    } elsif (defined $preset && exists $PRESETS{$preset}) {
        $cap = $PRESETS{$preset};
    } else {
        $cap = $PRESETS{medium};
    }

    my $redis_cfg = _get_redis_config();
    my $redis     = _get_redis();

    my @raw = $redis_cfg->zrangebyscore("LRR_DUPLICATE_PAIRS", 0, $cap, "WITHSCORES", "LIMIT", $offset, $limit);
    my $total = $redis_cfg->zcount("LRR_DUPLICATE_PAIRS", 0, $cap) + 0;

    my @pairs;
    while (@raw) {
        my $member = shift @raw;
        my $score  = shift @raw;
        my ($id_a, $id_b) = split /\|/, $member, 2;
        my $meta_json = $redis_cfg->hget("LRR_DUPLICATE_PAIR_META", $member) // '{}';
        my $meta      = eval { decode_json($meta_json) } // {};

        push @pairs, {
            id_a             => $id_a,
            id_b             => $id_b,
            score            => $score + 0,
            per_page         => $meta->{per_page} // [],
            page_count_delta => $meta->{pcount_delta} // 0,
            a                => _archive_brief($redis, $id_a),
            b                => _archive_brief($redis, $id_b),
        };
    }

    $redis->quit;
    $redis_cfg->quit;

    $self->render(json => { pairs => \@pairs, total => $total });
}

sub _archive_brief {
    my ($redis, $id) = @_;
    my %h = $redis->hgetall($id);
    return {} unless %h;
    my $tags  = redis_decode($h{tags} // '');
    my $tag_count = 0;
    my $language  = '';
    my $date_added = '';
    if (length $tags) {
        my @parts = grep { /\S/ } split /,/, $tags;
        $tag_count = scalar @parts;
        for my $t (@parts) {
            $t =~ s/^\s+|\s+$//g;
            if    ($t =~ /^language:\s*(.+)$/i)   { $language   = $1 unless length $language }
            elsif ($t =~ /^date_added:\s*(.+)$/i) { $date_added = $1 unless length $date_added }
        }
    }
    return {
        arcid      => $id,
        title      => redis_decode($h{title} // ''),
        name       => redis_decode($h{name}  // ''),
        tags       => $tags,
        pagecount  => ($h{pagecount} // 0) + 0,
        arcsize    => ($h{arcsize}   // 0) + 0,
        tag_count  => $tag_count,
        language   => $language,
        date_added => $date_added,
    };
}

sub delete_pair {
    my $self = shift;
    my $body = $self->req->json // {};
    my $pair = $body->{pair} // '';

    unless ($pair =~ /\A[0-9a-f]{40}\|[0-9a-f]{40}\z/) {
        return $self->render(status => 400, json => { error => "pair must be 'idA|idB' lowercase hex" });
    }

    my $redis_cfg = _get_redis_config();
    $redis_cfg->sadd("LRR_DEDUP_DISMISSED",     $pair);
    $redis_cfg->zrem("LRR_DUPLICATE_PAIRS",     $pair);
    $redis_cfg->hdel("LRR_DUPLICATE_PAIR_META", $pair);
    $redis_cfg->quit;

    $self->render(json => { dismissed => \1, pair => $pair });
}

sub stats {
    my $self = shift;
    my $redis_cfg = _get_redis_config();
    my $redis     = _get_redis();

    my $total_pairs   = $redis_cfg->zcard("LRR_DUPLICATE_PAIRS") + 0;
    my %config        = $redis_cfg->hgetall("LRR_DEDUP_CONFIG");
    my $last_scan_ts  = $redis_cfg->get("LRR_DEDUP_LAST_SCAN");
    my $algo_version  = ($config{algo_version} // 1) + 0;

    my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
    my $hashed  = 0;
    my $errored = 0;
    my $pending = 0;
    # Pipelined HMGET in one round-trip per archive instead of two
    # synchronous round-trips. On a 17k library this is ~30s vs ~3min.
    my @results;
    for my $id (@ids) {
        $redis->hmget($id, "pagehashes_v", "pagehashes_err",
            sub { push @results, $_[0] });
    }
    $redis->wait_all_responses;
    for my $reply (@results) {
        my ($v, $err) = @{ $reply // [] };
        $v   //= '';
        $err //= '';
        if ($v eq $algo_version) { $hashed++ }
        elsif ($err =~ /^\Q$algo_version\E:/) { $errored++ }
        else { $pending++ }
    }

    $redis->quit;
    $redis_cfg->quit;

    my $deck_target = 100;
    my $cursor_i    = ($config{pair_cursor_i} // 0) + 0;
    my $cursor_j    = ($config{pair_cursor_j} // 0) + 0;
    my $cursor_threshold = defined $config{pair_cursor_threshold}
        ? $config{pair_cursor_threshold} + 0
        : undef;
    my $sweep_done  = ($cursor_i == 0 && $cursor_j == 0) ? 1 : 0;

    $self->render(json => {
        total_pairs              => $total_pairs,
        deck_size                => $total_pairs,
        deck_target              => $deck_target,
        deck_full                => ($total_pairs >= $deck_target ? 1 : 0),
        cursor_i                 => $cursor_i,
        cursor_j                 => $cursor_j,
        cursor_threshold         => $cursor_threshold,
        sweep_done               => $sweep_done,
        archives_total           => scalar @ids,
        archives_with_hashes     => $hashed,
        archives_pending         => $pending,
        archives_errored         => $errored,
        last_scan_ts             => defined $last_scan_ts ? $last_scan_ts + 0 : 0,
        algo_version             => $algo_version,
        config => {
            algo_version         => $algo_version,
            pages_sampled        => ($config{pages_sampled}        // 5)  + 0,
            pcount_tolerance_pct => ($config{pcount_tolerance_pct} // 20) + 0,
            loose_max_score      => ($config{loose_max_score}      // 40) + 0,
            candidate_pair_cap   => ($config{candidate_pair_cap}   // 10_000_000) + 0,
        },
    });
}

1;
