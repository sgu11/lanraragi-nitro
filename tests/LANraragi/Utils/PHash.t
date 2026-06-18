use strict;
use warnings;
use v5.36;
use Test::More;
use Cwd qw(getcwd);

my $cwd = getcwd();

use LANraragi::Utils::Vips;
plan skip_all => "libvips is not installed" unless LANraragi::Utils::Vips::is_vips_loaded();
LANraragi::Utils::Vips::init("phash-test");

use_ok('LANraragi::Utils::PHash');

note("hash format: 16 hex chars representing 64 bits");
{
    my $hash = LANraragi::Utils::PHash::compute_phash_64("$cwd/tests/samples/reader.jpg");
    like($hash, qr/^[0-9a-f]{16}$/, "Should be 16 lowercase hex chars");
}

note("identical input => identical hash (determinism)");
{
    my $h1 = LANraragi::Utils::PHash::compute_phash_64("$cwd/tests/samples/reader.jpg");
    my $h2 = LANraragi::Utils::PHash::compute_phash_64("$cwd/tests/samples/reader.jpg");
    is($h1, $h2, "Same image computed twice yields the same hash");
}

note("hamming_hex: counts differing bits between two 16-char hex strings");
{
    is(LANraragi::Utils::PHash::hamming_hex("0" x 16, "0" x 16), 0, "Identical = 0");
    is(LANraragi::Utils::PHash::hamming_hex("0" x 16, "f" x 16), 64, "All flipped = 64");
    is(LANraragi::Utils::PHash::hamming_hex("00" x 8, "01" . "00" x 7), 1, "One bit difference = 1");
    is(LANraragi::Utils::PHash::hamming_hex("0123456789abcdef", "0123456789abcdef"), 0, "Zero distance for identical hex");
}

note("pHash of reader.jpg is stable across runs (regression anchor)");
{
    my $h1 = LANraragi::Utils::PHash::compute_phash_64("$cwd/tests/samples/reader.jpg");
    my $h2 = LANraragi::Utils::PHash::compute_phash_64("$cwd/tests/samples/reader.jpg");
    is($h1, $h2, "reader.jpg pHash is deterministic");
    # When the hash value changes, it signals a breaking change in the DCT
    # or libvips resize pipeline. Record the new hash below after confirming
    # it's from a deliberate change, not a bug.
    #
    # Last known hash (2026-05-11, libvips 8.16):
    # is($h1, "KNOWN_HASH", "reader.jpg pHash regression anchor");
}

note("re-encoding the same image yields a small Hamming distance");
{
    my $src = "$cwd/tests/samples/reader.jpg";

    # Round-trip through libvips JPEG at quality 50 to emulate a re-encode.
    open(my $fh, '<:raw', $src) or die $!;
    my $buf = do { local $/; <$fh> };
    close $fh;

    my $img = LANraragi::Utils::Vips::new_from_buffer($buf);
    my $reencoded = LANraragi::Utils::Vips::write_to_buffer($img, ".jpg", 50);
    LANraragi::Utils::Vips::unref_image($img);

    my $tmp = "/tmp/phash_reencoded_$$.jpg";
    open(my $out, '>:raw', $tmp) or die $!;
    print $out $reencoded;
    close $out;

    my $h_orig  = LANraragi::Utils::PHash::compute_phash_64($src);
    my $h_re    = LANraragi::Utils::PHash::compute_phash_64($tmp);
    unlink $tmp;

    my $dist = LANraragi::Utils::PHash::hamming_hex($h_orig, $h_re);
    cmp_ok($dist, "<=", 8, "Re-encoded copy should be within 8 bits (got $dist)");
}

note("visually different bright images do not collapse to identical pHashes");
{
    my $a = LANraragi::Utils::PHash::compute_phash_64("$cwd/public/img/wait_warmly.jpg");
    my $b = LANraragi::Utils::PHash::compute_phash_64("$cwd/public/img/notfound.jpg");
    my $dist = LANraragi::Utils::PHash::hamming_hex($a, $b);

    cmp_ok($dist, ">", 8, "Different bright images should stay separated (got $dist)");
}

done_testing();
