package LANraragi::Model::Dedup;

use v5.36;
use strict;
use warnings;

use LANraragi::Utils::PHash qw(hamming_hex);

# Page-count-delta weight in the score formula. 20 means a 100% page-count
# mismatch contributes 20 to the score.
use constant PCOUNT_WEIGHT => 20;

# Returns the list of zero-based page indices to sample for an archive of $n
# pages, asking for $k samples. Cell-center sampling: int(n*(i+0.5)/k), then
# clamped to [0, n-1] and deduplicated while preserving order. Returns
# fewer than $k entries when $n < $k.
sub pick_spaced {
    my ($n, $k) = @_;
    return () if $n <= 0 || $k <= 0;

    my @seen;
    my @out;
    for my $i (0 .. $k - 1) {
        my $pos = int($n * ($i + 0.5) / $k);
        $pos = 0      if $pos < 0;
        $pos = $n - 1 if $pos >= $n;
        next if $seen[$pos]++;
        push @out, $pos;
    }
    return @out;
}

# Scores a candidate pair. Each archive is a hashref:
#   { hashes => [ "<16-hex>" or "-", ... ], n => <page count> }
# Returns ($score, \@per_page_distances, $page_count_delta_abs).
# Slots where either side is sentinel "-" are skipped. If no valid slots
# remain, mean_hamming = 64 (treat as fully dissimilar).
sub score_pair {
    my ($a, $b) = @_;
    my $n_a = $a->{n};
    my $n_b = $b->{n};

    my $hashes_a = $a->{hashes} // [];
    my $hashes_b = $b->{hashes} // [];
    my $k = (@$hashes_a < @$hashes_b) ? scalar(@$hashes_a) : scalar(@$hashes_b);

    my @per_page;
    my $total = 0;
    my $valid = 0;
    for my $i (0 .. $k - 1) {
        my $ha = $hashes_a->[$i];
        my $hb = $hashes_b->[$i];
        next if !defined $ha || !defined $hb || $ha eq '-' || $hb eq '-';
        my $d = hamming_hex($ha, $hb);
        push @per_page, $d;
        $total += $d;
        $valid++;
    }

    my $mean_hamming = $valid > 0 ? $total / $valid : 64;
    my $max_n = ($n_a > $n_b) ? $n_a : $n_b;
    my $pcount_delta_abs = abs($n_a - $n_b);
    my $pcount_delta_frac = $max_n > 0 ? $pcount_delta_abs / $max_n : 0;

    my $score = $mean_hamming + PCOUNT_WEIGHT * $pcount_delta_frac;
    return ($score, \@per_page, $pcount_delta_abs);
}

use LANraragi::Utils::Path    qw(get_archive_path);
use LANraragi::Utils::Archive qw(get_filelist);
use LANraragi::Utils::PHash   qw(compute_phash_64);
use File::Temp qw(tempdir);
use File::Path qw();

# Indirection seams so tests can stub side effects without an archive on disk.
sub _get_archive_path { LANraragi::Utils::Path::get_archive_path(@_) }
# Force-refresh the pagefiles cache when computing pHashes. The cache stored in
# Redis can drift if an archive file was replaced without HDEL'ing pagefiles
# (we have observed cached lists pointing at filenames that no longer exist
# inside the archive); force=1 rewalks the archive and rewrites the cache.
sub _get_filelist     { my @list = LANraragi::Utils::Archive::get_filelist($_[0], $_[1], 1); return @list }
# extract_single_file returns content bytes, not a path; pHash needs a path.
# Use extract_single_file_to_file into a per-call tempdir. Returns
# ($file_path, $dir) so the caller can remove both — leaving the dir
# behind on a long-lived Minion worker leaks ~5 dirs per archive.
sub _extract_page {
    my ($archive, $page) = @_;
    my $dir = tempdir(CLEANUP => 0);
    my $file = LANraragi::Utils::Archive::extract_single_file_to_file($archive, $page, $dir);
    return ($file, $dir);
}
sub _unlink_temp {
    my ($file, $dir) = @_;
    unlink $file if $file && -e $file;
    File::Path::remove_tree($dir) if $dir && -d $dir;
}
sub _compute_phash    { LANraragi::Utils::PHash::compute_phash_64(@_) }

# Computes pHashes for $id and writes them to Redis. Idempotent.
# $config is { algo_version => N, pages_sampled => K }.
# Behavior:
#   - If pagehashes_v already equals algo_version, returns 0 (no work).
#   - On full success: writes pagehashes / pagehashes_v / pagehashes_n, clears pagehashes_err.
#   - On per-slot failure: that slot becomes "-".
#   - On total failure: writes pagehashes_err = "<algo>:<reason>" and returns -1.
sub compute_pagehashes_for_archive {
    my ($redis, $id, $config) = @_;
    my $algo = $config->{algo_version} // 1;
    my $k    = $config->{pages_sampled} // 5;

    my $existing_v = $redis->hget($id, "pagehashes_v");
    return 0 if defined $existing_v && $existing_v eq $algo;

    my $file = _get_archive_path($redis, $id);
    unless ($file && -e $file) {
        $redis->hset($id, "pagehashes_err", "$algo:archive_missing");
        return -1;
    }

    my @filelist = _get_filelist($file, $id);
    my $n = scalar @filelist;
    if ($n == 0) {
        $redis->hset($id, "pagehashes_err", "$algo:empty_archive");
        return -1;
    }

    my @positions = pick_spaced($n, $k);
    my @hashes;
    my $any_success = 0;
    for my $pos (@positions) {
        my $page = $filelist[$pos];
        my ($extracted, $extracted_dir);
        my $hash;
        eval {
            ($extracted, $extracted_dir) = _extract_page($file, $page);
            $hash = _compute_phash($extracted);
        };
        if ($@ || !$hash) {
            push @hashes, "-";
        } else {
            push @hashes, $hash;
            $any_success = 1;
        }
        _unlink_temp($extracted, $extracted_dir) if $extracted || $extracted_dir;
    }

    while (scalar(@hashes) < $k) {
        push @hashes, "-";
    }

    unless ($any_success) {
        $redis->hset($id, "pagehashes_err", "$algo:all_extractions_failed");
        return -1;
    }

    $redis->hset($id, "pagehashes",   join(' ', @hashes));
    $redis->hset($id, "pagehashes_v", $algo);
    $redis->hset($id, "pagehashes_n", $n);
    $redis->hdel($id, "pagehashes_err");
    return 1;
}

use Mojo::JSON qw(encode_json);

# Pure matcher driver: takes pre-loaded %page_data instead of fetching from
# Redis, so the algorithm can be unit-tested without I/O. The Minion task
# wraps this with the Redis-side gather and cursor persistence.
#
# %page_data maps id -> { hashes => [...], n => N }.
#
# $config recognized keys:
#   loose_max_score, pcount_tolerance_pct, candidate_pair_cap, algo_version
#   cur_i, cur_j        - resume position in the sliding window (0,0 = start)
#   target_pairs        - stop after this many *new* pairs are stored
#                         (0 or undef = no cap, exhaust the sweep)
#
# Returns: { stored, candidates, truncated, cur_i, cur_j, sweep_done }.
# Caller persists cur_i/cur_j and resets to 0 when sweep_done is true.
sub find_duplicate_pairs_in_memory {
    my ($page_data, $redis, $config) = @_;
    my $loose_max    = $config->{loose_max_score}      // 40;
    my $tol_pct      = $config->{pcount_tolerance_pct} // 20;
    my $cap          = $config->{candidate_pair_cap}   // 10_000_000;
    my $algo         = $config->{algo_version}         // 1;
    my $start_i      = $config->{cur_i}                // 0;
    my $start_j      = $config->{cur_j}                // 0;
    my $target_pairs = $config->{target_pairs}         // 0;
    my $tolerance    = $tol_pct / 100.0;

    my @ids = sort { $page_data->{$a}{n} <=> $page_data->{$b}{n} } keys %$page_data;
    my $n_total = scalar @ids;

    # Stale cursor (e.g. archives deleted) — restart from beginning.
    $start_i = 0 if $start_i >= $n_total;

    my $stored          = 0;
    my $candidates_seen = 0;
    my $truncated       = 0;
    my $cur_i           = $n_total;   # default = sweep complete
    my $cur_j           = 0;

    OUTER: for (my $i = $start_i; $i < $n_total; $i++) {
        my $n_i = $page_data->{$ids[$i]}{n};
        my $upper_bound = $n_i * (1 + $tolerance);
        my $j_begin = ($i == $start_i && $start_j > $i) ? $start_j : $i + 1;

        for (my $j = $j_begin; $j < $n_total; $j++) {
            my $n_j = $page_data->{$ids[$j]}{n};
            last if $n_j > $upper_bound;

            if ($candidates_seen >= $cap) {
                $truncated = 1;
                $cur_i = $i; $cur_j = $j;
                last OUTER;
            }
            $candidates_seen++;

            my ($a, $b) = sort ($ids[$i], $ids[$j]);
            my $member = "$a|$b";
            next if $redis->sismember("LRR_DEDUP_DISMISSED", $member);
            next if defined $redis->zscore("LRR_DUPLICATE_PAIRS", $member);

            my ($score, $per_page, $pcount_delta) =
                score_pair($page_data->{$a}, $page_data->{$b});
            next if $score > $loose_max;

            $redis->zadd("LRR_DUPLICATE_PAIRS", $score, $member);
            $redis->hset("LRR_DUPLICATE_PAIR_META", $member,
                encode_json({
                    per_page     => $per_page,
                    pcount_delta => $pcount_delta,
                    algo_version => $algo,
                    ts           => time(),
                }));
            $stored++;

            if ($target_pairs && $stored >= $target_pairs) {
                $cur_i = $i; $cur_j = $j + 1;
                last OUTER;
            }
        }
    }

    return {
        stored     => $stored,
        candidates => $candidates_seen,
        truncated  => $truncated,
        cur_i      => $cur_i,
        cur_j      => $cur_j,
        sweep_done => ($cur_i >= $n_total ? 1 : 0),
    };
}

1;
