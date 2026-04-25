package LANraragi::Utils::PHash;

use v5.36;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(compute_phash_64 hamming_hex);

use LANraragi::Utils::Vips;

# Precomputed cosine table for a 32-point DCT-II.
# COS_TABLE[$i][$j] = cos((2i+1) * j * pi / 64), where i in 0..31, j in 0..7.
# We only need the first 8 frequency bins, so the table is 32x8 instead of 32x32.
my @COS_TABLE;
sub _init_cos_table {
    return if @COS_TABLE;
    my $pi = 4 * atan2(1, 1);
    for my $i (0 .. 31) {
        my @row;
        for my $j (0 .. 7) {
            push @row, cos((2 * $i + 1) * $j * $pi / 64);
        }
        push @COS_TABLE, \@row;
    }
}

# Popcount for an 8-bit value.
my @POPCOUNT_8 = map { my $b = $_; my $c = 0; $c += ($b >> $_) & 1 for 0..7; $c } 0..255;

# Computes a 64-bit perceptual hash for the image at $image_path.
# Pipeline: stretch-resize 32x32 -> grayscale uchar -> 2D DCT-II (32x32 -> 8x8) ->
# drop DC term -> threshold remaining 63 coefficients against their median ->
# pack 64 bits as a 16-char lowercase hex string.
sub compute_phash_64 {
    my ($image_path) = @_;
    _init_cos_table();

    my $matrix = LANraragi::Utils::Vips::extract_grayscale_32x32($image_path);

    # Row DCT: for each row i, compute 8 frequency bins.
    my @row_dct;
    for my $i (0 .. 31) {
        my $base = $i * 32;
        for my $j (0 .. 7) {
            my $sum = 0;
            for my $k (0 .. 31) {
                $sum += $matrix->[$base + $k] * $COS_TABLE[$k][$j];
            }
            $row_dct[$i][$j] = $sum;
        }
    }

    # Column DCT: take the 32 row-DCT results for each j and compute 8 column bins.
    my @dct;
    for my $i (0 .. 7) {
        for my $j (0 .. 7) {
            my $sum = 0;
            for my $k (0 .. 31) {
                $sum += $row_dct[$k][$j] * $COS_TABLE[$k][$i];
            }
            $dct[$i][$j] = $sum;
        }
    }

    # Median of 63 coefficients (skip [0][0] DC term).
    my @coeffs;
    for my $i (0 .. 7) {
        for my $j (0 .. 7) {
            next if $i == 0 && $j == 0;
            push @coeffs, $dct[$i][$j];
        }
    }
    my @sorted = sort { $a <=> $b } @coeffs;
    my $median = $sorted[31];

    # Build 64-bit value, MSB-first row-major.
    my $bits_high = 0;
    my $bits_low  = 0;
    my $idx       = 0;
    for my $i (0 .. 7) {
        for my $j (0 .. 7) {
            my $bit = ($dct[$i][$j] > $median) ? 1 : 0;
            if ($idx < 32) {
                $bits_high = ($bits_high << 1) | $bit;
            } else {
                $bits_low = ($bits_low << 1) | $bit;
            }
            $idx++;
        }
    }
    return sprintf("%08x%08x", $bits_high, $bits_low);
}

# Counts differing bits between two 16-char hex strings (Hamming distance, 0..64).
sub hamming_hex {
    my ($a, $b) = @_;
    my $packed_a = pack("H*", $a);
    my $packed_b = pack("H*", $b);
    # Use string bitwise XOR (^.) since use v5.36 enables the bitwise feature
    # which makes bare ^ numeric-only.
    my $xor = $packed_a ^. $packed_b;
    my $count = 0;
    $count += $POPCOUNT_8[$_] for unpack("C*", $xor);
    return $count;
}

1;
