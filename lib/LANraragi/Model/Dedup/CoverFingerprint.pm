package LANraragi::Model::Dedup::CoverFingerprint;

use v5.36;
use strict;
use warnings;

use Mojo::JSON qw(encode_json decode_json);

use LANraragi::Utils::Vips;
use LANraragi::Utils::PHash qw(hamming_hex);
use LANraragi::Model::Dedup qw(_extract_page _get_filelist compute_coverhash_for_archive);

# Algorithm version for cover fingerprint v2.
use constant FP_VERSION => 2;

# Cover page selection thresholds.
use constant MIN_COVER_WIDTH  => 300;
use constant MIN_COVER_HEIGHT => 400;
use constant MIN_COVER_ASPECT => 0.55;   # width/height
use constant MAX_COVER_ASPECT => 0.85;
use constant MAX_COVER_ENTROPY_THRESHOLD => 3.0;

# How many pages to inspect for cover selection.
use constant COVER_INSPECT_PAGES => 5;

# -------------------------------------------------------------------------
# Cover page selection
# -------------------------------------------------------------------------

sub _shannon_entropy {
    my ($pixels, $bins) = @_;
    $bins //= 16;
    my $n = scalar @$pixels;
    return 0 unless $n > 0;
    my @hist = (0) x $bins;
    my $bin_width = 256 / $bins;
    for my $p (@$pixels) {
        my $idx = int($p / $bin_width);
        $idx = $bins - 1 if $idx >= $bins;
        $hist[$idx]++;
    }
    my $entropy = 0;
    for my $c (@hist) {
        next if $c == 0;
        my $p = $c / $n;
        $entropy -= $p * log($p);
    }
    return $entropy / log(2);
}

# Score a candidate cover page. Higher = better cover candidate.
sub _score_cover_page {
    my ($width, $height, $pixels) = @_;
    my $score = 0;
    my $aspect = $height > 0 ? $width / $height : 0;

    # Size bonus
    if ($width >= MIN_COVER_WIDTH && $height >= MIN_COVER_HEIGHT) {
        $score += 10;
    } else {
        $score -= 5;
    }

    # Portrait aspect bonus
    if ($aspect >= MIN_COVER_ASPECT && $aspect <= MAX_COVER_ASPECT) {
        $score += 10;
    } elsif ($aspect > 0 && $aspect < 1.0) {
        $score += 3;   # portrait but not typical cover ratio
    }

    # Entropy penalty for blank/near-monochrome pages
    my $entropy = _shannon_entropy($pixels, 16);
    if ($entropy < MAX_COVER_ENTROPY_THRESHOLD) {
        $score -= 10;
    } else {
        $score += 5;
    }

    return ($score, $aspect, $entropy);
}

# Inspect the first N image pages and pick the best cover candidate.
# Returns ($page_index, $page_filename) or (0, $first_page) as fallback.
sub pick_cover_page {
    my ($file, $filelist, $id) = @_;
    return (0, undef) unless $filelist && @$filelist;

    my $n_files = scalar(@$filelist);
    my $inspect = $n_files <= COVER_INSPECT_PAGES ? $n_files - 1 : COVER_INSPECT_PAGES - 1;
    my ($best_score, $best_idx) = (-999, 0);
    my $best_page;

    for my $i (0 .. $inspect) {
        my $page_file = $filelist->[$i];
        my ($extracted, $extracted_dir);
        eval {
            ($extracted, $extracted_dir) = _extract_page($file, $page_file);
            unless ($extracted && -e $extracted) {
                die "extraction failed";
            }
            open(my $fh, '<:raw', $extracted) or die "Can't open: $!";
            my $buf = do { local $/; <$fh> };
            close $fh;

            my $img = LANraragi::Utils::Vips::new_from_buffer($buf);
            my $w = LANraragi::Utils::Vips::width($img);
            my $h = LANraragi::Utils::Vips::height($img);

            # Resize small for entropy calculation
            my $thumb_buf = LANraragi::Utils::Vips::stretch_resize($buf, 64, 64);
            my ($pixel_bytes, $pixel_len) = LANraragi::Utils::Vips::read_pixels(
                LANraragi::Utils::Vips::new_from_buffer($thumb_buf)
            );
            my @pixels = unpack("C*", $pixel_bytes);

            my ($score, $aspect, $entropy) = _score_cover_page($w, $h, \@pixels);
            LANraragi::Utils::Vips::unref_image($img);

            if ($score > $best_score) {
                $best_score = $score;
                $best_idx   = $i;
                $best_page  = $page_file;
            }
        };
        _unlink_temp($extracted, $extracted_dir) if $extracted || $extracted_dir;
    }

    return ($best_idx, $best_page);
}

# -------------------------------------------------------------------------
# Fingerprint computation
# -------------------------------------------------------------------------

sub _compute_phash_fit {
    my ($image_path) = @_;
    open(my $fh, '<:raw', $image_path) or die "Can't open $image_path: $!";
    my $buf = do { local $/; <$fh> };
    close $fh;

    # Fit-resize preserving aspect ratio, then pHash on the result.
    # The fit may be smaller than 32x32 in one dimension; compute_phash_64
    # will stretch it to 32x32 internally, but the aspect-preserving
    # intermediate step produces a different hash than a direct stretch.
    my $fitted = LANraragi::Utils::Vips::fit_resize($buf, 32, 32);
    my $tmp = _vips_to_temp_file($fitted);
    LANraragi::Utils::Vips::unref_image($fitted);
    my $hash = LANraragi::Utils::PHash::compute_phash_64($tmp);
    unlink $tmp;
    return $hash;
}

sub _compute_phash_crop {
    my ($image_path) = @_;
    open(my $fh, '<:raw', $image_path) or die "Can't open $image_path: $!";
    my $buf = do { local $/; <$fh> };
    close $fh;

    my $cropped = LANraragi::Utils::Vips::cover_resize($buf, 32, 32);
    my $tmp = _vips_to_temp_file($cropped);
    LANraragi::Utils::Vips::unref_image($cropped);
    my $hash = LANraragi::Utils::PHash::compute_phash_64($tmp);
    unlink $tmp;
    return $hash;
}

sub _compute_dhash {
    my ($image_path) = @_;
    open(my $fh, '<:raw', $image_path) or die "Can't open $image_path: $!";
    my $buf = do { local $/; <$fh> };
    close $fh;

    # 128-bit dHash: resize to 17x16, grayscale, compare adjacent horizontal pixels.
    # VIPS_INTERPRETATION_GREY16 = 12, VIPS_FORMAT_UCHAR = 0.
    my $resized = LANraragi::Utils::Vips::stretch_resize($buf, 17, 16);
    my $grey16;
    my $cs_ret = LANraragi::Utils::Vips::vips_colourspace($resized, \$grey16, 12, undef);
    LANraragi::Utils::Vips::unref_image($resized);
    die "dHash colourspace error" if $cs_ret != 0;

    my $gray;
    my $cast_ret = LANraragi::Utils::Vips::vips_cast($grey16, \$gray, 0, undef);
    LANraragi::Utils::Vips::unref_image($grey16);
    die "dHash cast error" if $cast_ret != 0;

    my ($bytes, $size) = LANraragi::Utils::Vips::read_pixels($gray);
    LANraragi::Utils::Vips::unref_image($gray);
    my @pixels = unpack("C*", $bytes);

    my $bits = '';
    for my $row (0 .. 15) {
        for my $col (0 .. 15) {
            my $left  = $pixels[$row * 17 + $col];
            my $right = $pixels[$row * 17 + $col + 1];
            $bits .= ($left > $right) ? '1' : '0';
        }
    }

    # Pack 128 bits into 32 hex chars.
    my $hex = '';
    for my $i (0 .. 31) {
        $hex .= sprintf("%x", oct("0b" . substr($bits, $i * 4, 4)));
    }
    return $hex;
}

sub _compute_color_histogram {
    my ($image_path) = @_;
    open(my $fh, '<:raw', $image_path) or die "Can't open $image_path: $!";
    my $buf = do { local $/; <$fh> };
    close $fh;

    # Resize small and read raw RGB pixels
    my $resized = LANraragi::Utils::Vips::stretch_resize($buf, 16, 16);
    my ($bytes, $size) = LANraragi::Utils::Vips::read_pixels($resized);
    LANraragi::Utils::Vips::unref_image($resized);
    my @pixels = unpack("C*", $bytes);

    # 6-bin normalized HSV histogram: 2 hue bins × 3 value bins
    my @hist = (0, 0, 0, 0, 0, 0);
    my $n = length($bytes) / 3;   # RGB triples
    for my $i (0 .. $n - 1) {
        my $r = ($pixels[$i * 3]     // 0) / 255;
        my $g = ($pixels[$i * 3 + 1] // 0) / 255;
        my $b = ($pixels[$i * 3 + 2] // 0) / 255;

        my $max = $r > $g ? ($r > $b ? $r : $b) : ($g > $b ? $g : $b);
        my $min = $r < $g ? ($r < $b ? $r : $b) : ($g < $b ? $g : $b);
        my $delta = $max - $min;

        # Value bin (0-2)
        my $v = int($max * 3);
        $v = 2 if $v > 2;

        # Hue bin (0-1): warm (red/orange/yellow) vs cool (green/blue/purple)
        my $h = 0;
        if ($delta > 0.01) {
            my $hue;
            if    ($max == $r) { $hue = ($g - $b) / $delta }
            elsif ($max == $g) { $hue = 2 + ($b - $r) / $delta }
            else               { $hue = 4 + ($r - $g) / $delta }
            $hue = ($hue + 6) % 6;
            $h = int($hue / 3);   # 0 or 1
        }

        my $bin = $h * 3 + $v;
        $hist[$bin]++;
    }

    # Normalize
    my $total = $n || 1;
    my @normalized = map { sprintf("%.3f", $_ / $total) } @hist;
    return \@normalized;
}

sub _vips_to_temp_file {
    my ($image) = @_;
    my $tmp;
    my $ext = '.png';
    eval {
        $tmp = LANraragi::Utils::Vips::write_to_buffer($image, '.png', 90);
    };
    if ($@ || !$tmp) {
        # Fallback: write via PNG to temp
        require File::Temp;
        my ($fh, $path) = File::Temp::tempfile(SUFFIX => '.png', UNLINK => 1);
        LANraragi::Utils::Vips::pngsave($image, $path);
        close $fh;
        return $path;
    }
    require File::Temp;
    my ($fh, $path) = File::Temp::tempfile(SUFFIX => '.png', UNLINK => 1);
    print $fh $tmp;
    close $fh;
    return $path;
}

sub _unlink_temp {
    my ($extracted, $extracted_dir) = @_;
    unlink $extracted if $extracted && -e $extracted;
    rmdir $extracted_dir if $extracted_dir && -d $extracted_dir;
}

# -------------------------------------------------------------------------
# Main fingerprint function
# -------------------------------------------------------------------------

sub compute_cover_fingerprint_for_archive {
    my ($redis, $id, $config) = @_;
    my $algo = FP_VERSION;

    my $existing_v = $redis->hget($id, "cover_fp_v");
    return 0 if defined $existing_v && $existing_v eq $algo;

    my $file = $redis->hget($id, "file");
    unless ($file && -e $file) {
        $redis->hset($id, "cover_fp_err", "$algo:archive_missing");
        return -1;
    }

    my @filelist = _get_filelist($file, $id);
    my $n = scalar @filelist;
    if ($n == 0) {
        $redis->hset($id, "cover_fp_err", "$algo:empty_archive");
        return -1;
    }

    # Pick best cover page
    my ($cover_idx, $cover_page) = pick_cover_page($file, \@filelist, $id);
    $cover_page //= $filelist[0];
    $cover_idx //= 0;

    my ($extracted, $extracted_dir);
    my $fp;
    eval {
        ($extracted, $extracted_dir) = _extract_page($file, $cover_page);

        my $phash_fit  = _compute_phash_fit($extracted);
        my $phash_crop = _compute_phash_crop($extracted);
        my $dhash      = _compute_dhash($extracted);
        my $color      = _compute_color_histogram($extracted);

        my $w = 0; my $h = 0;
        eval {
            open(my $fh, '<:raw', $extracted) or die $!;
            my $buf = do { local $/; <$fh> };
            close $fh;
            my $img = LANraragi::Utils::Vips::new_from_buffer($buf);
            $w = LANraragi::Utils::Vips::width($img);
            $h = LANraragi::Utils::Vips::height($img);
            LANraragi::Utils::Vips::unref_image($img);
        };

        $fp = {
            v      => $algo,
            page   => $cover_idx,
            phash_fit  => $phash_fit,
            phash_crop => $phash_crop,
            dhash      => $dhash,
            color      => $color,
            aspect     => $h > 0 ? sprintf("%.3f", $w / $h) + 0 : 0,
            w => $w,
            h => $h,
        };
    };
    my $err = $@;
    _unlink_temp($extracted, $extracted_dir);

    if ($err || !$fp) {
        $redis->hset($id, "cover_fp_err", "$algo:extract_failed");
        return -1;
    }

    $redis->hmset($id,
        "cover_fp",   encode_json($fp),
        "cover_fp_v", $algo,
    );
    $redis->hdel($id, "cover_fp_err");
    return 1;
}

# Backward-compatible: also computes the legacy coverhash for archives
# that don't have the new fingerprint yet. The Minion task should call both
# compute_coverhash_for_archive (legacy) and this function.
sub backfill_cover_fingerprint {
    my ($redis, $id, $config) = @_;
    # First compute the old coverhash (needed for legacy code)
    my $rc = LANraragi::Model::Dedup::compute_coverhash_for_archive($redis, $id, $config);
    # Then compute the v2 fingerprint
    my $fp_rc = compute_cover_fingerprint_for_archive($redis, $id, $config);
    return $rc < 0 && $fp_rc < 0 ? -1 : 1;
}

1;
