use strict;
use warnings;
use v5.36;
use Test::More;
use Cwd qw(getcwd);
use File::Temp qw(tempfile);

my $cwd = getcwd();
require "$cwd/tests/mocks.pl";
setup_redis_mock();

use_ok('LANraragi::Utils::Vips');
use_ok('LANraragi::Model::Dedup::CoverFingerprint');

LANraragi::Utils::Vips::init("cover-fingerprint-test");

my $sample = "$cwd/tests/samples/reader.jpg";

my $dhash = LANraragi::Model::Dedup::CoverFingerprint::_compute_dhash($sample);
like($dhash, qr/\A[0-9a-f]{32}\z/, "dHash is a 128-bit hex string");

my ($fh, $gray_path) = tempfile(SUFFIX => '.png', UNLINK => 1);
close $fh;
my $gray = LANraragi::Utils::Vips::black(16, 16);
LANraragi::Utils::Vips::pngsave($gray, $gray_path);
LANraragi::Utils::Vips::unref_image($gray);

my $hist = LANraragi::Model::Dedup::CoverFingerprint::_compute_color_histogram($gray_path);
my $sum = 0;
$sum += $_ for @$hist;
is(scalar(@$hist), 6, "color histogram keeps six bins");
cmp_ok(abs($sum - 1), '<=', 0.001, "grayscale color histogram normalizes to 1.0");

done_testing();
