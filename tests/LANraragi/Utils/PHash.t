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
}

done_testing();
