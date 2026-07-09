use strict;
use warnings;
use utf8;

use File::Temp qw(tempdir);
use Test::More;

BEGIN { use_ok( 'LANraragi::Utils::PageCache', qw(fetch put clear_by_id) ); }

note('PageCache mmap geometry never exceeds the configured cap');
{
    local $ENV{LRR_PAGECACHE_PAGE_SIZE_MB} = 32;
    my $page_size = LANraragi::Utils::PageCache::calc_page_size_bytes(3000);
    my $page_count = LANraragi::Utils::PageCache::calc_page_count( 3000, $page_size );

    is( $page_size, 32 * 1024 * 1024, 'keeps a power-of-two 32 MiB page' );
    is( $page_count, 93, 'uses floor division instead of FastMmap page-count expansion' );
    cmp_ok( $page_count * $page_size, '<=', 3000 * 1024 * 1024, 'effective mmap stays within tempmaxsize' );

    local $ENV{LRR_PAGECACHE_PAGE_SIZE_MB} = 3;
    $page_size = LANraragi::Utils::PageCache::calc_page_size_bytes(64);
    is( $page_size, 2 * 1024 * 1024, 'normalizes non-power-of-two overrides before sizing the cache' );
}

{
package FakePageCacheLogger;

    sub new   { return bless {}, shift }
    sub debug { return 1 }
    sub warn  { return 1 }
}

note('PageCache creates a backing file within the configured cap');
{
    my $tmpdir = tempdir( CLEANUP => 1 );
    no warnings 'redefine';
    local $ENV{LRR_PAGECACHE_PAGE_SIZE_MB} = 32;
    local *LANraragi::Utils::PageCache::get_temp = sub { return $tmpdir };
    local *LANraragi::Utils::PageCache::get_logger = sub { return FakePageCacheLogger->new };
    local *LANraragi::Utils::PageCache::calc_max_size = sub { return 100 };

    LANraragi::Utils::PageCache::initialize();
    my @backing_files = glob "$tmpdir/*.dat";
    is( scalar @backing_files, 1, 'FastMmap created one backing file' );
    is( -s $backing_files[0], 96 * 1024 * 1024, 'backing file uses three 32 MiB pages, not FastMmap automatic expansion' );
    cmp_ok( -s $backing_files[0], '<=', 100 * 1024 * 1024, 'actual backing file stays below the cap' );
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
