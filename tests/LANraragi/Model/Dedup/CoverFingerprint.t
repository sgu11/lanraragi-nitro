use strict;
use warnings;
use v5.36;
use Test::More;
use Cwd qw(getcwd);

my $cwd = getcwd();
require "$cwd/tests/mocks.pl";
setup_redis_mock();

use_ok('LANraragi::Utils::Vips');
use_ok('LANraragi::Model::Dedup::CoverFingerprint');

LANraragi::Utils::Vips::init("cover-fingerprint-test");

my $sample = "$cwd/tests/samples/reader.jpg";

my $dhash = LANraragi::Model::Dedup::CoverFingerprint::_compute_dhash($sample);
like($dhash, qr/\A[0-9a-f]{32}\z/, "dHash is a 128-bit hex string");

done_testing();
