package LANraragi::Controller::Api::Coverduplicates;
use Mojo::Base 'Mojolicious::Controller';

use Mojo::JSON qw(decode_json encode_json);
use LANraragi::Model::Config;
use LANraragi::Model::Dedup::CoverIndex;
use LANraragi::Model::Dedup::ReviewLog;

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
        max_score => ($req->param('max_score')
            // $req->param('threshold')
            // LANraragi::Model::Dedup::CoverIndex::DEFAULT_COVER_MAX_HAMMING()) + 0,
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

sub review_events {
    my $self = shift;
    my $req  = $self->req;

    my $opts = {
        offset => ($req->param('offset') // 0) + 0,
        limit  => ($req->param('limit')  // 1000) + 0,
    };

    my $redis_cfg = _get_redis_config();
    my $result = LANraragi::Model::Dedup::ReviewLog::review_events($redis_cfg, $opts);
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
    my $redis     = _get_redis();
    my $existing = eval { decode_json($redis_cfg->hget("LRR_COVER_DUPLICATE_PAIR_META", $pair) // '{}') } // {};
    $existing = {} unless ref $existing eq 'HASH';
    my $previous_status = $existing->{status} // 'new';
    $existing->{status} = $status;
    $redis_cfg->hset("LRR_COVER_DUPLICATE_PAIR_META", $pair, encode_json($existing));

    my $event;
    my $log_error;
    eval {
        $event = LANraragi::Model::Dedup::ReviewLog::record_cover_decision(
            $redis_cfg,
            $redis,
            {
                pair => $pair,
                action_type => 'mark_status',
                label => $status,
                previous_status => $previous_status,
                new_status => $status,
                context => $body->{context},
                visible_snapshot => $body->{visible_snapshot},
            }
        );
        1;
    } or $log_error = $@ || 'unknown error';

    $redis->quit;
    $redis_cfg->quit;

    if ($log_error) {
        chomp $log_error;
        # Status write already committed — do not imply full failure/rollback.
        # Clients advance the review queue; event logging is best-effort.
        return $self->render(
            status => 200,
            json => {
                success => \1,
                event_logged => \0,
                warning => "status updated but review event logging failed: $log_error",
                pair => $pair,
                status => $status,
            }
        );
    }

    $self->render(json => {
        success => \1,
        event_logged => \1,
        pair => $pair,
        status => $status,
        event_id => $event->{event_id},
    });
}

1;
