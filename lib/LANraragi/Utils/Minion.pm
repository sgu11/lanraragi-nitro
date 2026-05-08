package LANraragi::Utils::Minion;

use strict;
use warnings;

use Encode;
use File::Temp qw(tempdir);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::UserAgent;
use MCE::Loop;
use MCE::Shared;
use Config;

use LANraragi::Utils::Logging    qw(get_logger);
use LANraragi::Utils::Redis      qw(redis_decode);
use LANraragi::Utils::Archive    qw(extract_thumbnail);
use LANraragi::Utils::Database   ();
use LANraragi::Utils::Plugins    qw(get_downloader_for_url get_plugin get_plugin_parameters use_plugin);
use LANraragi::Utils::String     qw(trim_url);
use LANraragi::Utils::TempFolder qw(get_temp);

use LANraragi::Model::Upload;
use LANraragi::Model::Config;
use LANraragi::Model::Stats;
use LANraragi::Model::Dedup;
use LANraragi::Model::Backup;

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );

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
        cover_algo_version   => ($h{cover_algo_version}   // 1)  + 0,
        cover_max_hamming    => ($h{cover_max_hamming}    // 12) + 0,
    };
}

# Add Tasks to the Minion instance.
sub add_tasks {
    my $minion = shift;

    $minion->add_task(
        thumbnail_task => sub {
            my ( $job, @args ) = @_;
            my ( $thumbdir, $id, $page ) = @args;

            my $logger = get_logger( "Minion", "minion" );

            # Non-cover thumbnails are rendered in low quality by default.
            my $use_hq    = $page eq 0 || LANraragi::Model::Config->get_hqthumbpages;
            my $thumbname = "";

            # Take a shortcut here - Minion jobs can keep the old basic behavior of page 0 = cover.
            eval { $thumbname = extract_thumbnail( $thumbdir, $id, $page, $page eq 0, $use_hq ); };
            if ($@) {
                my $msg = "Error building thumbnail: $@";
                $logger->error($msg);
                $job->fail( { errors => [$msg] } );
            } else {
                $job->finish($thumbname);
            }

        }
    );

    $minion->add_task(
        page_thumbnails => sub {

            my ( $job, @args )  = @_;
            my ( $id,  $force ) = @args;

            my $logger = get_logger( "Minion", "minion" );
            $logger->debug("Generating page thumbnails for archive $id...");

            # Get the number of pages in the archive
            my $redis = LANraragi::Model::Config->get_redis;
            my $pages = $redis->hget( $id, "pagecount" );

            my $use_hq   = LANraragi::Model::Config->get_hqthumbpages;
            my $thumbdir = LANraragi::Model::Config->get_thumbdir;

            my $use_jxl   = LANraragi::Model::Config->get_jxlthumbpages;
            my $format    = $use_jxl ? 'jxl' : 'jpg';
            my $subfolder = substr( $id, 0, 2 );

            my $errors = MCE::Shared->array;

            # Generate thumbnails for all pages -- Cover should already be handled in higher resolution
            my @keys = ();
            for ( my $i = 1; $i <= $pages; $i++ ) {
                push @keys, $i;
            }

            # Regen thumbnails for errythang if $force = 1, only missing thumbs otherwise
            my $sub = sub {
                my (@keys) = @_;

                foreach my $i (@keys) {

                    my $thumbname = "$thumbdir/$subfolder/$id/$i.$format";
                    unless ( $force == 0 && -e $thumbname ) {
                        $logger->debug("Generating thumbnail for page $i... ($thumbname)");
                        eval { $thumbname = extract_thumbnail( $thumbdir, $id, $i, 0, $use_hq ); };
                        if ($@) {
                            $logger->warn("Error while generating thumbnail: $@");
                            $errors->push($@);
                        }
                    }

                    # Add page number to note field so it can be fetched by the API
                    $job->note( $i => "processed", total_pages => $pages );

                }
            };

            eval {
                if ( IS_UNIX ) {
                    MCE::Loop->init( { max_workers => $ENV{LRR_MCE_WORKERS} } ) if $ENV{LRR_MCE_WORKERS};
                    mce_loop {
                        $sub->( @{$_} );
                    }
                    \@keys;
                    MCE::Loop->finish;
                } else {

                    # libarchive does not support threading on Windows
                    $sub->(@keys);
                }
            };

            $redis->hdel( $id, "thumbjob" );
            $redis->quit;

            my @err = $errors->values;
            $job->finish( { errors => \@err } );

            # Crashes on Windows so don't run it there
            if (IS_UNIX) {
                MCE::Shared->stop;
            }
        }
    );

    $minion->add_task(
        regen_all_thumbnails => sub {
            my ( $job,      @args )  = @_;
            my ( $thumbdir, $force ) = @args;

            my $logger = get_logger( "Minion", "minion" );
            my $redis  = LANraragi::Model::Config->get_redis;
            my @keys   = LANraragi::Utils::Database::all_archive_ids($redis);
            $redis->quit();

            $logger->info("Starting thumbnail regen job (force = $force)");
            my $errors = MCE::Shared->array;

            # Regen thumbnails for errythang if $force = 1, only missing thumbs o therwise
            my $sub = sub {
                my (@keys) = @_;

                foreach my $id (@keys) {

                    my $use_jxl   = LANraragi::Model::Config->get_jxlthumbpages;
                    my $format    = $use_jxl ? 'jxl' : 'jpg';
                    my $subfolder = substr( $id, 0, 2 );
                    my $thumbname = "$thumbdir/$subfolder/$id.$format";

                    unless ( $force == 0 && -e $thumbname ) {
                        eval {
                            $logger->debug("Regenerating for $id...");
                            extract_thumbnail( $thumbdir, $id, 0, 1, 1 );
                        };

                        if ($@) {
                            $logger->warn("Error while generating thumbnail: $@");
                            $errors->push($@);
                        }
                    }
                }
            };

            eval {
                if ( IS_UNIX ) {
                    MCE::Loop->init( { max_workers => $ENV{LRR_MCE_WORKERS} } ) if $ENV{LRR_MCE_WORKERS};
                    mce_loop {
                        $sub->( @{$_} );
                    }
                    \@keys;
                    MCE::Loop->finish;
                } else {

                    # libarchive does not support threading on Windows
                    $sub->(@keys);
                }
            };

            my @err = $errors->values;
            $job->finish( { errors => \@err } );

            # Crashes on Windows so don't run it there
            if (IS_UNIX) {
                MCE::Shared->stop;
            }
        }
    );

    $minion->add_task(
        compute_pagehashes => sub {
            my ($job, $id) = @_;
            my $logger = LANraragi::Utils::Logging::get_logger("Minion", "minion");
            my $redis  = LANraragi::Model::Config->get_redis;
            my $cfg    = _dedup_config_from_redis($redis);

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
                # Trim pairs above the new threshold so the deck reflects it.
                # ZREMRANGEBYSCORE doesn't return the removed members, so
                # collect them first to also clear LRR_DUPLICATE_PAIR_META.
                my @above = $redis_cfg->zrangebyscore(
                    "LRR_DUPLICATE_PAIRS", "($threshold", "+inf"
                );
                if (@above) {
                    $redis_cfg->zrem("LRR_DUPLICATE_PAIRS", @above);
                    $redis_cfg->hdel("LRR_DUPLICATE_PAIR_META", @above);
                    $logger->info(
                        "find_duplicate_pairs: trimmed " . scalar(@above)
                        . " pair(s) above new threshold $threshold"
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
            my $redis  = LANraragi::Model::Config->get_redis;
            my $cfg    = _dedup_config_from_redis($redis);

            my $rc = LANraragi::Model::Dedup::compute_coverhash_for_archive($redis, $id, $cfg);
            $redis->quit;

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
                LANraragi::Model::Config->get_minion->enqueue(
                    compute_coverhash => [ $id ] => { priority => 0 }
                );
                $enqueued++;
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
        build_stat_hashes => sub {
            my ( $job, @args ) = @_;
            LANraragi::Model::Stats->build_stat_hashes;
            $job->finish;
        }
    );

    $minion->add_task(
        handle_upload => sub {
            my ( $job,  @args )  = @_;
            my ( $file, $catid ) = @args;

            my $logger = get_logger( "Minion", "minion" );

            if (IS_UNIX) {
                $file = decode_utf8($file);
            }

            $logger->info("Processing uploaded file $file...");

            # Since we already have a file, this goes straight to handle_incoming_file.
            my ( $status_code, $id, $title, $message ) =
              LANraragi::Model::Upload::handle_incoming_file( $file, $catid, "", "", "" );
            my $status = $status_code == 200 ? 1 : 0;
            $job->finish(
                {   success  => $status,
                    id       => $id,
                    category => $catid,
                    title    => redis_decode($title),    # Fix display issues in the response
                    message  => $message
                }
            );
        }
    );

    $minion->add_task(
        download_url => sub {
            my ( $job, @args )  = @_;
            my ( $url, $catid ) = @args;

            my $ua     = Mojo::UserAgent->new;
            my $logger = get_logger( "Minion", "minion" );
            $logger->info("Downloading url $url...");

            # Keep a clean copy of the url for display and tagging
            my $og_url = $url;
            $og_url = trim_url($og_url);

            # If the URL is already recorded, abort the download
            my $recorded_id = LANraragi::Model::Stats::is_url_recorded($og_url);
            if ($recorded_id) {
                $job->finish(
                    {   success => 0,
                        url     => $og_url,
                        id      => $recorded_id,
                        message => "URL already downloaded!"
                    }
                );
                return;
            }

            # Check downloader plugins for one matching the given URL
            my $downloader = get_downloader_for_url($url);

            if ($downloader) {

                $logger->info( "Found downloader " . $downloader->{namespace} );
                my $tempdir = tempdir( CLEANUP => 1 );

                # Use the downloader to transform the URL
                my $plugname = $downloader->{namespace};
                my $plugin   = get_plugin($plugname);
                my %settings = get_plugin_parameters($plugname);

                my $plugin_result = LANraragi::Model::Plugins::exec_download_plugin( $plugin, $url, $tempdir, %settings );

                if ( exists $plugin_result->{error} ) {
                    $job->finish(
                        {   success => 0,
                            url     => $url,
                            message => $plugin_result->{error}
                        }
                    );
                    return;
                }

                # Check if the plugin provided a direct file path instead of a URL to download
                if ( exists $plugin_result->{file_path} ) {
                    my $tempfile = $plugin_result->{file_path};
                    $logger->info("Plugin directly provided file at: $tempfile");

                    # Add the url as a source: tag
                    my $tag = "source:$og_url";

                    # Hand off the result to handle_incoming_file
                    my ( $status_code, $id, $title, $message ) =
                      LANraragi::Model::Upload::handle_incoming_file( $tempfile, $catid, $tag, "", "" );
                    my $status = $status_code == 200 ? 1 : 0;

                    $job->finish(
                        {   success  => $status,
                            url      => $og_url,
                            id       => $id,
                            category => $catid,
                            title    => $title,
                            message  => $message
                        }
                    );
                    return;
                } else {

                    # Plugin provided a URL and User-Agent to download
                    $url = $plugin_result->{download_url};
                    $ua  = $plugin_result->{user_agent};
                    $logger->info("URL transformed by plugin to $url");
                }
            } else {
                $logger->debug("No downloader found, trying direct URL.");
            }

            # Download the URL
            eval {
                my $tempfile = LANraragi::Model::Upload::download_url( $url, $ua );
                $logger->info("URL downloaded to $tempfile");

                # Add the url as a source: tag
                my $tag = "source:$og_url";

                # Hand off the result to handle_incoming_file
                my ( $status_code, $id, $title, $message ) =
                  LANraragi::Model::Upload::handle_incoming_file( $tempfile, $catid, $tag, "", "" );
                my $status = $status_code == 200 ? 1 : 0;

                eval {
                    # Title might or might not be utf8 encoded
                    $title = decode_utf8($title);
                };

                $job->finish(
                    {   success  => $status,
                        url      => $og_url,
                        id       => $id,
                        category => $catid,
                        title    => $title,
                        message  => $message
                    }
                );
            };

            if ($@) {

                # Downloading failed...
                $job->finish(
                    {   success => 0,
                        url     => $og_url,
                        message => $@
                    }
                );
            }
        }
    );

    $minion->add_task(
        run_plugin => sub {
            my ( $job, @args ) = @_;
            my ( $namespace, $id, $scriptarg ) = @args;

            my $logger = get_logger( "Minion", "minion" );
            $logger->info("Running plugin $namespace...");

            my ( $pluginfo, $plugin_result ) = use_plugin( $namespace, $id, $scriptarg );

            $job->finish(
                {   type    => $pluginfo->{type},
                    success => ( exists $plugin_result->{error} ? 0 : 1 ),
                    error   => $plugin_result->{error},
                    data    => $plugin_result
                }
            );
        }
    );

    # Clear the stale thumbjob field when a page_thumbnails job fails or exhausts its retries.
    # Without this, a subsequent request sees thumbjob set and won't re-enqueue.
    $minion->on(
        failed => sub {
            my ( $minion, $job ) = @_;
            return unless $job->task eq 'page_thumbnails';
            my ($id) = @{ $job->args };
            return unless $id;
            my $redis = LANraragi::Model::Config->get_redis;
            my $stored = $redis->hget( $id, "thumbjob" );
            if ( defined $stored && $stored eq $job->id ) {
                $redis->hdel( $id, "thumbjob" );
            }
            $redis->quit;
        }
    );

    $minion->add_task(
        backup_json => sub {
            my ( $job, @args ) = @_;

            my $logger = get_logger( "Minion", "minion" );
            $logger->info("Starting backup JSON generation...");

            eval {
                # Generate the backup JSON with progress reporting
                my $json = LANraragi::Model::Backup::build_backup_JSON($job);

                # Write JSON to temp file
                my $tempdir  = get_temp();
                my $filename = "backup_" . $job->id . ".json";
                my $filepath = "$tempdir/$filename";

                open my $fh, '>:encoding(UTF-8)', $filepath
                  or die "Cannot write to $filepath: $!";
                print $fh $json;
                close $fh;

                $logger->info("Backup JSON generated successfully at $filepath");

                $job->finish(
                    {   success  => 1,
                        filename => $filename,
                        path     => $filepath
                    }
                );
            };

            if ($@) {
                my $error = "Error generating backup JSON: $@";
                $logger->error($error);
                $job->fail( { error => $error } );
            }
        }
    );

    $minion->add_task(
        restore_backup => sub {
            my ( $job, @args ) = @_;
            my ($json_data) = @args;

            my $logger = get_logger( "Minion", "minion" );
            $logger->info("Starting backup restoration...");

            eval {
                # Restore from JSON with progress reporting
                LANraragi::Model::Backup::restore_from_JSON( $json_data, $job );

                $logger->info("Backup restored successfully");

                $job->finish( { success => 1 } );
            };

            if ($@) {
                my $error = "Error restoring backup: $@";
                $logger->error($error);
                $job->fail( { error => $error } );
            }
        }
    );
}

1;
