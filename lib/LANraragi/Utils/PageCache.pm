package LANraragi::Utils::PageCache;

use v5.36;

use strict;
use warnings;
use utf8;

use List::Util qw(min max);
use CHI;
use Config;

use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::TempFolder qw(get_temp);

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );
use constant DEFAULT_PAGE_SIZE_MB => 32;

# Contains all functions related to caching entire pages
use Exporter 'import';
our @EXPORT_OK = qw(fetch put);

my $cache = undef;
my $page_size_bytes = undef;

sub calc_max_size() {
    return max(0, min(LANraragi::Model::Config->get_tempmaxsize, 4096));
}

sub calc_page_size_bytes( $cache_size_mb ) {
    return if !$cache_size_mb;

    my $configured_mb = $ENV{LRR_PAGECACHE_PAGE_SIZE_MB} // DEFAULT_PAGE_SIZE_MB;
    my $page_size_mb = $configured_mb =~ /^\d+$/ ? $configured_mb : DEFAULT_PAGE_SIZE_MB;

    $page_size_mb = max(1, min($page_size_mb, $cache_size_mb));
    return $page_size_mb * 1024 * 1024;
}

sub initialize() {
    my $logger = get_logger( "PageCache", "lanraragi" );
    my $cache_size_mb = calc_max_size;
    my $disk_size = $cache_size_mb . "m";
    $page_size_bytes = calc_page_size_bytes($cache_size_mb);
    $logger->debug(
        "Initializing cache, disk size: "
          . $disk_size
          . ( defined $page_size_bytes ? ", page size: " . $page_size_bytes : "" )
    );

    if ( IS_UNIX ) {
        my %cache_options = (
            driver     => 'FastMmap',
            cache_size => $disk_size,
            root_dir    => get_temp,
        );
        $cache_options{page_size} = $page_size_bytes if defined $page_size_bytes;
        $cache = CHI->new(%cache_options);
    } else {
        $cache = CHI->new(
            driver     => 'Memory',
            global => 1,
            max_size => $disk_size,
        );
    }
}

# Fetches data from cache if available. Returns undef if nothing is there
sub fetch( $key ) {
    if (!defined($cache)) {
        initialize;
    }
    my $logger = get_logger( "PageCache", "lanraragi" );
    $logger->debug("Fetch $key");

    my $content = $cache->get($key);
    if (defined $content) {
        $logger->debug("Cache HIT for $key");
    } else {
        $logger->debug("Cache MISS for $key");
    }
    return $content;
}

# Attempts to store data in the cache. Do not assume that fetch will work immediately after, cache may be disabled etc
sub put( $key, $content ) {
    if (!defined($cache)) {
        initialize;
    }
    my $logger = get_logger( "PageCache", "lanraragi" );
    $logger->debug("Put $key");

    if ( IS_UNIX && defined $page_size_bytes && length($content) >= $page_size_bytes - 4096 ) {
        $logger->warn("Skipping cache put for $key: value is too large for the FastMmap page size");
        return;
    }

    return $cache->set($key, $content);
}

sub clear() {
    if (!defined($cache)) {
        initialize;
    }

    my $logger = get_logger( "PageCache", "lanraragi" );
    $logger->debug("Clearing cache");
    $cache->clear();
}

1;
