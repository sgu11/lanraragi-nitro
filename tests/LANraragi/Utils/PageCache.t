use strict;
use warnings;
use utf8;

use File::Temp qw(tempdir);
use Test::More;

BEGIN { use_ok( 'LANraragi::Utils::PageCache', qw(fetch put) ); }

{
    package FakePageCacheLogger;

    sub new   { return bless {}, shift }
    sub debug { return 1 }
    sub warn  { return 1 }
}

note('PageCache stores image-sized blobs in the mmap cache');
{
    my $tmpdir = tempdir( CLEANUP => 1 );
    my $blob   = "x" x ( 1024 * 1024 );

    no warnings 'redefine';
    local *LANraragi::Utils::PageCache::get_temp = sub { return $tmpdir };
    local *LANraragi::Utils::PageCache::get_logger = sub { return FakePageCacheLogger->new };
    local *LANraragi::Utils::PageCache::calc_max_size = sub { return 64 };

    LANraragi::Utils::PageCache::initialize();

    ok( put( "large-page-blob", $blob ), "put accepts a 1 MiB page blob" );
    my $cached = fetch("large-page-blob");
    ok( defined $cached, "fetch returns a cached page blob after put" );
    is( length($cached), length($blob), "cached page blob keeps its full length" );
}

done_testing();
