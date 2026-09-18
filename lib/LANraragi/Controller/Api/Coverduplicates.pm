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

    for my $field (qw(max_score threshold offset limit)) {
        my $value = $req->param($field);
        next unless defined $value;
        my $max = $field eq 'limit' ? 200 : $field eq 'offset' ? 1_000_000 : 64;
        my $min = $field eq 'limit' ? 1 : 0;
        return $self->render(status => 400, json => { error => "Invalid $field" })
            unless $value =~ /\A\d{1,7}\z/ && $value >= $min && $value <= $max;
    }
    my $status = $req->param('status') // 'new';
    return $self->render(status => 400, json => { error => 'Invalid status' })
        unless $status =~ /\A(?:all|new|same_cover|variant|not_duplicate|needs_review|resolved)\z/;

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
    return $self->render(status => 400, json => { error => 'Expected a JSON object' }) unless ref $body eq 'HASH';
    my $pair = LANraragi::Model::Dedup::ReviewLog::canonical_pair($body->{pair});

    unless (defined $pair) {
        return $self->render(status => 400, json => { error => "pair must be 'idA|idB' lowercase hex" });
    }

    return $self->render(status => 409, json => { error => 'Pair changed; reload the review queue' })
        unless defined $body->{generation} && !ref $body->{generation} && length($body->{generation});
    my $redis_cfg = _get_redis_config();
    my $deleted = LANraragi::Model::Dedup::CoverIndex::delete_cover_pair($redis_cfg, $pair, $body->{generation});
    unless ($deleted) {
        my $exists = defined $redis_cfg->zscore(LANraragi::Model::Dedup::CoverIndex::PAIR_KEY(), $pair);
        $redis_cfg->quit;
        return $self->render(status => $exists ? 409 : 404,
            json => { error => $exists ? 'Pair changed; reload the review queue' : 'Pair is no longer available' });
    }
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
    return $self->render(status => 400, json => { error => 'Invalid threshold' })
        if defined $threshold && ($threshold !~ /\A\d{1,2}\z/ || $threshold > 64);
    $threshold = defined $threshold ? $threshold + 0 : undef;
    my $retry_failed = $req->param('retry_failed') // '0';
    return $self->render(status => 400, json => { error => 'Invalid retry_failed' })
        unless $retry_failed =~ /\A[01]\z/;

    # Queue the isolated cover find Minion job.
    my $minion = LANraragi::Model::Config->get_minion;
    my @args = ($threshold);
    push @args, 1 if $retry_failed;
    my $job_id = $minion->enqueue(find_cover_duplicates_isolated => \@args => { priority => 0 });
    return $self->render(status => 503, json => { error => 'Could not queue cover scan' }) unless $job_id;

    $self->render(json => {
        success => \1,
        job     => $job_id,
    });
}

sub verify {
    my $self = shift;
    my $body = $self->req->json;
    return $self->render(status => 400, json => { error => 'Expected 1 to 24 pairs' })
        unless ref $body eq 'HASH' && ref $body->{pairs} eq 'ARRAY'
            && @{$body->{pairs}} && @{$body->{pairs}} <= 24;
    my %seen;
    my @pairs;
    for my $raw (@{$body->{pairs}}) {
        my $pair = LANraragi::Model::Dedup::ReviewLog::canonical_pair($raw);
        return $self->render(status => 400, json => { error => 'Invalid pair' }) unless defined $pair;
        push @pairs, $pair unless $seen{$pair}++;
    }
    my $job = LANraragi::Model::Config->get_minion->enqueue(
        verify_cover_duplicates => [\@pairs] => { priority => 0 }
    );
    return $self->render(status => 503, json => { error => 'Could not queue verification' }) unless $job;
    $self->render(json => { success => \1, job => $job });
}

# Update review status for a cover pair.
sub update_status {
    my $self = shift;
    my $body = $self->req->json // {};
    return $self->render(status => 400, json => { error => 'Expected a JSON object' }) unless ref $body eq 'HASH';
    my $pair = LANraragi::Model::Dedup::ReviewLog::canonical_pair($body->{pair});
    my $status = $body->{status} // '';

    unless (defined $pair) {
        return $self->render(status => 400, json => { error => "pair must be 'idA|idB' lowercase hex" });
    }
    unless ($status =~ /\A(?:new|same_cover|variant|not_duplicate|needs_review|resolved)\z/) {
        return $self->render(status => 400, json => { error => "invalid status" });
    }

    return $self->render(status => 409, json => { error => 'Pair changed; reload the review queue' })
        unless defined $body->{generation} && !ref $body->{generation} && length($body->{generation});
    my $redis_cfg = _get_redis_config();
    my $redis     = _get_redis();
    my $existing = LANraragi::Model::Dedup::CoverIndex::patch_pair_meta(
        $redis_cfg, $pair, { status => $status }, undef, $body->{generation});
    unless (defined $existing) {
        my $exists = defined $redis_cfg->zscore(LANraragi::Model::Dedup::CoverIndex::PAIR_KEY(), $pair);
        $redis->quit;
        $redis_cfg->quit;
        return $self->render(status => $exists ? 409 : 404,
            json => { error => $exists ? 'Pair changed; reload the review queue' : 'Pair is no longer available' });
    }
    my $previous_status = $existing->{status} // 'new';

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
