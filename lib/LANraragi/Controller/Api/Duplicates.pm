package LANraragi::Controller::Api::Duplicates;
use Mojo::Base 'Mojolicious::Controller';

use Mojo::JSON qw(decode_json);
use LANraragi::Utils::Redis qw(redis_decode);

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
    return {
        arcid     => $id,
        title     => redis_decode($h{title} // ''),
        name      => redis_decode($h{name}  // ''),
        tags      => redis_decode($h{tags}  // ''),
        pagecount => ($h{pagecount} // 0) + 0,
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

1;
