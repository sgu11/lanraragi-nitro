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

1;
