package LANraragi::Model::Dedup::CoverIndex;

use v5.36;
use strict;
use warnings;

use Mojo::JSON qw(encode_json decode_json);
use Digest::SHA qw(sha256_hex);
use LANraragi::Utils::Database ();
use LANraragi::Utils::Logging  ();
use LANraragi::Utils::PHash    qw(hamming_hex);
use LANraragi::Utils::Redis    qw(redis_decode);
use LANraragi::Utils::RedisScript qw(evalsha_cached);
use LANraragi::Model::Dedup    ();

use constant DECK_TARGET => 100;
use constant NUM_BANDS   => 4;       # split 64-bit pHash into 4x16-bit bands
use constant BAND_WIDTH  => 4;       # 4 hex chars per band
# Single product default for cover Hamming threshold (UI, API, Redis config).
use constant DEFAULT_COVER_MAX_HAMMING => 22;

# Band bucket key pattern: cover:band:<band_index>:<hex_value>
sub band_key {
    my ($band_idx, $hex_value) = @_;
    return "cover:band:$band_idx:$hex_value";
}

# Split a 16-char hex hash into 4 bands of 4 chars each.
sub _hash_bands {
    my ($hash) = @_;
    return () unless defined $hash && $hash =~ /\A[0-9a-f]{16}\z/i;
    my $h = lc($hash);
    return map { substr($h, $_ * BAND_WIDTH, BAND_WIDTH) } 0 .. NUM_BANDS - 1;
}

# --- Key name constants -------------------------------------------------
sub PAIR_KEY       { "LRR_COVER_DUPLICATE_PAIRS" }
sub PAIR_META_KEY  { "LRR_COVER_DUPLICATE_PAIR_META" }
sub DISMISSED_KEY  { "LRR_COVER_DUPLICATE_DISMISSED" }
sub CONFIG_KEY     { "LRR_COVER_DEDUP_CONFIG" }
sub LAST_SCAN_KEY  { "LRR_COVER_DEDUP_LAST_SCAN" }

# Patch only owned fields atomically: background verification must not erase a
# human decision, and a stale browser must not recreate a removed pair.
sub patch_pair_meta {
    my ($redis_cfg, $pair, $patch, $expected, $generation) = @_;
    my $script = <<'LUA';
if not redis.call('ZSCORE', ARGV[1], ARGV[3]) then return '' end
local raw = redis.call('HGET', ARGV[2], ARGV[3]) or '{}'
if ARGV[5] ~= '' and raw ~= ARGV[5] then return '' end
local ok, meta = pcall(cjson.decode, raw)
if not ok or type(meta) ~= 'table' then meta = {} end
if ARGV[6] ~= '' and meta.generation ~= ARGV[6] then return '' end
local previous = cjson.encode(meta)
local patch = cjson.decode(ARGV[4])
for k, v in pairs(patch) do meta[k] = v end
redis.call('HSET', ARGV[2], ARGV[3], cjson.encode(meta))
return previous
LUA
    my $previous = evalsha_cached($redis_cfg, 'cover_patch_meta', $script,
        PAIR_KEY, PAIR_META_KEY, $pair, encode_json($patch), $expected // '', $generation // '');
    return unless defined $previous && length $previous;
    return decode_json($previous);
}

# Upgrade historical pairs on read, without replacing a concurrently regenerated
# pair's token or metadata. Only the displayed page (at most 200) needs tokens.
sub _pair_generation {
    my ($redis_cfg, $pair, $expected) = @_;
    my $script = <<'LUA';
if not redis.call('ZSCORE', ARGV[1], ARGV[3]) then return '' end
local raw = redis.call('HGET', ARGV[2], ARGV[3]) or '{}'
if raw ~= ARGV[5] then return '' end
local ok, meta = pcall(cjson.decode, raw)
if not ok or type(meta) ~= 'table' then meta = {} end
if not meta.generation or meta.generation == '' then
    meta.generation = ARGV[4]
    redis.call('HSET', ARGV[2], ARGV[3], cjson.encode(meta))
end
return cjson.encode(meta)
LUA
    my $raw = evalsha_cached($redis_cfg, 'cover_pair_generation', $script,
        PAIR_KEY, PAIR_META_KEY, $pair, sha256_hex(join ':', time(), $$, rand(), $pair), $expected // '{}');
    return length($raw // '') ? decode_json($raw) : undef;
}

# Archive and config databases share one Redis server. SELECT is local to the
# script; checking sources and publishing the pair must be one atomic operation.
sub _publish_cover_pair {
    my ($redis_cfg, $pair, $score, $meta, $sources) = @_;
    my ($a, $b) = split /\|/, $pair, 2;
    my $script = <<'LUA';
redis.call('SELECT', ARGV[1])
local valid = true
for i = 8, 12, 4 do
    local row = redis.call('HMGET', ARGV[i], 'coverhash', 'coverhash_v', 'dedup_generation')
    if row[1] ~= ARGV[i+1] or row[2] ~= ARGV[i+2] or (row[3] or '') ~= ARGV[i+3] then valid = false end
end
redis.call('SELECT', ARGV[2])
if not valid or redis.call('SISMEMBER', ARGV[5], ARGV[6]) == 1
    or redis.call('ZSCORE', ARGV[3], ARGV[6]) then return 0 end
redis.call('ZADD', ARGV[3], ARGV[7], ARGV[6])
redis.call('HSET', ARGV[4], ARGV[6], ARGV[16])
return 1
LUA
    return evalsha_cached($redis_cfg, 'cover_publish_pair', $script,
        LANraragi::Model::Config->get_archivedb, LANraragi::Model::Config->get_configdb,
        PAIR_KEY, PAIR_META_KEY, DISMISSED_KEY, $pair, $score,
        $a, @{$sources->{$a}}, $b, @{$sources->{$b}}, encode_json($meta));
}

# A single bounded HMGET replaces one Redis command per historical pair.
sub _visit_pair_meta {
    my ($redis_cfg, $members, $visit) = @_;
    for (my $offset = 0; $offset < @$members; $offset += 256) {
        my $end = $offset + 255 < $#$members ? $offset + 255 : $#$members;
        my @batch = @$members[$offset .. $end];
        $redis_cfg->hmget(PAIR_META_KEY, @batch, sub {
            my ($reply, $error) = @_;
            die "Cannot read cover pair metadata\n" if $error || ref $reply ne 'ARRAY';
            for my $i (0 .. $#batch) {
                my $meta = eval { decode_json($reply->[$i] // '{}') };
                $meta = {} unless ref $meta eq 'HASH';
                $visit->($batch[$i], $meta, $reply->[$i] // '{}');
            }
        });
        $redis_cfg->wait_all_responses;
    }
}

# Human decisions remain queryable, but must not consume the active deck.
sub active_deck_size {
    my ($redis_cfg) = @_;
    my @members = $redis_cfg->zrange(PAIR_KEY, 0, -1);
    my $count = 0;
    _visit_pair_meta($redis_cfg, \@members, sub {
        my ($member, $meta) = @_;
        $count++ if ($meta->{status} // 'new') eq 'new';
    });
    return $count;
}

sub _trim_unreviewed_pairs {
    my ($redis_cfg, $threshold) = @_;
    my @members = $redis_cfg->zrangebyscore(PAIR_KEY, "($threshold", '+inf');
    my $script = <<'LUA';
local removed = 0
for i = 4, #ARGV do
    local member = ARGV[i]
    local score = tonumber(redis.call('ZSCORE', ARGV[1], member))
    local ok, meta = pcall(cjson.decode, redis.call('HGET', ARGV[2], member) or '{}')
    if not ok or type(meta) ~= 'table' then meta = {} end
    if score and score > tonumber(ARGV[3]) and (meta.status or 'new') == 'new' then
        redis.call('ZREM', ARGV[1], member)
        redis.call('HDEL', ARGV[2], member)
        removed = removed + 1
    end
end
return removed
LUA
    while (@members) {
        evalsha_cached($redis_cfg, 'cover_trim_unreviewed', $script,
            PAIR_KEY, PAIR_META_KEY, $threshold, splice(@members, 0, 256));
    }
}

sub LEGACY_PAIR_KEY      { "LRR_DUPLICATE_PAIRS" }
sub LEGACY_PAIR_META_KEY { "LRR_DUPLICATE_PAIR_META" }

# --- Cover config -------------------------------------------------------
sub cover_config_from_redis {
    my ($redis_cfg) = @_;
    my %h;
    eval { %h = $redis_cfg->hgetall(CONFIG_KEY); };
    return {
        cover_algo_version => ($h{cover_algo_version} // LANraragi::Model::Dedup::COVER_HASH_ALGO_VERSION()) + 0,
        cover_max_hamming  => ($h{cover_max_hamming}  // DEFAULT_COVER_MAX_HAMMING()) + 0,
        candidate_pair_cap => ($h{candidate_pair_cap} // 10_000_000) + 0,
        cover_cursor_i     => ($h{cover_cursor_i}     // 0) + 0,
        cover_cursor_j     => ($h{cover_cursor_j}     // 0) + 0,
        cover_sweep_complete => $h{cover_sweep_complete},
        cover_cursor_threshold => defined $h{cover_cursor_threshold}
            ? $h{cover_cursor_threshold} + 0
            : undef,
        # legacy (default) = O(N²) upper-triangle; banded = LSH band buckets (opt-in).
        cover_sweep_mode   => (($h{cover_sweep_mode} // 'legacy') eq 'banded') ? 'banded' : 'legacy',
    };
}

# --- Pair listing -------------------------------------------------------
sub cover_pairs {
    my ($redis_cfg, $redis, $opts) = @_;
    $opts //= {};
    my $config = cover_config_from_redis($redis_cfg);
    my $algo = $config->{cover_algo_version};
    my $max_score = $opts->{max_score} // 64;
    my $offset    = $opts->{offset}    // 0;
    my $limit     = $opts->{limit}     // 100;
    my $status    = $opts->{status}    // 'new';
    $offset = 0 if $offset < 0;
    $limit = 1 if $limit < 1;
    $limit = 200 if $limit > 200;

    my @raw = $redis_cfg->zrangebyscore(PAIR_KEY, 0, $max_score, "WITHSCORES");

    my @raw_tuples;
    while (@raw) {
        my $member = shift @raw;
        my $score  = shift @raw;
        my ($id_a, $id_b) = split /\|/, $member, 2;
        push @raw_tuples, [$member, $score, $id_a, $id_b];
    }

    # Batched meta fetch
    my (%meta_cache, %raw_cache);
    _visit_pair_meta($redis_cfg, [map { $_->[0] } @raw_tuples], sub {
        $meta_cache{$_[0]} = $_[1];
        $raw_cache{$_[0]} = $_[2];
    });

    my @filtered;
    for my $t (@raw_tuples) {
        my $meta = $meta_cache{$t->[0]} // {};
        next if (($meta->{cover_algo_version} // 0) + 0) != $algo;
        next if $status ne 'all' && (($meta->{status} // 'new') ne $status);
        push @filtered, $t;
    }
    my $filtered_total = scalar @filtered;
    my $total = $filtered_total;
    my @pair_tuples = $offset < @filtered ? splice(@filtered, $offset, $limit) : ();

    my %seen_ids;
    for my $t (@pair_tuples) {
        $seen_ids{$t->[2]} = 1;
        $seen_ids{$t->[3]} = 1;
    }

    # Batched archive brief fetch
    my %brief_cache;
    my @brief_fields = qw(title name tags pagecount arcsize cover_fp);
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
        $meta = _pair_generation($redis_cfg, $member, $raw_cache{$member}) unless length($meta->{generation} // '');
        next unless $meta;
        push @pairs, {
            id_a         => $id_a,
            id_b         => $id_b,
            score        => $score + 0,
            cover_hamming => $meta->{cover_hamming},
            pass         => 'cover',
            status       => $meta->{status} // 'new',
            generation   => $meta->{generation},
            verification => ref $meta->{verification} eq 'HASH' ? $meta->{verification} : undef,
            a            => $brief_cache{$id_a} // {},
            b            => $brief_cache{$id_b} // {},
        };
    }

    return {
        pairs          => \@pairs,
        total          => $total,
        filtered_total => $filtered_total,
    };
}

sub _archive_brief_from_hash {
    my ($id, $h) = @_;
    return {} unless $h && %$h;
    my $tags = LANraragi::Utils::Redis::redis_decode($h->{tags} // '');
    my $cover_fp = eval { decode_json($h->{cover_fp} // '{}') } // {};
    $cover_fp = {} unless ref $cover_fp eq 'HASH';
    my $cover_width  = _nonnegative_number($cover_fp->{w});
    my $cover_height = _nonnegative_number($cover_fp->{h});
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
        arcid     => $id,
        title     => LANraragi::Utils::Redis::redis_decode($h->{title} // ''),
        name      => LANraragi::Utils::Redis::redis_decode($h->{name}  // ''),
        tags      => $tags,
        pagecount => ($h->{pagecount} || 0) + 0,
        arcsize   => ($h->{arcsize}   || 0) + 0,
        cover_width  => $cover_width,
        cover_height => $cover_height,
        cover_pixels => $cover_width * $cover_height,
        tag_count => $tag_count,
        language  => $language,
        date_added => $date_added,
    };
}

sub _nonnegative_number {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 unless "$value" =~ /^\d+(?:\.\d+)?$/;
    return $value + 0;
}

# --- Stats --------------------------------------------------------------
sub cover_stats {
    my ($redis_cfg, $redis) = @_;

    my $deck_size = active_deck_size($redis_cfg);
    my $config = cover_config_from_redis($redis_cfg);
    my $last_scan = $redis_cfg->get(LAST_SCAN_KEY);

    my $algo = $config->{cover_algo_version};

    # all_archive_ids lazily backfills this set with a one-time KEYS scan after
    # upgrades. Preserve that behavior before the server-side fast path, but
    # do not pull the maintained IDs into Perl on ordinary requests.
    if ( !( $redis->scard("LRR_ALL_ARCHIVES") + 0 ) ) {
        LANraragi::Utils::Database::all_archive_ids($redis);
    }

    my $script = <<'LUA';
        local ids = redis.call('SMEMBERS', ARGV[1])
        local algo = ARGV[2]
        local hashed = 0
        local errored = 0
        local pending = 0
        for i = 1, #ids do
            local values = redis.call('HMGET', ids[i], 'coverhash_v', 'coverhash_err', 'coverhash')
            local v = values[1] or ''
            local err = values[2] or ''
            local hash = values[3] or ''
            if v == algo and #hash == 16 and not string.find(hash, '[^%x]') then
                hashed = hashed + 1
            elseif string.sub(err, 1, string.len(algo) + 1) == algo .. ':' then
                errored = errored + 1
            else
                pending = pending + 1
            end
        end
        return cjson.encode({ total = #ids, hashed = hashed, errored = errored, pending = pending })
LUA

    my $stats = eval {
        my $result = decode_json( evalsha_cached( $redis, "cover_stats", $script, "LRR_ALL_ARCHIVES", $algo ) );
        die "Invalid cover stats Lua result\n"
            unless ref $result eq 'HASH'
                && defined $result->{total}
                && defined $result->{hashed}
                && defined $result->{errored}
                && defined $result->{pending};
        $result;
    };

    my ( $total, $hashed, $errored, $pending ) = ( 0, 0, 0, 0 );
    if ($@) {
        # Retain the previous pipelined implementation for Redis deployments
        # where Lua is unavailable or a script invocation otherwise fails.
        my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
        $total = scalar @ids;

        my @results;
        for my $id (@ids) {
            $redis->hmget($id, "coverhash_v", "coverhash_err", "coverhash",
                sub { push @results, $_[0] });
        }
        $redis->wait_all_responses;
        for my $reply (@results) {
            my ($v, $err, $hash) = @{ $reply // [] };
            $v   //= ''; $err //= '';
            if    ($v eq $algo && LANraragi::Model::Dedup::_valid_hash($hash)) { $hashed++ }
            elsif ($err =~ /^\Q$algo\E:/)       { $errored++ }
            else                                { $pending++ }
        }
    } else {
        $total   = $stats->{total} + 0;
        $hashed  = $stats->{hashed} + 0;
        $errored = $stats->{errored} + 0;
        $pending = $stats->{pending} + 0;
    }

    my $cursor_i = ($config->{cover_cursor_i} // 0) + 0;
    my $cursor_j = ($config->{cover_cursor_j} // 0) + 0;
    my $cursor_threshold = $config->{cover_cursor_threshold};
    my $sweep_done = defined($last_scan) && ($cursor_i == 0 && $cursor_j == 0) ? 1 : 0;
    $sweep_done = $config->{cover_sweep_complete} ? 1 : 0 if defined $config->{cover_sweep_complete};

    return {
        deck_size                => $deck_size,
        deck_target              => DECK_TARGET,
        deck_full                => ($deck_size >= DECK_TARGET ? 1 : 0),
        archives_total           => $total,
        archives_with_coverhashes => $hashed,
        archives_cover_pending    => $pending,
        archives_cover_errored    => $errored,
        cover_algo_version        => $algo,
        cover_max_hamming         => ($config->{cover_max_hamming} // DEFAULT_COVER_MAX_HAMMING()) + 0,
        last_scan_ts              => defined $last_scan ? $last_scan + 0 : 0,
        cover_cursor_i            => $cursor_i,
        cover_cursor_j            => $cursor_j,
        cover_cursor_threshold    => $cursor_threshold,
        cover_sweep_done          => $sweep_done,
        config => {
            cover_algo_version  => $algo,
            cover_max_hamming   => ($config->{cover_max_hamming}   // DEFAULT_COVER_MAX_HAMMING()) + 0,
            candidate_pair_cap  => ($config->{candidate_pair_cap}  // 10_000_000) + 0,
            cover_sweep_mode    => $config->{cover_sweep_mode} // 'legacy',
        },
    };
}

# --- Delete / Dismiss ---------------------------------------------------
sub delete_cover_pair {
    my ($redis_cfg, $pair, $generation) = @_;
    return 0 unless length($generation // '');
    my $script = <<'LUA';
if not redis.call('ZSCORE', ARGV[1], ARGV[4]) then return 0 end
local ok, meta = pcall(cjson.decode, redis.call('HGET', ARGV[2], ARGV[4]) or '{}')
if not ok or type(meta) ~= 'table' or meta.generation ~= ARGV[5] then return 0 end
redis.call('SADD', ARGV[3], ARGV[4])
redis.call('ZREM', ARGV[1], ARGV[4])
redis.call('HDEL', ARGV[2], ARGV[4])
return 1
LUA
    return evalsha_cached($redis_cfg, 'cover_delete_pair', $script,
        PAIR_KEY, PAIR_META_KEY, DISMISSED_KEY, $pair, $generation);
}

# --- Refresh: remove orphaned and dismissed pairs -----------------------
sub refresh_cover_pairs {
    my ($redis_cfg, $redis) = @_;
    my $SCAN_CAP = 200;
    my @members  = $redis_cfg->zrange(PAIR_KEY, 0, $SCAN_CAP - 1);
    my $orphans = 0;
    my $dismissed = 0;
    my @to_remove;

    my %check_ids;
    for my $member (@members) {
        if ($redis_cfg->sismember(DISMISSED_KEY, $member)) {
            push @to_remove, $member;
            $dismissed++;
            next;
        }
        my ($a, $b) = split /\|/, $member, 2;
        $check_ids{$a} = [];
        $check_ids{$b} = [];
    }

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
        next if $redis_cfg->sismember(DISMISSED_KEY, $member);
        my ($a, $b) = split /\|/, $member, 2;
        if (!($check_ids{$a} // 0) || !($check_ids{$b} // 0)) {
            push @to_remove, $member;
            $orphans++;
        }
    }

    if (@to_remove) {
        $redis_cfg->zrem(PAIR_KEY,      @to_remove);
        $redis_cfg->hdel(PAIR_META_KEY, @to_remove);
    }

    return {
        orphans_removed   => $orphans,
        dismissed_removed => $dismissed,
        total_removed     => scalar(@to_remove),
    };
}

# --- Remove all cover pairs for a given archive -------------------------
sub remove_pairs_for_archive {
    my ($redis_cfg, $id) = @_;
    my @members = $redis_cfg->zrange(PAIR_KEY, 0, -1);
    my @to_remove = grep { my ($a, $b) = split /\|/, $_, 2; $a eq $id || $b eq $id } @members;
    if (@to_remove) {
        $redis_cfg->zrem(PAIR_KEY,      @to_remove);
        $redis_cfg->hdel(PAIR_META_KEY, @to_remove);
    }
    return scalar @to_remove;
}

sub remove_stale_cover_pairs {
    my ($redis_cfg, $algo) = @_;
    my @members = $redis_cfg->zrange(PAIR_KEY, 0, -1);
    my @to_remove;
    _visit_pair_meta($redis_cfg, \@members, sub {
        my ($m, $meta) = @_;
        push @to_remove, $m if (($meta->{cover_algo_version} // 0) + 0) != $algo;
    });
    if (@to_remove) {
        $redis_cfg->zrem(PAIR_KEY,      @to_remove);
        $redis_cfg->hdel(PAIR_META_KEY, @to_remove);
    }
    return scalar @to_remove;
}

sub mark_band_buckets_stale {
    my ($redis_cfg) = @_;
    $redis_cfg->hset(CONFIG_KEY, "band_buckets_built", 0);
}

# --- (Phase 0) Cleanup: remove pass=cover entries from legacy keys ------
sub cleanup_legacy_cover_pairs {
    my ($redis_cfg) = @_;
    my @members = $redis_cfg->zrange(LEGACY_PAIR_KEY, 0, -1);
    my @to_remove;
    for my $m (@members) {
        my $meta_json = $redis_cfg->hget(LEGACY_PAIR_META_KEY, $m) // '{}';
        my $meta = eval { decode_json($meta_json) } // {};
        push @to_remove, $m if ($meta->{pass} // '') eq 'cover';
    }
    if (@to_remove) {
        $redis_cfg->zrem(LEGACY_PAIR_KEY,      @to_remove);
        $redis_cfg->hdel(LEGACY_PAIR_META_KEY, @to_remove);
    }
    return scalar @to_remove;
}

# --- Invalidate cover dedup signals for an archive ----------------------
sub invalidate_cover_dedup_signals {
    my ($redis, $redis_cfg, $id) = @_;

    LANraragi::Model::Dedup::_invalidate_dedup_source($redis, $id);

    # Remove affected pairs from cover-specific keys
    remove_pairs_for_archive($redis_cfg, $id);
    my @dismissed = $redis_cfg->smembers(DISMISSED_KEY);
    my @obsolete = grep { my ($a, $b) = split /\|/, $_, 2; $a eq $id || $b eq $id } @dismissed;
    $redis_cfg->srem(DISMISSED_KEY, @obsolete) if @obsolete;
    mark_band_buckets_stale($redis_cfg);

    # Also remove from legacy keys during transition
    my @legacy_members = $redis_cfg->zrange(LEGACY_PAIR_KEY, 0, -1);
    my @legacy_remove;
    for my $m (@legacy_members) {
        my ($a, $b) = split /\|/, $m, 2;
        next unless $a eq $id || $b eq $id;
        my $meta_json = $redis_cfg->hget(LEGACY_PAIR_META_KEY, $m) // '{}';
        my $meta = eval { decode_json($meta_json) } // {};
        push @legacy_remove, $m if ($meta->{pass} // '') eq 'cover';
    }
    if (@legacy_remove) {
        $redis_cfg->zrem(LEGACY_PAIR_KEY,      @legacy_remove);
        $redis_cfg->hdel(LEGACY_PAIR_META_KEY, @legacy_remove);
    }
}

# --- Phase 2: Banded hash bucket indexes ---------------------------------
#
# Each archive's coverhash (64-bit pHash) is split into 4 bands of 16 bits
# (4 hex chars). Archives that share at least one band are candidate pairs.
# This reduces the candidate space from O(N²) to O(N × avg_bucket_size).

# Build all band bucket indexes from current coverhashes. Clears old band
# keys and repopulates. Called from Minion before candidate generation.
sub build_band_buckets {
    my ($redis_cfg, $redis) = @_;

    # Clear old band keys — scan and delete keys matching the pattern.
    # The config DB holds these band indexes.
    my @old_keys = $redis_cfg->keys("cover:band:*");
    if (@old_keys) {
        $redis_cfg->del(@old_keys);
    }

    my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
    my @results;
    for my $id (@ids) {
        $redis->hmget($id, "coverhash", "coverhash_v",
            sub { push @results, [ $id, $_[0] ] });
    }
    $redis->wait_all_responses;

    my $algo = LANraragi::Model::Dedup::COVER_HASH_ALGO_VERSION();
    my $added = 0;
    for my $r (@results) {
        my ($id, $reply) = @$r;
        my ($ch, $cv) = @{ $reply // [] };
        next unless defined $ch && $ch =~ /\A[0-9a-f]{16}\z/i;
        # Accept only hashes written at the current algorithm version.
        next unless defined $cv && length($cv) && ($cv + 0) == $algo;

        my @bands = _hash_bands($ch);
        for my $band_idx (0 .. $#bands) {
            my $key = band_key($band_idx, $bands[$band_idx]);
            $redis_cfg->sadd($key, $id);
        }
        $added++;
    }

    $redis_cfg->hset(CONFIG_KEY, "band_buckets_built", 1);
    $redis_cfg->hset(CONFIG_KEY, "band_buckets_count", $added);
    $redis_cfg->hset(CONFIG_KEY, "band_buckets_algo_version", $algo);
    $redis_cfg->hset(CONFIG_KEY, 'band_cursor', 0);

    return { buckets_built => 1, archives_indexed => $added };
}

# Generate candidate pairs from band bucket intersections.
# Returns a list of unique "idA|idB" member strings for pairs that share
# at least one band bucket.
#
# Uses a cursor approach: ($band_cursor) persists which band index we left
# off at, so incremental calls don't rebuild the same candidates.
sub generate_band_candidates {
    my ($redis_cfg, $redis, $cfg) = @_;

    my $band_cursor      = ($cfg->{band_cursor}     // 0) + 0;
    my $bucket_cap        = $cfg->{candidate_bucket_cap} // 100;
    my $candidate_pair_cap = $cfg->{candidate_pair_cap} // 10_000_000;

    my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
    my @results;
    for my $id (@ids) {
        $redis->hmget($id, "coverhash", "coverhash_v", "dedup_generation",
            sub { push @results, [ $id, $_[0] ] });
    }
    $redis->wait_all_responses;

    my $algo = LANraragi::Model::Dedup::COVER_HASH_ALGO_VERSION();
    my %cover_data;
    my %sources;
    for my $r (@results) {
        my ($id, $reply) = @$r;
        my ($ch, $cv, $generation) = @{ $reply // [] };
        next unless defined $ch && $ch =~ /\A[0-9a-f]{16}\z/i;
        next unless defined $cv && length($cv) && ($cv + 0) == $algo;
        $cover_data{$id} = $ch;
        $sources{$id} = [$ch, $cv, $generation // ""];
    }

    my @sorted_ids = sort keys %cover_data;
    my $n_total = scalar @sorted_ids;

    # For each archive, look up its 4 band indices. Collect unique pairs
    # that share at least one band.
    my %candidate_set;
    my $scanned = 0;
    my $dropped_buckets = 0;
    my $largest_bucket = 0;

    for (my $i = $band_cursor; $i < $n_total; $i++) {
        my $aid = $sorted_ids[$i];
        my $hash = $cover_data{$aid};
        my @bands = _hash_bands($hash);

        # Collect candidate IDs from each band bucket
        my %seen;
        for my $band_idx (0 .. $#bands) {
            my $key = band_key($band_idx, $bands[$band_idx]);
            my @bucket = $redis_cfg->smembers($key);
            next unless @bucket;

            if (@bucket > $bucket_cap) {
                $dropped_buckets++;
                $largest_bucket = @bucket if @bucket > $largest_bucket;
                next;  # Skip over-generic buckets (solid-color covers)
            }
            $largest_bucket = @bucket if @bucket > $largest_bucket;

            for my $bid (@bucket) {
                next if $bid eq $aid;
                $seen{$bid} = 1;
            }
        }

        # Generate unique pairs for this archive's candidates
        for my $bid (keys %seen) {
            next unless exists $cover_data{$bid};
            my ($x, $y) = sort ($aid, $bid);
            $candidate_set{"$x|$y"} = 1;
        }

        $scanned++;
        # Cap to prevent unbounded work per call
        last if keys(%candidate_set) >= $candidate_pair_cap;
    }

    my $band_next = $scanned >= $n_total ? $n_total : $band_cursor + $scanned;

    return {
        members        => [ sort keys %candidate_set ],
        band_cursor    => $band_next,
        bands_done     => ($band_next >= $n_total ? 1 : 0),
        scanned        => $scanned,
        total          => $n_total,
        dropped_buckets => $dropped_buckets,
        largest_bucket  => $largest_bucket,
        cover_data      => \%cover_data,
        sources         => \%sources,
    };
}

# -------------------------------------------------------------------------
# Cover candidate sweep with banded candidate generation (Phase 2)
# Replaces the O(N²) cursor sweep with indexed band-bucket lookups.
# -------------------------------------------------------------------------
sub run_cover_candidate_sweep_banded {
    my ($redis, $redis_cfg, $threshold, $logger) = @_;
    $logger //= LANraragi::Utils::Logging::get_logger("Dedup", "dedup");

    my $cfg = cover_config_from_redis($redis_cfg);
    $threshold //= $cfg->{cover_max_hamming};

    # Trim pairs above new threshold
    my $prev_threshold = $cfg->{cover_cursor_threshold};
    $prev_threshold = defined $prev_threshold ? $prev_threshold + 0 : -1;
    my $threshold_changed = ($prev_threshold != $threshold);

    if ($threshold_changed) {
        _trim_unreviewed_pairs($redis_cfg, $threshold);
        $redis_cfg->hset(CONFIG_KEY, "cover_cursor_threshold", $threshold);
        $redis_cfg->hset(CONFIG_KEY, "band_cursor", 0);
    }

    my $stale_removed = remove_stale_cover_pairs($redis_cfg, $cfg->{cover_algo_version});
    $logger->info("cover sweep (banded): removed $stale_removed stale cover pair(s)")
        if $stale_removed;

    my $deck_size = active_deck_size($redis_cfg);
    my $room = DECK_TARGET - $deck_size;
    if ($room <= 0) {
        return {
            stored    => 0,
            deck_size => $deck_size,
            deck_full => 1,
            threshold => $threshold,
        };
    }

    # Check if band buckets need (re)building
    my $buckets_built = $redis_cfg->hget(CONFIG_KEY, "band_buckets_built") // 0;
    my $buckets_algo  = $redis_cfg->hget(CONFIG_KEY, "band_buckets_algo_version");
    my $algo          = $cfg->{cover_algo_version} // LANraragi::Model::Dedup::COVER_HASH_ALGO_VERSION();
    my $buckets_stale = !$buckets_built
        || !defined $buckets_algo
        || $buckets_algo eq ''
        || ($buckets_algo + 0) != ($algo + 0);
    if ($buckets_stale) {
        $logger->info("cover sweep: building band bucket indexes...");
        my $r = build_band_buckets($redis_cfg, $redis);
        $logger->info("cover sweep: band buckets built for " . ($r->{archives_indexed} // 0) . " archives");
    }

    my $band_cursor_raw = $redis_cfg->hget(CONFIG_KEY, "band_cursor");
    $band_cursor_raw = 0 if !defined $band_cursor_raw || $band_cursor_raw eq '';
    $cfg->{band_cursor}  = $band_cursor_raw + 0;
    $cfg->{target_pairs} = $room;
    $cfg->{cover_max_hamming} = $threshold;
    my $bucket_cap_raw = $redis_cfg->hget(CONFIG_KEY, "candidate_bucket_cap");
    $bucket_cap_raw = 100 if !defined $bucket_cap_raw || $bucket_cap_raw eq '';
    $cfg->{candidate_bucket_cap} = $bucket_cap_raw + 0;

    # Phase 2: generate candidates from band buckets
    my $gen = generate_band_candidates($redis_cfg, $redis, $cfg);

    # Skipping a large bucket trades away recall even at distance zero.
    return run_cover_candidate_sweep_legacy($redis, $redis_cfg, $threshold, $logger)
        if $gen->{dropped_buckets};

    $logger->info(sprintf(
        "cover sweep (banded): threshold=%g candidates=%d scanned=%d/%d dropped_buckets=%d largest_bucket=%d",
        $threshold,
        scalar(@{$gen->{members}}), $gen->{scanned},
        $gen->{total}, $gen->{dropped_buckets}, $gen->{largest_bucket}
    ));

    # Score the band-generated candidates. Pass key names through $cfg.
    $cfg->{pair_key}      = PAIR_KEY;
    $cfg->{pair_meta_key} = PAIR_META_KEY;
    $cfg->{dismissed_key} = DISMISSED_KEY;

    my $stored = 0;
    my $scored = 0;

    for my $member (@{$gen->{members}}) {
        last if $stored >= $room;
        $scored++;

        my ($id_a, $id_b) = split /\|/, $member, 2;
        my $hash_a = $gen->{cover_data}{$id_a};
        my $hash_b = $gen->{cover_data}{$id_b};
        next unless defined $hash_a && defined $hash_b;

        next if $redis_cfg->sismember(DISMISSED_KEY, $member);
        next if defined $redis_cfg->zscore(PAIR_KEY, $member);

        my $d = LANraragi::Utils::PHash::hamming_hex($hash_a, $hash_b);
        next if $d > $threshold;

        $stored += _publish_cover_pair($redis_cfg, $member, $d, {
                pass               => 'cover',
                cover_hamming      => $d,
                cover_algo_version => $algo,
                ts                 => time(),
                generation         => sha256_hex(join ':', time(), $$, rand(), $member),
            }, $gen->{sources});
    }

    $redis_cfg->set(LAST_SCAN_KEY, time());

    if ($gen->{bands_done}) {
        $redis_cfg->hset(CONFIG_KEY, "band_cursor", 0);
    } else {
        $redis_cfg->hset(CONFIG_KEY, "band_cursor", $gen->{band_cursor});
    }

    $logger->info(sprintf(
        "cover sweep (banded): threshold=%g candidates=%d scored=%d stored=%d deck=%d/%d bands_done=%s",
        $threshold, scalar(@{$gen->{members}}), $scored, $stored,
        $deck_size + $stored, DECK_TARGET,
        $gen->{bands_done} ? "yes" : "no"
    ));

    return {
        stored      => $stored,
        candidates  => scalar(@{$gen->{members}}),
        scanned     => $gen->{scanned},
        total       => $gen->{total},
        truncated   => (!$gen->{bands_done} && $stored < $room) ? 1 : 0,
        cur_i       => $gen->{band_cursor},
        cur_j       => 0,
        sweep_done  => ($gen->{bands_done} && $scored >= @{$gen->{members}}) ? 1 : 0,
    };
}
# Public entry: default remains the reliable O(N²) legacy sweep.
# Opt into banded LSH with LRR_COVER_DEDUP_CONFIG cover_sweep_mode=banded
# (or the equivalent field returned by cover_config_from_redis).
sub run_cover_candidate_sweep {
    my ($redis, $redis_cfg, $threshold, $logger) = @_;
    my $cfg = cover_config_from_redis($redis_cfg);
    # Four exact 16-bit bands guarantee a shared band only within distance 3.
    # At the product threshold (22), even distance-4 pairs can be missed.
    my $effective_threshold = $threshold // $cfg->{cover_max_hamming};
    if (($cfg->{cover_sweep_mode} // 'legacy') eq 'banded' && $effective_threshold <= 3) {
        return run_cover_candidate_sweep_banded($redis, $redis_cfg, $threshold, $logger);
    }
    return run_cover_candidate_sweep_legacy($redis, $redis_cfg, $threshold, $logger);
}

# O(N²) upper-triangle Hamming sweep with cover-only storage. Reliable default
# that guarantees recall: every pair within the Hamming threshold is found.
sub run_cover_candidate_sweep_legacy {
    my ($redis, $redis_cfg, $threshold, $logger) = @_;
    $logger //= LANraragi::Utils::Logging::get_logger("Dedup", "dedup");

    my $cfg = cover_config_from_redis($redis_cfg);
    $threshold //= $cfg->{cover_max_hamming};

    # Trim pairs above new threshold
    my $prev_threshold = $cfg->{cover_cursor_threshold};
    $prev_threshold = defined $prev_threshold ? $prev_threshold + 0 : -1;
    my $threshold_changed = ($prev_threshold != $threshold);

    if ($threshold_changed) {
        _trim_unreviewed_pairs($redis_cfg, $threshold);
        $redis_cfg->hset(CONFIG_KEY, "cover_cursor_i", 0);
        $redis_cfg->hset(CONFIG_KEY, "cover_cursor_j", 0);
        $redis_cfg->hset(CONFIG_KEY, "cover_cursor_threshold", $threshold);
    }

    my $stale_removed = remove_stale_cover_pairs($redis_cfg, $cfg->{cover_algo_version});
    $logger->info("cover sweep: removed $stale_removed stale cover pair(s)")
        if $stale_removed;

    my $deck_size = active_deck_size($redis_cfg);
    my $room = DECK_TARGET - $deck_size;
    if ($room <= 0) {
        return {
            stored    => 0,
            deck_size => $deck_size,
            deck_full => 1,
            threshold => $threshold,
        };
    }

    $cfg->{cur_i}        = ($redis_cfg->hget(CONFIG_KEY, "cover_cursor_i") || 0) + 0;
    $cfg->{cur_j}        = ($redis_cfg->hget(CONFIG_KEY, "cover_cursor_j") || 0) + 0;
    $cfg->{target_pairs} = $room;
    $cfg->{cover_max_hamming} = $threshold;

    # Pipelined HMGET for coverhash
    my @ids = LANraragi::Utils::Database::all_archive_ids($redis);
    my @results;
    for my $id (@ids) {
        $redis->hmget($id, "coverhash", "coverhash_v", "dedup_generation",
            sub { push @results, [ $id, $_[0] ] });
    }
    $redis->wait_all_responses;

    my %cover_data;
    my %sources;
    for my $r (@results) {
        my ($id, $reply) = @$r;
        my ($ch, $cv, $generation) = @{ $reply // [] };
        next unless defined $ch && $ch =~ /\A[0-9a-f]{16}\z/i;
        next unless defined $cv && $cv eq $cfg->{cover_algo_version};
        $cover_data{$id} = $ch;
        $sources{$id} = [$ch, $cv, $generation // ""];
    }

    # Numeric cursors are valid only for the same sorted inventory. Additions,
    # removals and same-ID hash replacements otherwise silently skip pairs.
    my $inventory = sha256_hex(join '', map { $_ . $cover_data{$_} . $sources{$_}[2] } sort keys %cover_data);
    my $previous_inventory = $redis_cfg->hget(CONFIG_KEY, 'cover_inventory') // '';
    if ($inventory ne $previous_inventory) {
        $cfg->{cur_i} = 0;
        $cfg->{cur_j} = 0;
        $redis_cfg->hset(CONFIG_KEY, 'cover_inventory', $inventory);
    }

    my $n_cover = scalar keys %cover_data;
    if ($n_cover > 5000) {
        $logger->warn("cover sweep: $n_cover archives — O(N²) sweep may take a while");
    }

    # Pass key names through $cfg for the underlying matcher
    $cfg->{pair_key}      = PAIR_KEY;
    $cfg->{pair_meta_key} = PAIR_META_KEY;
    $cfg->{dismissed_key} = DISMISSED_KEY;

    $cfg->{publish_pair} = sub { _publish_cover_pair($redis_cfg, @_, \%sources) };
    my $result = LANraragi::Model::Dedup::find_cover_duplicate_pairs_in_memory(\%cover_data, $redis_cfg, $cfg);
    $redis_cfg->set(LAST_SCAN_KEY, time());

    if ($result->{sweep_done}) {
        $redis_cfg->hset(CONFIG_KEY, "cover_cursor_i", 0);
        $redis_cfg->hset(CONFIG_KEY, "cover_cursor_j", 0);
    } else {
        $redis_cfg->hset(CONFIG_KEY, "cover_cursor_i", $result->{cur_i});
        $redis_cfg->hset(CONFIG_KEY, "cover_cursor_j", $result->{cur_j});
    }

    $logger->info(sprintf(
        "cover sweep: threshold=%g archives=%d candidates=%d stored=%d deck=%d/%d cursor=(%d,%d) sweep_done=%s",
        $threshold, scalar(keys %cover_data), $result->{candidates}, $result->{stored},
        $deck_size + $result->{stored}, DECK_TARGET,
        $result->{cur_i}, $result->{cur_j},
        $result->{sweep_done} ? "yes" : "no"
    ));

    return $result;
}

1;
