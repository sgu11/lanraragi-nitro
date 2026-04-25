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
use LANraragi::Utils::Archive qw(extract_single_file get_filelist);
use LANraragi::Utils::PHash   qw(compute_phash_64);

# Indirection seams so tests can stub side effects without an archive on disk.
sub _get_archive_path { LANraragi::Utils::Path::get_archive_path(@_) }
sub _get_filelist     { my @list = LANraragi::Utils::Archive::get_filelist(@_); return @list }
sub _extract_page     { LANraragi::Utils::Archive::extract_single_file(@_) }
sub _unlink_temp      { unlink $_[0] if -e $_[0] }
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
        my $extracted;
        my $hash;
        eval {
            $extracted = _extract_page($file, $page);
            $hash = _compute_phash($extracted);
        };
        if ($@ || !$hash) {
            push @hashes, "-";
        } else {
            push @hashes, $hash;
            $any_success = 1;
        }
        _unlink_temp($extracted) if $extracted;
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

1;
