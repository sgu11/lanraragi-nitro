package LANraragi::Utils::Minion::Dedup;

use strict;
use warnings;

use Mojo::JSON qw(decode_json);

use LANraragi::Utils::Database ();
use LANraragi::Utils::Logging  ();

use LANraragi::Model::Config;
use LANraragi::Model::Dedup;
use LANraragi::Model::Dedup::CoverIndex;
use LANraragi::Model::Dedup::CoverFingerprint;

# Fork-only Minion tasks for the duplicate-detection suite (pagehash, coverhash,
# relation/lead-signal matching and their backfills). Kept out of
# LANraragi::Utils::Minion so upstream merges of that file stay small; the only
# upstream-file footprint is the single add_tasks() call.

use constant COVER_HASH_INFLIGHT_KEY => "LRR_COVER_HASH_INFLIGHT";
use constant COVER_HASH_INFLIGHT_TTL => 15 * 60;

# Reads dedup tunables from Redis with sane defaults. The hash key lives in DB 2 (config).
sub _dedup_config_from_redis {
    my ($redis_cfg) = @_;
    my %h;
    eval { %h = $redis_cfg->hgetall("LRR_DEDUP_CONFIG"); };
    return {
        algo_version         => ($h{algo_version}         // 1) + 0,
        pages_sampled        => ($h{pages_sampled}        // 5) + 0,
        pcount_tolerance_pct => ($h{pcount_tolerance_pct} // 20) + 0,
        loose_max_score      => ($h{loose_max_score}      // 40) + 0,
        candidate_pair_cap   => ($h{candidate_pair_cap}   // 10_000_000) + 0,
        cover_algo_version   => ($h{cover_algo_version}   // LANraragi::Model::Dedup::COVER_HASH_ALGO_VERSION()) + 0,
        cover_max_hamming    => ($h{cover_max_hamming}
            // LANraragi::Model::Dedup::CoverIndex::DEFAULT_COVER_MAX_HAMMING()) + 0,
        matcher_version                     => ($h{matcher_version}                     // 2)    + 0,
        lead_algo_version                   => ($h{lead_algo_version}                   // 2)    + 0,
        lead_pages_sampled                  => ($h{lead_pages_sampled}                  // 3)    + 0,
        strong_visual_hamming               => ($h{strong_visual_hamming}               // 16)   + 0,
        weak_visual_hamming                 => ($h{weak_visual_hamming}                 // 24)   + 0,
        strong_title_score                  => ($h{strong_title_score}                  // 0.78) + 0,
        very_strong_title_score             => ($h{very_strong_title_score}             // 0.90) + 0,
        subset_page_ratio                   => ($h{subset_page_ratio}                   // 0.70) + 0,
        preferred_language_quality_floor    => ($h{preferred_language_quality_floor}    // 0.70) + 0,
        high_quality_subset_warning_ratio   => ($h{high_quality_subset_warning_ratio}   // 1.30) + 0,
        candidate_block_match_count         => ($h{candidate_block_match_count}         // 2)    + 0,
        candidate_bucket_cap                => ($h{candidate_bucket_cap}                // 100)  + 0,
    };
}

sub _coverhash_inflight_fresh {
    my ($redis_cfg, $id) = @_;
    my $started = $redis_cfg->hget(COVER_HASH_INFLIGHT_KEY, $id) // '';
    return 0 unless $started =~ /^\d+$/;
    return (time() - $started) < COVER_HASH_INFLIGHT_TTL ? 1 : 0;
}

sub _mark_coverhash_inflight {
    my ($redis_cfg, $id) = @_;
    $redis_cfg->hset(COVER_HASH_INFLIGHT_KEY, $id, time());
}

sub _clear_coverhash_inflight {
    my ($redis_cfg, $id) = @_;
    $redis_cfg->hdel(COVER_HASH_INFLIGHT_KEY, $id);
}

sub _enqueue_coverhash_unless_inflight {
    my ($redis_cfg, $minion, $id) = @_;
    return 0 if _coverhash_inflight_fresh($redis_cfg, $id);

    $minion->enqueue(
        compute_coverhash => [ $id ] => { priority => 0 }
    );
    _mark_coverhash_inflight($redis_cfg, $id);
    return 1;
}

sub _run_find_cover_duplicates_isolated {
    my ($job, $redis, $redis_cfg, $threshold_arg) = @_;

    my $logger = LANraragi::Utils::Logging::get_logger("Minion", "minion");
    my $cfg    = _dedup_config_from_redis($redis_cfg);
    my $minion = LANraragi::Model::Config->get_minion;

    # One-time legacy cleanup.
    my $cleaned = LANraragi::Model::Dedup::CoverIndex::cleanup_legacy_cover_pairs($redis_cfg);
    $logger->info("find_cover_duplicates_isolated: cleaned $cleaned legacy cover pair(s)");

    # Composite rebuild: queue missing cover hashes before sweeping. If any
    # hashes were queued, requeue this same task once so a single UI click can
    # complete the hash-then-sweep flow.
    my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
    my $pending  = 0;
    my $enqueued = 0;
    my $in_flight = 0;
    my $skipped  = 0;
    my @cover_states;
    for my $id (@ids) {
        $redis->hmget($id, "coverhash_v", "coverhash_err",
            sub { push @cover_states, [ $id, $_[0] ] });
    }
    $redis->wait_all_responses;

    for my $state (@cover_states) {
        my ($id, $reply) = @$state;
        my ($v, $err) = @{ $reply // [] };
        $v   //= '';
        $err //= '';
        if ($v eq $cfg->{cover_algo_version}) {
            $skipped++;
            next;
        }
        if ($err =~ /^\Q$cfg->{cover_algo_version}\E:/) {
            $skipped++;
            next;
        }
        $pending++;
        if (_enqueue_coverhash_unless_inflight($redis_cfg, $minion, $id)) {
            $enqueued++;
        } else {
            $in_flight++;
        }
    }

    if ($pending > 0) {
        $minion->enqueue(
            find_cover_duplicates_isolated => [ $threshold_arg ] => { priority => 0, delay => 30 }
        );
        $redis->quit;
        $redis_cfg->quit;
        $logger->info(
            "find_cover_duplicates_isolated: $pending archives pending cover hashes " .
            "(enqueued $enqueued, in-flight $in_flight, skipped $skipped). Sweep requeued."
        );
        $job->finish({
            stored         => 0,
            pending        => $pending,
            enqueued       => $enqueued,
            in_flight      => $in_flight,
            skipped        => $skipped,
            sweep_deferred => 1,
            requeued       => 1,
            legacy_cleaned => $cleaned,
        });
        return;
    }

    # All cover hashes ready -- run the sweep.
    my $threshold = defined $threshold_arg ? $threshold_arg + 0 : undef;
    my $result = LANraragi::Model::Dedup::CoverIndex::run_cover_candidate_sweep(
        $redis, $redis_cfg, $threshold, $logger
    );

    $redis->quit;
    $redis_cfg->quit;
    $result->{legacy_cleaned}  = $cleaned;
    $result->{pending}         = $pending;
    $result->{sweep_deferred}  = 0;
    $job->finish($result);
}

sub add_tasks {
    my $minion = shift;

    $minion->add_task(
        compute_pagehashes => sub {
            my ($job, $id) = @_;
            my $logger = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            my $cfg       = _dedup_config_from_redis($redis_cfg);
            $redis_cfg->quit;

            my $rc = LANraragi::Model::Dedup::compute_pagehashes_for_archive($redis, $id, $cfg);
            $redis->quit;

            if ($rc < 0) {
                $logger->warn("compute_pagehashes failed for $id");
            } elsif ($rc == 0) {
                $logger->debug("compute_pagehashes skip $id (already at v$cfg->{algo_version})");
            } else {
                $logger->debug("compute_pagehashes ok $id");
            }
            $job->finish({ rc => $rc });
        }
    );

    $minion->add_task(
        backfill_pagehashes => sub {
            my ($job) = @_;
            my $logger = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            my $cfg       = _dedup_config_from_redis($redis_cfg);

            my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
            my $total    = scalar @ids;
            my $enqueued = 0;
            my $skipped  = 0;
            my $seen     = 0;
            $redis_cfg->del("LRR_DEDUP_BACKFILL_CURSOR");
            $logger->info("backfill_pagehashes: scanning $total archives (algo_version=$cfg->{algo_version})");
            for my $id (@ids) {
                $seen++;
                my $v   = $redis->hget($id, "pagehashes_v")   // '';
                my $err = $redis->hget($id, "pagehashes_err") // '';
                if ($v eq $cfg->{algo_version}) {
                    $skipped++;
                    next;
                }
                if ($err =~ /^\Q$cfg->{algo_version}\E:/) {
                    $skipped++;
                    next;
                }
                LANraragi::Model::Config->get_minion->enqueue(
                    compute_pagehashes => [ $id ] => { priority => 0 }
                );
                $enqueued++;
                $redis_cfg->set("LRR_DEDUP_BACKFILL_CURSOR", $id);
                $logger->info("backfill_pagehashes: progress $seen/$total (enqueued=$enqueued skipped=$skipped)")
                    if $seen % 500 == 0;
            }
            $redis->quit;
            $redis_cfg->quit;
            $logger->info("backfill_pagehashes: done enqueued=$enqueued skipped=$skipped total=$total");
            $job->finish({ enqueued => $enqueued, skipped => $skipped, total => $total });
        }
    );

    $minion->add_task(
        find_duplicate_pairs => sub {
            my ($job, $threshold_arg) = @_;
            my $logger = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            my $cfg    = _dedup_config_from_redis($redis_cfg);

            # Caller (the Find button) passes the current UI threshold so the
            # deck only fills with pairs the user actually wants to see.
            # Without this, the deck filled at the loose ceiling (40) and a
            # user reviewing at threshold 25 saw an empty list with the
            # button stuck disabled.
            my $threshold = defined $threshold_arg
                ? $threshold_arg + 0
                : ($cfg->{loose_max_score} // 40);
            $cfg->{loose_max_score} = $threshold;

            # If the threshold differs from the one the current cursor was
            # built for, drop existing high-score pairs and reset the cursor
            # so the next sweep starts over with the new gate.
            my $prev_threshold = $redis_cfg->hget("LRR_DEDUP_CONFIG", "pair_cursor_threshold");
            $prev_threshold = defined $prev_threshold ? $prev_threshold + 0 : -1;
            my $threshold_changed = ($prev_threshold != $threshold);

            if ($threshold_changed) {
                # Trim pcount-pass pairs above the new threshold so the deck
                # reflects it. The same zset also holds cover/relation pairs
                # whose scores live on different scales (cover 0..64, relation
                # <1), so filter by meta.pass to avoid wiping them — mirrors
                # find_cover_duplicates. pcount pairs carry no `pass` key, so
                # an absent pass counts as 'pcount'.
                my @candidates = $redis_cfg->zrangebyscore(
                    "LRR_DUPLICATE_PAIRS", "($threshold", "+inf"
                );
                my @above;
                for my $m (@candidates) {
                    my $meta_json = $redis_cfg->hget("LRR_DUPLICATE_PAIR_META", $m) // '{}';
                    my $meta = eval { decode_json($meta_json) } // {};
                    push @above, $m if ($meta->{pass} // 'pcount') eq 'pcount';
                }
                if (@above) {
                    $redis_cfg->zrem("LRR_DUPLICATE_PAIRS", @above);
                    $redis_cfg->hdel("LRR_DUPLICATE_PAIR_META", @above);
                    $logger->info(
                        "find_duplicate_pairs: trimmed " . scalar(@above)
                        . " pcount pair(s) above new threshold $threshold"
                    );
                }
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "pair_cursor_i", 0);
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "pair_cursor_j", 0);
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "pair_cursor_threshold", $threshold);
            }

            # Deck UX: keep at most DECK_TARGET unreviewed pairs in
            # LRR_DUPLICATE_PAIRS at any time. Each run tops the deck up,
            # resuming from a persisted (cur_i, cur_j) cursor.
            my $DECK_TARGET = 100;
            my $deck_size = $redis_cfg->zcard("LRR_DUPLICATE_PAIRS") + 0;
            my $room      = $DECK_TARGET - $deck_size;
            if ($room <= 0) {
                $logger->info(
                    "find_duplicate_pairs: deck full ($deck_size/$DECK_TARGET) at threshold $threshold; review existing pairs first"
                );
                $redis->quit;
                $redis_cfg->quit;
                $job->finish({
                    stored     => 0,
                    deck_size  => $deck_size,
                    deck_full  => 1,
                    threshold  => $threshold,
                });
                return;
            }

            # One-time cleanup of pre-deck legacy index.
            my $legacy = $redis_cfg->hlen("LRR_DUPLICATE_GROUPS") // 0;
            $redis_cfg->del("LRR_DUPLICATE_GROUPS") if $legacy;
            $logger->info("find_duplicate_pairs: cleared $legacy legacy LRR_DUPLICATE_GROUPS entries") if $legacy;

            $cfg->{cur_i}        = ($redis_cfg->hget("LRR_DEDUP_CONFIG", "pair_cursor_i") // 0) + 0;
            $cfg->{cur_j}        = ($redis_cfg->hget("LRR_DEDUP_CONFIG", "pair_cursor_j") // 0) + 0;
            $cfg->{target_pairs} = $room;

            # Gather pagehashes for all archives via pipelined HMGET.
            my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
            my @results;
            for my $id (@ids) {
                $redis->hmget($id, "pagehashes", "pagehashes_n",
                    sub { push @results, [ $id, $_[0] ] });
            }
            $redis->wait_all_responses;
            $redis->quit;

            my %page_data;
            for my $r (@results) {
                my ($id, $reply) = @$r;
                my ($ph, $pn) = @{ $reply // [] };
                next unless defined $ph && length $ph;
                next unless defined $pn && $pn > 0;
                $page_data{$id} = { hashes => [ split / /, $ph ], n => $pn + 0 };
            }

            my $result = LANraragi::Model::Dedup::find_duplicate_pairs_in_memory(\%page_data, $redis_cfg, $cfg);
            $redis_cfg->set("LRR_DEDUP_LAST_SCAN", time());

            if ($result->{sweep_done}) {
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "pair_cursor_i", 0);
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "pair_cursor_j", 0);
            } else {
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "pair_cursor_i", $result->{cur_i});
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "pair_cursor_j", $result->{cur_j});
            }
            $redis_cfg->quit;

            $logger->info(sprintf(
                "find_duplicate_pairs: threshold=%g archives=%d candidates=%d stored=%d deck=%d/%d cursor=(%d,%d) sweep_done=%s",
                $threshold,
                scalar(keys %page_data), $result->{candidates}, $result->{stored},
                $deck_size + $result->{stored}, $DECK_TARGET,
                $result->{cur_i}, $result->{cur_j},
                $result->{sweep_done} ? "yes" : "no"
            ));
            if ($result->{truncated}) {
                $logger->warn("find_duplicate_pairs: candidate cap reached; tighten pcount_tolerance_pct");
            }
            $job->finish($result);
        }
    );

    # ----------------------------------------------------------------------
    # Cover-only dedup pass.
    # Mirrors the trio above (compute / backfill / find) but keys on a single
    # pHash of page 0 instead of 5 spaced samples, and skips the page-count
    # tolerance gate entirely. Picks up chapter-vs-volume style pairs that
    # the pcount sweep is structurally unable to consider.
    # ----------------------------------------------------------------------
    $minion->add_task(
        compute_coverhash => sub {
            my ($job, $id) = @_;
            my $logger = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            my $cfg       = _dedup_config_from_redis($redis_cfg);

            my ($rc, $err);
            eval { $rc = LANraragi::Model::Dedup::compute_coverhash_for_archive($redis, $id, $cfg); 1 }
                or $err = $@ || "compute_coverhash failed";
            if (defined $rc && $rc > 0) {
                eval { LANraragi::Model::Dedup::CoverIndex::mark_band_buckets_stale($redis_cfg); };
            }
            eval { _clear_coverhash_inflight($redis_cfg, $id); };
            $redis->quit;
            $redis_cfg->quit;

            die $err if $err;

            if ($rc < 0) {
                $logger->warn("compute_coverhash failed for $id");
            } elsif ($rc == 0) {
                $logger->debug("compute_coverhash skip $id (already at v$cfg->{cover_algo_version})");
            } else {
                $logger->debug("compute_coverhash ok $id");
            }
            $job->finish({ rc => $rc });
        }
    );

    # Cover fingerprint v2: multi-signal fingerprint (phash_fit, phash_crop,
    # dHash, color histogram). Runs alongside the legacy compute_coverhash.
    $minion->add_task(
        compute_cover_fingerprint => sub {
            my ($job, $id) = @_;
            my $logger = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            my $cfg       = _dedup_config_from_redis($redis_cfg);
            $redis_cfg->quit;

            my $rc = LANraragi::Model::Dedup::CoverFingerprint::compute_cover_fingerprint_for_archive($redis, $id, $cfg);
            $redis->quit;

            if ($rc < 0) {
                $logger->warn("compute_cover_fingerprint failed for $id");
            } elsif ($rc == 0) {
                $logger->debug("compute_cover_fingerprint skip $id (already at v" . LANraragi::Model::Dedup::CoverFingerprint::FP_VERSION . ")");
            } else {
                $logger->debug("compute_cover_fingerprint ok $id");
            }
            $job->finish({ rc => $rc });
        }
    );

    $minion->add_task(
        backfill_cover_fingerprints => sub {
            my ($job) = @_;
            my $logger    = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;

            my $fp_version = LANraragi::Model::Dedup::CoverFingerprint::FP_VERSION;
            my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
            my $total    = scalar @ids;
            my $enqueued = 0;
            my $skipped  = 0;
            my $seen     = 0;
            $redis_cfg->del("LRR_COVER_FP_BACKFILL_CURSOR");
            $logger->info("backfill_cover_fingerprints: scanning $total archives (fp_version=$fp_version)");
            for my $id (@ids) {
                $seen++;
                my $v   = $redis->hget($id, "cover_fp_v")   // '';
                my $err = $redis->hget($id, "cover_fp_err") // '';
                if ($v eq $fp_version) {
                    $skipped++;
                    next;
                }
                if ($err =~ /^\Q$fp_version\E:/) {
                    $skipped++;
                    next;
                }
                LANraragi::Model::Config->get_minion->enqueue(
                    compute_cover_fingerprint => [ $id ] => { priority => 0 }
                );
                $enqueued++;
                $redis_cfg->set("LRR_COVER_FP_BACKFILL_CURSOR", $id);
                $logger->info("backfill_cover_fingerprints: progress $seen/$total (enqueued=$enqueued skipped=$skipped)")
                    if $seen % 500 == 0;
            }
            $redis->quit;
            $redis_cfg->quit;
            $logger->info("backfill_cover_fingerprints: done enqueued=$enqueued skipped=$skipped total=$total");
            $job->finish({ enqueued => $enqueued, skipped => $skipped, total => $total });
        }
    );

    $minion->add_task(
        compute_dedup_signals => sub {
            my ($job, $id) = @_;
            my $logger = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            my $cfg       = _dedup_config_from_redis($redis_cfg);
            $redis_cfg->quit;

            my $rc = LANraragi::Model::Dedup::compute_leadhashes_for_archive($redis, $id, $cfg);
            if ($rc >= 0) {
                my @vals = $redis->hmget($id, qw(title name tags pagecount arcsize));
                my %h;
                @h{qw(title name tags pagecount arcsize)} = @vals;
                my $title = $h{title} || $h{name} || '';
                $redis->hmset(
                    $id,
                    "dedup_title_key",  LANraragi::Model::Dedup::normalize_title_for_dedup($title),
                    "dedup_work_key",   LANraragi::Model::Dedup::work_key_for_dedup($title),
                    "dedup_source_key", LANraragi::Model::Dedup::dedup_source_key_from_tags($h{tags} // ''),
                );
            }
            $redis->quit;

            if ($rc < 0) {
                $logger->warn("compute_dedup_signals failed for $id");
            } elsif ($rc == 0) {
                $logger->debug("compute_dedup_signals skip $id (already at v$cfg->{lead_algo_version})");
            } else {
                $logger->debug("compute_dedup_signals ok $id");
            }
            $job->finish({ rc => $rc });
        }
    );

    $minion->add_task(
        backfill_coverhashes => sub {
            my ($job) = @_;
            my $logger    = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            my $cfg       = _dedup_config_from_redis($redis_cfg);

            my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
            my $total    = scalar @ids;
            my $enqueued = 0;
            my $skipped  = 0;
            my $seen     = 0;
            $redis_cfg->del("LRR_DEDUP_COVER_BACKFILL_CURSOR");
            $logger->info("backfill_coverhashes: scanning $total archives (cover_algo_version=$cfg->{cover_algo_version})");
            for my $id (@ids) {
                $seen++;
                my $v   = $redis->hget($id, "coverhash_v")   // '';
                my $err = $redis->hget($id, "coverhash_err") // '';
                if ($v eq $cfg->{cover_algo_version}) {
                    $skipped++;
                    next;
                }
                if ($err =~ /^\Q$cfg->{cover_algo_version}\E:/) {
                    $skipped++;
                    next;
                }
                if (_enqueue_coverhash_unless_inflight($redis_cfg, LANraragi::Model::Config->get_minion, $id)) {
                    $enqueued++;
                } else {
                    $skipped++;
                }
                $redis_cfg->set("LRR_DEDUP_COVER_BACKFILL_CURSOR", $id);
                $logger->info("backfill_coverhashes: progress $seen/$total (enqueued=$enqueued skipped=$skipped)")
                    if $seen % 500 == 0;
            }
            $redis->quit;
            $redis_cfg->quit;
            $logger->info("backfill_coverhashes: done enqueued=$enqueued skipped=$skipped total=$total");
            $job->finish({ enqueued => $enqueued, skipped => $skipped, total => $total });
        }
    );

    $minion->add_task(
        backfill_dedup_signals => sub {
            my ($job) = @_;
            my $logger    = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            my $cfg       = _dedup_config_from_redis($redis_cfg);

            my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
            my $total    = scalar @ids;
            my $enqueued = 0;
            my $skipped  = 0;
            my $seen     = 0;
            $redis_cfg->del("LRR_DEDUP_SIGNAL_BACKFILL_CURSOR");
            $logger->info("backfill_dedup_signals: scanning $total archives (lead_algo_version=$cfg->{lead_algo_version})");
            for my $id (@ids) {
                $seen++;
                my $v   = $redis->hget($id, "lead_hashes_v")   // '';
                my $err = $redis->hget($id, "lead_hashes_err") // '';
                if ($v eq $cfg->{lead_algo_version}) {
                    $skipped++;
                    next;
                }
                if ($err =~ /^\Q$cfg->{lead_algo_version}\E:/) {
                    $skipped++;
                    next;
                }
                LANraragi::Model::Config->get_minion->enqueue(
                    compute_dedup_signals => [ $id ] => { priority => 0 }
                );
                $enqueued++;
                $redis_cfg->set("LRR_DEDUP_SIGNAL_BACKFILL_CURSOR", $id);
                $logger->info("backfill_dedup_signals: progress $seen/$total (enqueued=$enqueued skipped=$skipped)")
                    if $seen % 500 == 0;
            }
            $redis->quit;
            $redis_cfg->quit;
            $logger->info("backfill_dedup_signals: done enqueued=$enqueued skipped=$skipped total=$total");
            $job->finish({ enqueued => $enqueued, skipped => $skipped, total => $total });
        }
    );

    $minion->add_task(
        find_cover_duplicates => sub {
            my ($job, $threshold_arg) = @_;
            my $logger    = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            my $cfg       = _dedup_config_from_redis($redis_cfg);

            # Caller may pass a Hamming cap; otherwise use configured default.
            # Cover Hamming has a different scale than the pcount-based score
            # (raw 0..64 vs mean+pcount-penalty), so it has its own knob and
            # its own cursor; we don't share `pair_cursor_threshold`.
            my $threshold = defined $threshold_arg
                ? $threshold_arg + 0
                : $cfg->{cover_max_hamming};
            $cfg->{cover_max_hamming} = $threshold;

            my $prev_threshold = $redis_cfg->hget("LRR_DEDUP_CONFIG", "cover_cursor_threshold");
            $prev_threshold = defined $prev_threshold ? $prev_threshold + 0 : -1;
            my $threshold_changed = ($prev_threshold != $threshold);

            if ($threshold_changed) {
                # Trim cover-pass pairs above the new threshold. We can't
                # use ZRANGEBYSCORE alone because the same zset also holds
                # pcount-based pairs whose scores live on a different scale
                # (≤40 by default, much higher than cover_max_hamming);
                # filter by meta.pass to avoid wiping pcount results.
                my @candidates = $redis_cfg->zrangebyscore(
                    "LRR_DUPLICATE_PAIRS", "($threshold", "+inf"
                );
                my @to_remove;
                for my $m (@candidates) {
                    my $meta_json = $redis_cfg->hget("LRR_DUPLICATE_PAIR_META", $m) // '{}';
                    my $meta = eval { decode_json($meta_json) } // {};
                    push @to_remove, $m if ($meta->{pass} // '') eq 'cover';
                }
                if (@to_remove) {
                    $redis_cfg->zrem("LRR_DUPLICATE_PAIRS",     @to_remove);
                    $redis_cfg->hdel("LRR_DUPLICATE_PAIR_META", @to_remove);
                    $logger->info(
                        "find_cover_duplicates: trimmed " . scalar(@to_remove)
                        . " cover pair(s) above new threshold $threshold"
                    );
                }
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "cover_cursor_i", 0);
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "cover_cursor_j", 0);
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "cover_cursor_threshold", $threshold);
            }

            my $DECK_TARGET = 100;
            my $deck_size = $redis_cfg->zcard("LRR_DUPLICATE_PAIRS") + 0;
            my $room      = $DECK_TARGET - $deck_size;
            if ($room <= 0) {
                $logger->info(
                    "find_cover_duplicates: deck full ($deck_size/$DECK_TARGET) at cover threshold $threshold; review existing pairs first"
                );
                $redis->quit;
                $redis_cfg->quit;
                $job->finish({
                    stored     => 0,
                    deck_size  => $deck_size,
                    deck_full  => 1,
                    threshold  => $threshold,
                });
                return;
            }

            $cfg->{cur_i}        = ($redis_cfg->hget("LRR_DEDUP_CONFIG", "cover_cursor_i") // 0) + 0;
            $cfg->{cur_j}        = ($redis_cfg->hget("LRR_DEDUP_CONFIG", "cover_cursor_j") // 0) + 0;
            $cfg->{target_pairs} = $room;

            # Pipelined HMGET for coverhash on every archive.
            my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
            my @results;
            for my $id (@ids) {
                $redis->hmget($id, "coverhash", "coverhash_v",
                    sub { push @results, [ $id, $_[0] ] });
            }
            $redis->wait_all_responses;
            $redis->quit;

            my %cover_data;
            for my $r (@results) {
                my ($id, $reply) = @$r;
                my ($ch, $cv) = @{ $reply // [] };
                next unless defined $ch && length($ch) == 16;
                next unless defined $cv && $cv eq $cfg->{cover_algo_version};
                $cover_data{$id} = $ch;
            }

            my $n_cover = scalar keys %cover_data;
            if ($n_cover > 5000) {
                $logger->warn("find_cover_duplicates: $n_cover archives with cover hashes — O(N²) sweep may take a while");
            }

            my $result = LANraragi::Model::Dedup::find_cover_duplicate_pairs_in_memory(\%cover_data, $redis_cfg, $cfg);
            $redis_cfg->set("LRR_DEDUP_LAST_COVER_SCAN", time());

            if ($result->{sweep_done}) {
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "cover_cursor_i", 0);
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "cover_cursor_j", 0);
            } else {
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "cover_cursor_i", $result->{cur_i});
                $redis_cfg->hset("LRR_DEDUP_CONFIG", "cover_cursor_j", $result->{cur_j});
            }
            $redis_cfg->quit;

            $logger->info(sprintf(
                "find_cover_duplicates: threshold=%g archives=%d candidates=%d stored=%d deck=%d/%d cursor=(%d,%d) sweep_done=%s",
                $threshold,
                scalar(keys %cover_data), $result->{candidates}, $result->{stored},
                $deck_size + $result->{stored}, $DECK_TARGET,
                $result->{cur_i}, $result->{cur_j},
                $result->{sweep_done} ? "yes" : "no"
            ));
            if ($result->{truncated}) {
                $logger->warn("find_cover_duplicates: candidate cap reached; will resume from cursor on next run");
            }
            $job->finish($result);
        }
    );

    $minion->add_task(
        find_relation_duplicates => sub {
            my ($job) = @_;
            my $logger    = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            my $cfg       = _dedup_config_from_redis($redis_cfg);

            my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
            my @results;
            for my $id (@ids) {
                $redis->hmget(
                    $id,
                    qw(title name tags pagecount arcsize lead_hashes lead_hashes_v lead_hashes_err),
                    sub { push @results, [ $id, $_[0] ] }
                );
            }
            $redis->wait_all_responses;
            $redis->quit;

            my %signals;
            my $pending_signals = 0;
            for my $r (@results) {
                my ($id, $reply) = @$r;
                my @vals = @{ $reply // [] };
                my %h;
                @h{qw(title name tags pagecount arcsize lead_hashes lead_hashes_v lead_hashes_err)} = @vals;
                if (($h{lead_hashes_v} // '') eq $cfg->{lead_algo_version}) {
                    $signals{$id} = {
                        title       => $h{title} // '',
                        name        => $h{name} // '',
                        tags        => $h{tags} // '',
                        pagecount   => ($h{pagecount} // 0) + 0,
                        arcsize     => ($h{arcsize} // 0) + 0,
                        lead_hashes => [ split / /, ($h{lead_hashes} // '') ],
                    };
                } elsif (($h{lead_hashes_err} // '') =~ /^\Q$cfg->{lead_algo_version}\E:/) {
                    # Errored at the current algo version: this archive can
                    # never produce a signal, so it must not block the pass
                    # forever. The stats endpoint counts these as errored, not
                    # pending, for the same reason.
                } else {
                    $pending_signals++;
                }
            }

            # Block only while archives are genuinely in flight (neither hashed
            # nor errored). This mirrors archives_lead_pending in the stats API,
            # which gates the Find button — so an enabled button always means
            # the pass will actually run instead of silently aborting.
            if ($pending_signals > 0) {
                $redis_cfg->quit;
                $logger->info(
                    "find_relation_duplicates: skipped; $pending_signals/" . scalar(@ids) . " archives still need lead dedup signals"
                );
                $job->finish({
                    stored          => 0,
                    candidates      => 0,
                    truncated       => 0,
                    archives        => scalar(keys %signals),
                    pending_signals => $pending_signals,
                });
                return;
            }

            # Relation matching upserts into the shared deck: existing pairs
            # are refreshed in place (review status preserved), pairs that no
            # longer classify are GC'd by the matcher, and dismissed pairs stay
            # dismissed via LRR_DEDUP_DISMISSED. No wholesale wipe — in-progress
            # review survives re-runs (was: del LRR_DUPLICATE_PAIRS + META).
            my $result = LANraragi::Model::Dedup::find_relation_duplicates_in_memory(\%signals, $redis_cfg, $cfg);
            $redis_cfg->set("LRR_DEDUP_LAST_RELATION_SCAN", time());
            $redis_cfg->quit;

            $logger->info(
                "find_relation_duplicates: archives=" . scalar(keys %signals)
                . " candidates=$result->{candidates} stored=$result->{stored}"
                . " updated=" . ($result->{updated} // 0)
                . " removed=" . ($result->{removed} // 0)
                . " dropped_buckets=" . ($result->{dropped_buckets} // 0)
                . " largest_bucket=" . ($result->{largest_bucket} // 0)
            );
            if ($result->{truncated}) {
                $logger->warn("find_relation_duplicates: candidate cap reached; tighten relation candidate settings");
            }
            if (($result->{dropped_buckets} // 0) > 0) {
                $logger->warn(
                    "find_relation_duplicates: skipped $result->{dropped_buckets} over-generic bucket(s) "
                    . "(largest=$result->{largest_bucket} > candidate_bucket_cap); those pairs were not generated"
                );
            }
            $job->finish($result);
        }
    );

    # Cover-isolated sweep: stores into LRR_COVER_DUPLICATE_PAIRS instead of
    # the mixed deck. Used by the /duplicates_custom rebuild endpoint.
    $minion->add_task(
        find_cover_duplicates_isolated => sub {
            my ($job, $threshold_arg) = @_;
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            _run_find_cover_duplicates_isolated($job, $redis, $redis_cfg, $threshold_arg);
        }
    );

}

1;
