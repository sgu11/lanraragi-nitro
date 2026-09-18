package LANraragi::Utils::AdaptiveOffsetClient;

use v5.36;
use strict;
use warnings;
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::JSON qw(encode_json decode_json);
use Digest::SHA qw(sha256_hex);
use Scalar::Util qw(looks_like_number);
use POSIX qw(isfinite);
use LANraragi::Utils::AdaptiveOffsetVote;

# Transport only. Callers own acquisition, sampling/slots, revision checks,
# manual corrections and archive/chapter boundaries. No silent legacy fallback.
sub new ($class, $base_url, $ua = undef) {
    my $url = Mojo::URL->new($base_url // '');
    die "invalid_worker_url\n" unless ($url->scheme // '') =~ /\Ahttps?\z/ && $url->host
      && !length($url->userinfo // '') && !length($url->fragment // '') && !length($url->query->to_string);
    $ua //= Mojo::UserAgent->new;
    $ua->max_redirects(0)->connect_timeout(2)->request_timeout(20)->max_response_size(1024 * 1024);
    $ua->proxy->not(['*']);
    return bless {url => "$url" =~ s{/+$}{}r, ua => $ua}, $class;
}

sub _request ($self, $path, $revision, $key, $payload, $pages = undef) {
    die "invalid_content_revision\n" unless $revision =~ /\A[0-9a-f]{64}\z/;
    my $metadata = encode_json({schema_version => 1, content_revision => $revision, $key => $payload});
    die "worker_metadata_limit\n" if length($metadata) > 65536;
    my $raw = $metadata;
    my $type = 'application/json';
    if ($pages) {
        my $size = 8 + length($metadata);
        $size += length($_->{bytes}) for @$pages;
        die "worker_body_limit\n" if $size > 48 * 1024 * 1024;
        $raw = 'AOW1' . pack('N', length($metadata)) . $metadata . join('', map { $_->{bytes} } @$pages);
        $type = 'application/vnd.adaptive-offset.pages-v1';
    }
    my $tx = $self->{ua}->post($self->{url} . $path => {'Content-Type' => $type} => $raw);
    die "worker_unavailable\n" if $tx->error || !$tx->res->is_success;
    my $result = eval { decode_json($tx->res->body) };
    die "invalid_worker_response\n" unless ref($result) eq 'HASH' && ($result->{schema_version} // 0) == 1
      && ($result->{algorithm_version} // '') eq LANraragi::Utils::AdaptiveOffsetVote::ALGORITHM_VERSION
      && ($result->{content_revision} // '') eq $revision && ($result->{request_sha256} // '') eq sha256_hex($metadata)
      && ref($result->{$key}) eq 'ARRAY';
    return $result->{$key};
}

sub _score ($value, $max = 1) {
    return defined $value && !ref($value) && looks_like_number($value) && isfinite($value) && $value >= 0 && $value <= $max;
}

sub detect_pages ($self, $pages, $revision) {
    die "invalid_pages\n" unless ref($pages) eq 'ARRAY' && @$pages && @$pages <= 12;
    my %expected;
    my @input;
    for my $page (@$pages) {
        my ($index, $bytes) = @{$page}{qw(index bytes)};
        die "invalid_page\n" unless defined $index && "$index" =~ /\A(?:0|[1-9][0-9]*)\z/
          && $index <= 1_000_000 && !exists $expected{$index} && defined $bytes && length($bytes) && length($bytes) <= 8 * 1024 * 1024;
        $expected{$index} = sha256_hex($bytes);
        push @input, {index => 0 + $index, sha256 => $expected{$index}, bytes_count => length($bytes)};
    }
    my $result = $self->_request('/v1/pages', $revision, 'pages', \@input, $pages);
    die "incomplete_worker_pages\n" unless @$result == @$pages;
    my %seen;
    for my $page (@$result) {
        die "invalid_worker_page\n" unless ref($page) eq 'HASH';
        my $index = $page->{page_index};
        die "stale_worker_page\n" unless defined $index && exists $expected{$index} && !$seen{$index}++
          && ($page->{sha256} // '') eq $expected{$index};
        die "invalid_worker_evidence\n" unless ($page->{side} // '') =~ /\A(?:LEFT|RIGHT|UNKNOWN)\z/
          && _score($page->{confidence}) && ($page->{reason} // '') =~ /\A(?:edge_complexity|wide_page|weak_edge_delta)\z/
          && _score($page->{source_width}, 100_000_000) && $page->{source_width} > 0
          && _score($page->{source_height}, 100_000_000) && $page->{source_height} > 0;
    }
    return $result;
}

sub vote_groups ($self, $groups, $revision) {
    my $result = $self->_request('/v1/vote', $revision, 'groups', $groups);
    my %expected = map { $_->{id} => {map { $_->{index} => 1 } @{$_->{observations}}} } @$groups;
    die "incomplete_worker_votes\n" unless @$result == @$groups;
    my %seen;
    for my $group (@$result) {
        my $id = $group->{id} // '';
        die "invalid_worker_vote\n" unless exists $expected{$id} && !$seen{$id}++
          && ($group->{side} // '') =~ /\A(?:LEFT|RIGHT|UNKNOWN)\z/ && _score($group->{relative_gap})
          && ref($group->{vote_scores}) eq 'HASH' && _score($group->{vote_scores}{LEFT}, 12) && _score($group->{vote_scores}{RIGHT}, 12)
          && !$group->{confidence_calibrated} && ref($group->{evidence_indices}) eq 'ARRAY';
        my %used;
        die "invalid_worker_vote_evidence\n" if grep { !$expected{$id}{$_} || $used{$_}++ } @{$group->{evidence_indices}};
    }
    return $result;
}

1;
