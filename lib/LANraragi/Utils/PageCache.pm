package LANraragi::Utils::PageCache;

use v5.36;

use strict;
use warnings;
use utf8;

use List::Util qw(min max);
use CHI;
use Config;
use Fcntl     qw(:flock);
use File::Path qw(make_path remove_tree);
use Mojo::JSON qw(decode_json encode_json);

use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::TempFolder qw(get_temp);

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );
use constant DEFAULT_PAGE_SIZE_MB => 32;

# Contains all functions related to caching entire pages
use Exporter 'import';
our @EXPORT_OK = qw(fetch put clear clear_by_id);

my $cache = undef;
my $page_size_bytes = undef;

sub _archive_id_from_key ($key) {
    return $1 if $key =~ m{\A(?:page|resize_page)/([0-9a-f]{40})/}i;
    return $1 if $key =~ m{\A(?:crop_page|crop_resize_page|crop_page_nocrop)/v\d+/([0-9a-f]{40})/}i;
    return;
}

sub _index_dir() {
    return get_temp . "/pagecache-index";
}

sub _ensure_index_dir() {
    my $dir = _index_dir();
    make_path($dir) if !-d $dir;
    return $dir;
}

sub _index_file ( $dir, $id ) {
    return "$dir/$id.json";
}

sub _index_lock_file ( $dir, $id ) {
    return "$dir/$id.lock";
}

sub _read_index_unlocked ($path) {
    return () if !-e $path;

    open( my $fh, '<', $path ) or return ();
    local $/ = undef;
    my $json = <$fh> // "[]";
    close $fh;

    my $keys = eval { decode_json($json) };
    return () if $@ || ref($keys) ne 'ARRAY';
    return grep { defined $_ && length $_ } @{$keys};
}

sub _write_index_unlocked ( $path, @keys ) {
    my %seen;
    my @unique = grep { !$seen{$_}++ } @keys;

    if ( !@unique ) {
        unlink $path if -e $path;
        return 1;
    }

    my $tmp_path = "$path.$$";
    open( my $fh, '>', $tmp_path ) or return;
    print {$fh} encode_json( \@unique );
    close $fh;
    return rename $tmp_path, $path;
}

sub _with_index_lock ( $id, $callback ) {
    my $dir = _ensure_index_dir();
    my $lock_file = _index_lock_file( $dir, $id );
    open( my $lock, '>>', $lock_file ) or return $callback->($dir);
    flock( $lock, LOCK_EX );
    my $result = $callback->($dir);
    close $lock;
    return $result;
}

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

    my $id = _archive_id_from_key($key);
    return $cache->set( $key, $content ) if !defined $id;

    my $stored;
    my $ok = eval {
        _with_index_lock(
            $id,
            sub ($dir) {
                $stored = $cache->set( $key, $content );
                if ($stored) {
                    my $path = _index_file( $dir, $id );
                    my @keys = _read_index_unlocked($path);
                    push @keys, $key;
                    _write_index_unlocked( $path, @keys );
                }
            }
        );
        1;
    };
    $logger->warn("Failed to store indexed PageCache entry for $key: $@") if !$ok;
    return $stored;
}

sub clear() {
    if (!defined($cache)) {
        initialize;
    }

    my $logger = get_logger( "PageCache", "lanraragi" );
    $logger->debug("Clearing cache");
    $cache->clear();

    my $index_dir = _index_dir();
    remove_tree($index_dir) if -d $index_dir;
}

sub clear_by_id ($id) {
    return if !defined $id || $id !~ /\A[0-9a-f]{40}\z/i;

    if (!defined($cache)) {
        initialize;
    }

    my $logger = get_logger( "PageCache", "lanraragi" );
    $logger->debug("Clearing cache entries for archive $id");

    my $ok = eval {
        _with_index_lock(
            $id,
            sub ($dir) {
                my $path = _index_file( $dir, $id );
                my @keys = _read_index_unlocked($path);
                foreach my $key (@keys) {
                    $logger->debug("Remove $key");
                    $cache->remove($key);
                }
                _write_index_unlocked($path);
            }
        );
        1;
    };
    $logger->warn("Failed to clear PageCache entries for $id: $@") if !$ok;
}

1;
