use strict;
use warnings;
use utf8;

use File::Temp qw(tempdir);
use Test::More;

BEGIN { use_ok( 'LANraragi::Utils::PageCache', qw(fetch put clear_by_id) ); }

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

note('PageCache clears every page variant for one archive id');
{
    my $tmpdir = tempdir( CLEANUP => 1 );
    my $id = "0123456789abcdef0123456789abcdef01234567";
    my $other_id = "89abcdef0123456789abcdef0123456789abcdef";

    my @id_keys = (
        "page/$id/001.jpg",
        "resize_page/$id/001.jpg/1200/80",
        "crop_page/v6/$id/001.jpg/jpg",
        "crop_resize_page/v6/$id/001.jpg/1200/80",
        "crop_page_nocrop/v6/$id/001.jpg",
    );
    my @other_keys = (
        "page/$other_id/001.jpg",
        "crop_page/v6/$other_id/001.jpg/jpg",
        "untracked/misc-key",
    );

    no warnings 'redefine';
    local $ENV{LRR_PAGECACHE_PAGE_SIZE_MB} = 1;
    local *LANraragi::Utils::PageCache::get_temp = sub { return $tmpdir };
    local *LANraragi::Utils::PageCache::get_logger = sub { return FakePageCacheLogger->new };
    local *LANraragi::Utils::PageCache::calc_max_size = sub { return 64 };

    LANraragi::Utils::PageCache::initialize();

    foreach my $key ( @id_keys, @other_keys ) {
        ok( put( $key, "value:$key" ), "put accepts $key" );
    }

    clear_by_id($id);

    foreach my $key (@id_keys) {
        is( fetch($key), undef, "clear_by_id removes $key" );
    }

    foreach my $key (@other_keys) {
        is( fetch($key), "value:$key", "clear_by_id keeps $key" );
    }
}

done_testing();
