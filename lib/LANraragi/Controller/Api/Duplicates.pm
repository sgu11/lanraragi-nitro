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
    my $relation  = $req->param('relation') // '';
    my $min_confidence = $req->param('min_confidence');
    # Review lifecycle filter. Default 'new' shows only unreviewed pairs; pairs
    # written before the status field existed have no status and count as new.
    # 'all' bypasses the filter.
    my $status = $req->param('status');
    $status = (defined $status && length $status) ? $status : 'new';
    $limit = 200 if $limit > 200;
    $min_confidence = defined $min_confidence && length $min_confidence ? $min_confidence + 0 : undef;

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

    my @raw = $redis_cfg->zrangebyscore("LRR_DUPLICATE_PAIRS", 0, $cap, "WITHSCORES");
    my $total = $redis_cfg->zcount("LRR_DUPLICATE_PAIRS", 0, $cap) + 0;

    # Collect pair members for batched meta fetches, then apply relation filters
    # before fetching archive briefs. The deck is intentionally small, so an
    # in-memory filter avoids under-filled pages when LIMIT is applied too early.
    my @raw_tuples;
    while (@raw) {
        my $member = shift @raw;
        my $score  = shift @raw;
        my ($id_a, $id_b) = split /\|/, $member, 2;
        push @raw_tuples, [$member, $score, $id_a, $id_b];
    }

    # Batched meta fetch: pipeline HMGET for all pair metas in one round-trip.
    my %meta_cache;
    if (@raw_tuples) {
        my @meta_results;
        for my $t (@raw_tuples) {
            $redis_cfg->hmget("LRR_DUPLICATE_PAIR_META", $t->[0],
                sub { push @meta_results, [ $t->[0], $_[0] ] });
        }
        $redis_cfg->wait_all_responses;
        for my $r (@meta_results) {
            my ($member, $reply) = @$r;
            my $json = ($reply && ref $reply eq 'ARRAY' && $reply->[0]) ? $reply->[0] : '{}';
            $meta_cache{$member} = eval { decode_json($json) } // {};
        }
    }

    my @filtered_tuples;
    for my $t (@raw_tuples) {
        my $meta = $meta_cache{$t->[0]} // {};
        next if $status ne 'all' && (($meta->{status} // 'new') ne $status);
        next if length($relation) && ($meta->{relation} // '') ne $relation;
        next if defined($min_confidence) && (($meta->{confidence} // 0) + 0) < $min_confidence;
        push @filtered_tuples, $t;
    }
    my $filtered_total = scalar @filtered_tuples;
    my @pair_tuples = splice @filtered_tuples, $offset, $limit;

    my %seen_ids;
    for my $t (@pair_tuples) {
        $seen_ids{$t->[2]} = 1;
        $seen_ids{$t->[3]} = 1;
    }

    # Batched archive brief: pipeline HMGET for all archive fields in one round-trip.
    my %brief_cache;
    my @brief_fields = qw(title name tags pagecount arcsize);
    {
        my @brief_results;
        for my $id (keys %seen_ids) {
            $redis->hmget($id, @brief_fields,
                sub { push @brief_results, [ $id, $_[0] ] });
        }
        $redis->wait_all_responses;
        for my $r (@brief_results) {
            my ($id, $reply) = @$r;
            my @vals = @{ $reply // [] };
            my %h;
            for my $i (0 .. $#brief_fields) {
                $h{$brief_fields[$i]} = $vals[$i] // '';
            }
            $brief_cache{$id} = _archive_brief_from_hash($id, \%h);
        }
    }

    my @pairs;
    for my $t (@pair_tuples) {
        my ($member, $score, $id_a, $id_b) = @$t;
        my $meta = $meta_cache{$member} // {};

        push @pairs, {
            id_a             => $id_a,
            id_b             => $id_b,
            score            => $score + 0,
            pass             => $meta->{pass} // 'pcount',
            relation         => $meta->{relation},
            confidence       => $meta->{confidence},
            suggested_action => $meta->{suggested_action},
            suggested_delete => $meta->{suggested_delete},
            suggested_keep   => $meta->{suggested_keep},
            risk_flags       => $meta->{risk_flags} // [],
            lead_hamming     => $meta->{lead_hamming},
            title_score      => $meta->{title_score},
            tag_score        => $meta->{tag_score},
            page_ratio       => $meta->{page_ratio},
            quality_ratio    => $meta->{quality_ratio},
            per_page         => $meta->{per_page} // [],
            page_count_delta => $meta->{pcount_delta} // 0,
            cover_hamming    => $meta->{cover_hamming},
            a                => $brief_cache{$id_a}  // {},
            b                => $brief_cache{$id_b}  // {},
        };
    }

    $redis->quit;
    $redis_cfg->quit;

    $self->render(json => { pairs => \@pairs, total => $total, filtered_total => $filtered_total });
}

sub _archive_brief_from_hash {
    my ($id, $h) = @_;
    return {} unless $h && %$h;
    my $tags  = redis_decode($h->{tags} // '');
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
        title      => redis_decode($h->{title} // ''),
        name       => redis_decode($h->{name}  // ''),
        tags       => $tags,
        pagecount  => ($h->{pagecount} // 0) + 0,
        arcsize    => ($h->{arcsize}   // 0) + 0,
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

sub refresh {
    my $self = shift;

    my $redis_cfg = _get_redis_config();
    my $redis     = _get_redis();

    # Cap scan to 2x deck target to bound memory on oversized decks.
    my $SCAN_CAP = 200;
    my @members  = $redis_cfg->zrange("LRR_DUPLICATE_PAIRS", 0, $SCAN_CAP - 1);
    my $orphans  = 0;
    my $dismissed_leftover = 0;
    my @to_remove;

    # Collect unique IDs for batched existence check.
    my %check_ids;
    for my $member (@members) {
        if ($redis_cfg->sismember("LRR_DEDUP_DISMISSED", $member)) {
            push @to_remove, $member;
            $dismissed_leftover++;
            next;
        }
        my ($a, $b) = split /\|/, $member, 2;
        $check_ids{$a} = [];
        $check_ids{$b} = [];
    }

    # Pipelined EXISTS for all unique archive IDs.
    if (%check_ids) {
        my @exists_results;
        for my $id (keys %check_ids) {
            $redis->exists($id, sub { push @exists_results, [ $id, $_[0] ] });
        }
        $redis->wait_all_responses;
        for my $r (@exists_results) {
            $check_ids{$r->[0]} = $r->[1];
        }
    }

    for my $member (@members) {
        next if $redis_cfg->sismember("LRR_DEDUP_DISMISSED", $member);
        my ($a, $b) = split /\|/, $member, 2;
        if (!($check_ids{$a} // 0) || !($check_ids{$b} // 0)) {
            push @to_remove, $member;
            $orphans++;
        }
    }

    if (@to_remove) {
        $redis_cfg->zrem("LRR_DUPLICATE_PAIRS",     @to_remove);
        $redis_cfg->hdel("LRR_DUPLICATE_PAIR_META", @to_remove);
    }

    $redis->quit;
    $redis_cfg->quit;

    $self->render(json => {
        success            => \1,
        orphans_removed    => $orphans,
        dismissed_removed  => $dismissed_leftover,
        total_removed      => scalar(@to_remove),
    });
}

sub stats {
    my $self = shift;
    my $redis_cfg = _get_redis_config();
    my $redis     = _get_redis();

    my $total_pairs   = $redis_cfg->zcard("LRR_DUPLICATE_PAIRS") + 0;
    my %config        = $redis_cfg->hgetall("LRR_DEDUP_CONFIG");
    my $last_scan_ts       = $redis_cfg->get("LRR_DEDUP_LAST_SCAN");
    my $last_cover_scan_ts = $redis_cfg->get("LRR_DEDUP_LAST_COVER_SCAN");
    my $last_relation_scan_ts = $redis_cfg->get("LRR_DEDUP_LAST_RELATION_SCAN");
    my $algo_version       = ($config{algo_version}       // 1) + 0;
    my $cover_algo_version = ($config{cover_algo_version} // 1) + 0;
    my $lead_algo_version  = ($config{lead_algo_version}  // 2) + 0;

    my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
    my ($hashed, $errored, $pending) = (0, 0, 0);
    my ($cover_hashed, $cover_errored, $cover_pending) = (0, 0, 0);
    my ($lead_hashed, $lead_errored, $lead_pending) = (0, 0, 0);
    # Pipelined HMGET in one round-trip per archive instead of four
    # synchronous round-trips. On a 17k library this is ~30s vs ~3min.
    my @results;
    for my $id (@ids) {
        $redis->hmget($id, "pagehashes_v", "pagehashes_err", "coverhash_v", "coverhash_err", "lead_hashes_v", "lead_hashes_err",
            sub { push @results, $_[0] });
    }
    $redis->wait_all_responses;
    for my $reply (@results) {
        my ($v, $err, $cv, $cerr, $lv, $lerr) = @{ $reply // [] };
        $v    //= ''; $err  //= '';
        $cv   //= ''; $cerr //= '';
        $lv   //= ''; $lerr //= '';
        if    ($v eq $algo_version)              { $hashed++ }
        elsif ($err =~ /^\Q$algo_version\E:/)    { $errored++ }
        else                                     { $pending++ }
        if    ($cv eq $cover_algo_version)              { $cover_hashed++ }
        elsif ($cerr =~ /^\Q$cover_algo_version\E:/)    { $cover_errored++ }
        else                                            { $cover_pending++ }
        if    ($lv eq $lead_algo_version)               { $lead_hashed++ }
        elsif ($lerr =~ /^\Q$lead_algo_version\E:/)      { $lead_errored++ }
        else                                            { $lead_pending++ }
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

    my $cover_cursor_i = ($config{cover_cursor_i} // 0) + 0;
    my $cover_cursor_j = ($config{cover_cursor_j} // 0) + 0;
    my $cover_cursor_threshold = defined $config{cover_cursor_threshold}
        ? $config{cover_cursor_threshold} + 0
        : undef;
    my $cover_sweep_done = ($cover_cursor_i == 0 && $cover_cursor_j == 0) ? 1 : 0;

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
        cover_algo_version       => $cover_algo_version,
        archives_with_coverhashes => $cover_hashed,
        archives_cover_pending    => $cover_pending,
        archives_cover_errored    => $cover_errored,
        cover_cursor_i            => $cover_cursor_i,
        cover_cursor_j            => $cover_cursor_j,
        cover_cursor_threshold    => $cover_cursor_threshold,
        cover_sweep_done          => $cover_sweep_done,
        last_cover_scan_ts        => defined $last_cover_scan_ts ? $last_cover_scan_ts + 0 : 0,
        lead_algo_version         => $lead_algo_version,
        archives_with_leadhashes  => $lead_hashed,
        archives_lead_pending     => $lead_pending,
        archives_lead_errored     => $lead_errored,
        last_relation_scan_ts     => defined $last_relation_scan_ts ? $last_relation_scan_ts + 0 : 0,
        config => {
            algo_version         => $algo_version,
            pages_sampled        => ($config{pages_sampled}        // 5)  + 0,
            pcount_tolerance_pct => ($config{pcount_tolerance_pct} // 20) + 0,
            loose_max_score      => ($config{loose_max_score}      // 40) + 0,
            candidate_pair_cap   => ($config{candidate_pair_cap}   // 10_000_000) + 0,
            cover_algo_version   => $cover_algo_version,
            cover_max_hamming    => ($config{cover_max_hamming}    // 12) + 0,
            matcher_version                     => ($config{matcher_version}                     // 2)    + 0,
            lead_algo_version                   => $lead_algo_version,
            lead_pages_sampled                  => ($config{lead_pages_sampled}                  // 3)    + 0,
            strong_visual_hamming               => ($config{strong_visual_hamming}               // 16)   + 0,
            weak_visual_hamming                 => ($config{weak_visual_hamming}                 // 24)   + 0,
            strong_title_score                  => ($config{strong_title_score}                  // 0.78) + 0,
            very_strong_title_score             => ($config{very_strong_title_score}             // 0.90) + 0,
            subset_page_ratio                   => ($config{subset_page_ratio}                   // 0.70) + 0,
            preferred_language_quality_floor    => ($config{preferred_language_quality_floor}    // 0.70) + 0,
            high_quality_subset_warning_ratio   => ($config{high_quality_subset_warning_ratio}   // 1.30) + 0,
            candidate_block_match_count         => ($config{candidate_block_match_count}         // 2)    + 0,
            candidate_bucket_cap                => ($config{candidate_bucket_cap}                // 100)  + 0,
        },
    });
}

1;
