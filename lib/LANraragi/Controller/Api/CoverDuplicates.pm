package LANraragi::Controller::Api::CoverDuplicates;
use Mojo::Base 'Mojolicious::Controller';

use Mojo::JSON qw(decode_json encode_json);
use LANraragi::Model::Config;
use LANraragi::Model::Dedup::CoverIndex;

# Indirection seams for tests.
sub _get_redis        { LANraragi::Model::Config->get_redis }
sub _get_redis_config { LANraragi::Model::Config->get_redis_config }

sub stats {
    my $self = shift;
    my $redis_cfg = _get_redis_config();
    my $redis     = _get_redis();

    my $s = LANraragi::Model::Dedup::CoverIndex::cover_stats($redis_cfg, $redis);
    $redis->quit;
    $redis_cfg->quit;
    $self->render(json => $s);
}

sub pairs {
    my $self = shift;
    my $req  = $self->req;

    my $opts = {
        max_score => ($req->param('max_score') // $req->param('threshold') // 25) + 0,
        offset    => ($req->param('offset')    // 0) + 0,
        limit     => ($req->param('limit')     // 100) + 0,
        status    => $req->param('status')     // 'new',
    };

    my $redis_cfg = _get_redis_config();
    my $redis     = _get_redis();

    my $result = LANraragi::Model::Dedup::CoverIndex::cover_pairs($redis_cfg, $redis, $opts);
    $redis->quit;
    $redis_cfg->quit;
    $self->render(json => $result);
}

sub delete_pair {
    my $self = shift;
    my $body = $self->req->json // {};
    my $pair = $body->{pair} // '';

    unless ($pair =~ /\A[0-9a-f]{40}\|[0-9a-f]{40}\z/) {
        return $self->render(status => 400, json => { error => "pair must be 'idA|idB' lowercase hex" });
    }

    my $redis_cfg = _get_redis_config();
    LANraragi::Model::Dedup::CoverIndex::delete_cover_pair($redis_cfg, $pair);
    $redis_cfg->quit;
    $self->render(json => { dismissed => \1, pair => $pair });
}

sub refresh {
    my $self = shift;
    my $redis_cfg = _get_redis_config();
    my $redis     = _get_redis();

    my $result = LANraragi::Model::Dedup::CoverIndex::refresh_cover_pairs($redis_cfg, $redis);
    $redis->quit;
    $redis_cfg->quit;
    $self->render(json => { success => \1, %$result });
}

sub rebuild {
    my $self = shift;
    my $req = $self->req;
    my $threshold = $req->param('threshold');
    $threshold = defined $threshold ? $threshold + 0 : undef;

    # Queue the isolated cover find Minion job.
    my $minion = LANraragi::Model::Config->get_minion;
    my $job_id = $minion->enqueue(
        find_cover_duplicates_isolated => [ $threshold ] => { priority => 0 }
    );

    $self->render(json => {
        success => \1,
        job     => $job_id,
    });
}

# Update review status for a cover pair.
sub update_status {
    my $self = shift;
    my $body = $self->req->json // {};
    my $pair   = $body->{pair}   // '';
    my $status = $body->{status} // '';

    unless ($pair =~ /\A[0-9a-f]{40}\|[0-9a-f]{40}\z/) {
        return $self->render(status => 400, json => { error => "pair must be 'idA|idB' lowercase hex" });
    }
    unless ($status =~ /\A(?:new|same_cover|variant|not_duplicate|needs_review|resolved)\z/) {
        return $self->render(status => 400, json => { error => "invalid status" });
    }

    my $redis_cfg = _get_redis_config();
    my $existing = eval { decode_json($redis_cfg->hget("LRR_COVER_DUPLICATE_PAIR_META", $pair) // '{}') } // {};
    $existing->{status} = $status;
    $redis_cfg->hset("LRR_COVER_DUPLICATE_PAIR_META", $pair, encode_json($existing));
    $redis_cfg->quit;
    $self->render(json => { success => \1, pair => $pair, status => $status });
}

1;
