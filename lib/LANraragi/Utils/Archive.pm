package LANraragi::Utils::Archive;

use v5.36;
use experimental 'try';
use feature 'state';

use strict;
use warnings;
use utf8;

use Time::HiRes qw(gettimeofday);
use File::Basename;
use File::Path qw(remove_tree make_path);
use File::Find qw(finddepth);
use File::Copy qw(move);
use File::Temp qw(tempfile);
use Encode;
use Encode::Guess qw/euc-jp shiftjis 7bit-jis/;
use Redis;
use Cwd;
use Data::Dumper;
use Storable qw(nfreeze thaw);
use Archive::Libarchive qw( ARCHIVE_OK );
use Archive::Libarchive::Extract;
use Archive::Libarchive::Peek;
use File::Temp qw(tempdir);
use POSIX qw(strerror);
use Digest::SHA qw(sha256_hex);
use Mojo::DOM;
use Mojo::URL;
use Mojo::UserAgent;
use Socket qw(AF_INET AF_INET6 SOCK_STREAM getaddrinfo inet_ntop unpack_sockaddr_in unpack_sockaddr_in6);

use LANraragi::Utils::TempFolder qw(get_temp);
use LANraragi::Utils::Logging    qw(get_logger);
use LANraragi::Utils::Generic    qw(is_image shasum_str);
use LANraragi::Utils::Redis      qw(redis_decode redis_encode);
use LANraragi::Utils::Path       qw(get_archive_path open_path_or_die);
use LANraragi::Utils::Resizer    qw(get_resizer);
use LANraragi::Utils::PageCache  qw(put clear_by_id);
use LANraragi::Utils::Vips       ();

# Utilitary functions for handling Archives.
# Relies on Libarchive (for zip, cbz), VIPS (for PDFs) and Mojo::UserAgent (for CBW web comics).
use Exporter 'import';
our @EXPORT_OK =
  qw(is_file_in_archive extract_file_from_archive extract_single_file extract_thumbnail generate_thumbnail get_filelist is_cbw parse_cbw_urls cbw_content_digest detect_cbw_image validate_cbw_image);

use constant CBW_MAX_XML_BYTES      => 1024 * 1024;
use constant CBW_MAX_URL_BYTES      => 8192;
use constant CBW_MAX_PAGES          => 10_000;
use constant CBW_MAX_REDIRECTS      => 5;
use constant CBW_MAX_RESPONSE_BYTES => 64 * 1024 * 1024;
use constant CBW_MAX_DIMENSION      => 30_000;
use constant CBW_MAX_PIXELS         => 100_000_000;

my %CBW_URL_CACHE;

sub is_pdf {
    my ( $filename, $dirs, $suffix ) = fileparse( $_[0], qr/\.[^.]*/ );
    return ( $suffix eq ".pdf" );
}

# CBW (ComicBookWeb) files are XML metadata files that reference remote page images by URL.
# They contain no image data themselves; LRR proxies and caches those images on demand.
# See https://wiki.mobileread.com/wiki/CBW
sub is_cbw {
    my ( $filename, $dirs, $suffix ) = fileparse( $_[0], qr/\.[^.]*/ );
    return ( lc($suffix) eq ".cbw" );
}

# parse_cbw_xml($xml)
# Pure function: parses CBW XML content and returns an ordered list of page image URLs.
# Handles <Variables> ({Key} substitution) and the [format:a-b] range syntax in Image URLs.
# Dies with a descriptive message if the XML is malformed or contains no images.
sub parse_cbw_xml ($xml) {

    die "CBW file is empty.\n" unless defined($xml) && length($xml);
    die "CBW file is too large.\n" if length($xml) > CBW_MAX_XML_BYTES;

    # xml(1) keeps attribute case intact (Url, Key, Value...) and enforces XML semantics.
    my $dom = Mojo::DOM->new->xml(1)->parse($xml);

    my $root = $dom->at('WebComic');
    die "Not a valid CBW file: missing <WebComic> root element.\n" unless $root;

    # Collect reusable textual variables, keyed by their Key attribute.
    my %variables;
    for my $var ( $root->find('Variables > Variable')->each ) {
        my $key = $var->attr('Key');
        next unless defined $key;
        $variables{$key} = $var->attr('Value') // '';
    }

    my @urls;
    for my $image ( $root->find('Images > Image')->each ) {

        # Url is the only supported PageLinkType (and the default when omitted).
        my $type = $image->attr('PageLinkType');
        next if defined($type) && lc($type) ne 'url';

        my $url = $image->attr('Url');
        next unless defined($url) && length($url);

        # Substitute {Key} tokens with their variable values.
        $url =~ s/\{([^}]+)\}/ defined $variables{$1} ? $variables{$1} : "{$1}" /ge;

        die "CBW image URL is too long.\n" if length($url) > CBW_MAX_URL_BYTES;
        _parse_cbw_url($url);
        my @expanded = expand_cbw_range($url);
        die "CBW file contains too many image pages.\n" if @urls + @expanded > CBW_MAX_PAGES;
        push @urls, @expanded;
    }

    die "No image URLs found in CBW file.\n" unless @urls;
    return @urls;
}

# expand_cbw_range($url)
# Expands the [format:a-b] range syntax in a single CBW image URL into a list of URLs.
# format is a number-format string ("0", "00"...) giving the zero-padding width.
# e.g. "http://cdn/[00:8-11].jpg" -> 08.jpg, 09.jpg, 10.jpg, 11.jpg
# URLs without a range are returned unchanged as a single-element list.
sub expand_cbw_range ($url) {

    # Non-greedy prefix so the FIRST [format:N-M] is expanded when a URL
    # contains more than one bracket pair (unlikely in practice, but correct).
    if ( $url =~ /^(.*?)\[([^:\]]*):(\d+)-(\d+)\](.*)$/ ) {
        my ( $prefix, $format, $start, $end, $suffix ) = ( $1, $2, $3, $4, $5 );

        my $width = length($format);
        my $count = abs( $end - $start ) + 1;
        die "CBW range expands to too many image pages.\n" if $count > CBW_MAX_PAGES;
        my @expanded;

        # Ranges can run in either direction.
        my @range = $start <= $end ? ( $start .. $end ) : reverse( $end .. $start );
        for my $n (@range) {
            push @expanded, $prefix . sprintf( "%0*d", $width, $n ) . $suffix;
        }
        return @expanded;
    }

    return ($url);
}

# parse_cbw_urls($file)
# Reads a CBW file from disk and returns its ordered list of page image URLs.
sub parse_cbw_urls ($file) {
    my ( $xml, $digest ) = _read_cbw_document($file);
    my $cached = $CBW_URL_CACHE{$file};
    if ( !$cached || $cached->{digest} ne $digest ) {
        $CBW_URL_CACHE{$file} = { digest => $digest, urls => [ parse_cbw_xml($xml) ] };
    }
    return @{ $CBW_URL_CACHE{$file}{urls} };
}

sub _read_cbw_document ($file) {
    open_path_or_die( my $fh, '<:raw', $file );
    my $xml = '';
    my $read = read( $fh, $xml, CBW_MAX_XML_BYTES + 1 );
    close($fh);
    die "Could not read CBW file '$file': $!\n" unless defined $read;
    die "CBW file is too large.\n" if length($xml) > CBW_MAX_XML_BYTES;
    return ( $xml, sha256_hex($xml) );
}

sub cbw_content_digest ($file) {
    my ( undef, $digest ) = _read_cbw_document($file);
    return $digest;
}

# Derives a synthetic page filename for a CBW page from its 1-based index and source URL.
# The extension is taken from the URL (stripping any query/fragment), defaulting to jpg.
# The index is zero-padded so the reader's natural sort keeps pages in XML order.
sub cbw_page_name ( $index, $url, $total ) {

    my $ext = "jpg";
    ( my $clean = $url ) =~ s/[?#].*$//;
    if ( $clean =~ /\.([A-Za-z0-9]+)$/ ) {
        my $candidate = lc($1);
        $ext = $candidate if $candidate =~ /\A(?:avif|bmp|gif|heic|heif|jpe?g|jfif|jxl|png|webp)\z/;
    }

    my $width = length("$total");
    return sprintf( "%0*d.%s", $width, $index, $ext );
}

# fetch_cbw_image($url)
# Downloads a single CBW page image and returns its raw bytes.
# The server proxies remote images so the rest of the stack (thumbnails, resizing, page cache)
# works unchanged. Callers (get_page_data) already cache the result, so each image is fetched once.
sub fetch_cbw_image ($url) {
    my $current = Mojo::URL->new($url);
    for my $hop ( 0 .. CBW_MAX_REDIRECTS ) {
        my ( $validated, $ip ) = _validate_cbw_url($current);
        my $res = _fetch_cbw_http_hop( $validated, $ip );

        if ( $res->is_redirect ) {
            die "Too many redirects while fetching CBW image.\n" if $hop == CBW_MAX_REDIRECTS;
            my $location = $res->headers->location;
            die "CBW redirect is missing a Location header.\n" unless defined $location && length $location;
            $current = Mojo::URL->new($location)->to_abs($validated);
            next;
        }

        die "Failed to fetch CBW image from $validated: " . $res->code . " " . $res->message . "\n"
          unless $res->is_success;
        my $body = $res->body;
        die "CBW image response is too large.\n" if length($body) > CBW_MAX_RESPONSE_BYTES;
        validate_cbw_image( $body, $res->headers->content_type );
        return $body;
    }
    die "Too many redirects while fetching CBW image.\n";
}

sub _parse_cbw_url ($value) {
    die "CBW image URL is too long.\n" if !defined($value) || length($value) > CBW_MAX_URL_BYTES;
    my $url = ref($value) ? $value->clone : Mojo::URL->new($value);
    my $scheme = lc( $url->scheme // '' );
    die "CBW image URL must use HTTP or HTTPS.\n" unless $scheme eq 'http' || $scheme eq 'https';
    die "CBW image URL must not contain credentials.\n" if defined $url->userinfo && length $url->userinfo;
    my $host = $url->host // '';
    die "CBW image URL is missing a host.\n" unless length $host;
    my $port = $url->port // ( $scheme eq 'https' ? 443 : 80 );
    die "CBW image URL uses an unsafe port.\n" unless $port == 80 || $port == 443;
    return $url;
}

sub _validate_cbw_url ($value) {
    my $url = _parse_cbw_url($value);
    my @addresses = _resolve_cbw_host_addresses( $url->host, $url->port // ( $url->scheme eq 'https' ? 443 : 80 ) );
    die "Could not resolve CBW image host.\n" unless @addresses;
    for my $address (@addresses) {
        die "CBW image host resolved to an unsafe address.\n" unless _is_public_ip($address);
    }
    @addresses = sort @addresses;
    return ( $url, $addresses[0] );
}

sub _resolve_cbw_host_addresses ( $host, $port = 443 ) {
    $host =~ s/^\[|\]$//g;
    my ( $error, @resolved ) = getaddrinfo( $host, $port, { socktype => SOCK_STREAM } );
    die "Could not resolve CBW image host: $error\n" if $error;
    my %seen;
    my @addresses;
    for my $item (@resolved) {
        my $family = $item->{family};
        my $packed = $family == AF_INET  ? ( unpack_sockaddr_in( $item->{addr} ) )[1]
          : $family == AF_INET6 ? ( unpack_sockaddr_in6( $item->{addr} ) )[1]
          : undef;
        next unless defined $packed;
        my $address = inet_ntop( $family, $packed );
        push @addresses, $address unless $seen{$address}++;
    }
    return @addresses;
}

sub _is_public_ip ($address) {
    if ( my $v4 = Socket::inet_pton( AF_INET, $address ) ) {
        my $n = unpack( 'N', $v4 );
        return 0 if ( $n & 0xff000000 ) == 0x00000000;
        return 0 if ( $n & 0xff000000 ) == 0x0a000000;
        return 0 if ( $n & 0xffc00000 ) == 0x64400000;
        return 0 if ( $n & 0xff000000 ) == 0x7f000000;
        return 0 if ( $n & 0xffff0000 ) == 0xa9fe0000;
        return 0 if ( $n & 0xfff00000 ) == 0xac100000;
        return 0 if ( $n & 0xffffff00 ) == 0xc0000000;
        return 0 if ( $n & 0xffffff00 ) == 0xc0000200;
        return 0 if ( $n & 0xffffff00 ) == 0xc01fc400;
        return 0 if ( $n & 0xffffff00 ) == 0xc034c100;
        return 0 if ( $n & 0xffffff00 ) == 0xc0586300;
        return 0 if ( $n & 0xffff0000 ) == 0xc0a80000;
        return 0 if ( $n & 0xffffff00 ) == 0xc0af3000;
        return 0 if ( $n & 0xfffe0000 ) == 0xc6120000;
        return 0 if ( $n & 0xffffff00 ) == 0xc6336400;
        return 0 if ( $n & 0xffffff00 ) == 0xcb007100;
        return 0 if ( $n & 0xf0000000 ) == 0xe0000000;
        return 0 if ( $n & 0xf0000000 ) == 0xf0000000;
        return 1;
    }

    my $v6 = Socket::inet_pton( AF_INET6, $address ) or return 0;
    my @b = unpack( 'C16', $v6 );
    if ( join( '', @b[ 0 .. 9 ] ) eq ( '0' x 10 ) && $b[10] == 255 && $b[11] == 255 ) {
        return _is_public_ip( join '.', @b[ 12 .. 15 ] );
    }
    return 0 unless ( $b[0] & 0xe0 ) == 0x20;    # globally routable 2000::/3 only
    return 0 if $b[0] == 0x20 && $b[1] == 0x01 && $b[2] == 0x0d && $b[3] == 0xb8;
    return 1;
}

sub _fetch_cbw_http_hop ( $url, $ip ) {
    my $host = $url->host;
    ( my $bare_ip = $ip ) =~ s/^\[|\]$//g;
    my $pinned = $url->clone->host( $bare_ip =~ /:/ ? "[$bare_ip]" : $bare_ip );
    my $port = $url->port // ( $url->scheme eq 'https' ? 443 : 80 );
    my $host_header = $host;
    $host_header .= ":$port" if !( $url->scheme eq 'https' && $port == 443 ) && !( $url->scheme eq 'http' && $port == 80 );

    my $ua = _new_cbw_user_agent( $url->scheme, $host );
    my $tx = $ua->get( $pinned => { Host => $host_header, 'User-Agent' => 'Mozilla/5.0 (compatible; LANraragi CBW proxy)' } );
    my $res = $tx->result;
    _verify_cbw_peer( $tx->remote_address, $bare_ip );
    return $res;
}

sub _new_cbw_user_agent ( $scheme, $host ) {
    my $ua = Mojo::UserAgent->new
      ->connect_timeout(10)->request_timeout(30)->inactivity_timeout(10)
      ->max_redirects(0)->max_connections(0)->max_response_size(CBW_MAX_RESPONSE_BYTES);
    $ua->proxy->http(undef)->https(undef);
    if ( $scheme eq 'https' ) {
        $ua->tls_options->{SSL_hostname} = $host;
        $ua->tls_options->{SSL_verifycn_name} = $host;
    }
    return $ua;
}

sub _verify_cbw_peer ( $remote, $validated ) {
    die "CBW connection did not report its peer address.\n" unless defined($remote) && length($remote);
    die "CBW connection peer did not match the validated address.\n" unless _same_ip( $remote, $validated );
    return 1;
}

sub _same_ip ( $left, $right ) {
    for my $family ( AF_INET, AF_INET6 ) {
        my $a = Socket::inet_pton( $family, $left );
        my $b = Socket::inet_pton( $family, $right );
        return 1 if defined($a) && defined($b) && $a eq $b;
    }
    return 0;
}

sub validate_cbw_image ( $body, $content_type ) {
    die "CBW image response is empty.\n" unless defined($body) && length($body);
    die "CBW image response is too large.\n" if length($body) > CBW_MAX_RESPONSE_BYTES;
    my $info = detect_cbw_image($body);
    my $actual = lc( $content_type // '' );
    $actual =~ s/\s*;.*$//;
    my %accepted = ( jpg => 'image/jpeg', 'image/jpg' => 'image/jpeg', 'image/x-png' => 'image/png' );
    $actual = $accepted{$actual} // $actual;
    die "CBW response Content-Type does not match its image bytes.\n" unless $actual eq $info->{mime};

    _fully_decode_cbw_image( $body, $info->{width}, $info->{height} );
    return $info;
}

sub detect_cbw_image ($body) {
    my ( $format, $width, $height ) = _cbw_raster_info($body);
    die "CBW response is not a supported raster image.\n" unless $format && $width && $height;
    die "CBW image decoded dimensions are too large.\n" if $width > CBW_MAX_DIMENSION || $height > CBW_MAX_DIMENSION;
    die "CBW image has too many decoded pixels.\n" if $width * $height > CBW_MAX_PIXELS;
    my %mime = (
        avif => 'image/avif', bmp => 'image/bmp', gif => 'image/gif', heic => 'image/heic',
        heif => 'image/heif', jpeg => 'image/jpeg', jxl => 'image/jxl', png => 'image/png', webp => 'image/webp'
    );
    return { format => $format, mime => $mime{$format}, width => $width, height => $height };
}

sub _cbw_raster_info ($body) {
    if ( substr( $body, 0, 8 ) eq "\x89PNG\r\n\x1a\n" && length($body) >= 24 && substr( $body, 12, 4 ) eq 'IHDR' ) {
        return ( 'png', unpack( 'N', substr( $body, 16, 4 ) ), unpack( 'N', substr( $body, 20, 4 ) ) );
    }
    if ( $body =~ /\AGIF8[79]a/s && length($body) >= 10 ) {
        return ( 'gif', unpack( 'v', substr( $body, 6, 2 ) ), unpack( 'v', substr( $body, 8, 2 ) ) );
    }
    if ( substr( $body, 0, 2 ) eq 'BM' && length($body) >= 26 ) {
        return ( 'bmp', abs( unpack( 'l<', substr( $body, 18, 4 ) ) ), abs( unpack( 'l<', substr( $body, 22, 4 ) ) ) );
    }
    if ( substr( $body, 0, 2 ) eq "\xff\xd8" ) {
        my ( $width, $height ) = _jpeg_dimensions($body);
        return ( 'jpeg', $width, $height ) if $width && $height;
    }
    if ( substr( $body, 0, 4 ) eq 'RIFF' && substr( $body, 8, 4 ) eq 'WEBP' ) {
        my ( $width, $height ) = _webp_dimensions($body);
        return ( 'webp', $width, $height ) if $width && $height;
    }

    my $format;
    if ( length($body) >= 12 && substr( $body, 4, 4 ) eq 'ftyp' ) {
        my $brands = substr( $body, 8, 64 );
        $format = 'avif' if $brands =~ /avi[fs]/;
        $format //= 'heic' if $brands =~ /hei[cf]/;
        $format //= 'heif' if $brands =~ /mif1/;
    } elsif ( substr( $body, 0, 2 ) eq "\xff\x0a" || substr( $body, 0, 12 ) eq "\x00\x00\x00\x0cJXL \r\n\x87\n" ) {
        $format = 'jxl';
    }
    if ($format) {
        my ( $width, $height ) = _decoded_image_dimensions($body);
        return ( $format, $width, $height ) if $width && $height;
    }
    return;
}

sub _jpeg_dimensions ($body) {
    my $offset = 2;
    while ( $offset + 4 <= length($body) ) {
        $offset++ while $offset < length($body) && ord( substr( $body, $offset, 1 ) ) != 0xff;
        $offset++ while $offset < length($body) && ord( substr( $body, $offset, 1 ) ) == 0xff;
        last if $offset >= length($body);
        my $marker = ord( substr( $body, $offset++, 1 ) );
        next if $marker == 0x01 || ( $marker >= 0xd0 && $marker <= 0xd9 );
        last if $offset + 2 > length($body);
        my $length = unpack( 'n', substr( $body, $offset, 2 ) );
        last if $length < 2 || $offset + $length > length($body);
        if ( ( $marker >= 0xc0 && $marker <= 0xc3 ) || ( $marker >= 0xc5 && $marker <= 0xc7 )
            || ( $marker >= 0xc9 && $marker <= 0xcb ) || ( $marker >= 0xcd && $marker <= 0xcf ) ) {
            return ( unpack( 'n', substr( $body, $offset + 5, 2 ) ), unpack( 'n', substr( $body, $offset + 3, 2 ) ) );
        }
        $offset += $length;
    }
    return;
}

sub _webp_dimensions ($body) {
    return unless length($body) >= 30;
    my $kind = substr( $body, 12, 4 );
    if ( $kind eq 'VP8X' ) {
        my $w = unpack( 'V', substr( $body, 24, 3 ) . "\0" ) + 1;
        my $h = unpack( 'V', substr( $body, 27, 3 ) . "\0" ) + 1;
        return ( $w, $h );
    }
    if ( $kind eq 'VP8L' && ord( substr( $body, 20, 1 ) ) == 0x2f ) {
        my $bits = unpack( 'V', substr( $body, 21, 4 ) );
        return ( ( $bits & 0x3fff ) + 1, ( ( $bits >> 14 ) & 0x3fff ) + 1 );
    }
    if ( $kind eq 'VP8 ' && substr( $body, 23, 3 ) eq "\x9d\x01\x2a" ) {
        return ( unpack( 'v', substr( $body, 26, 2 ) ) & 0x3fff, unpack( 'v', substr( $body, 28, 2 ) ) & 0x3fff );
    }
    return;
}

sub _decoded_image_dimensions ($body) {
    return unless LANraragi::Utils::Vips::is_vips_loaded();
    my ( $width, $height, $image );
    my $ok = eval {
        LANraragi::Utils::Vips::init('LANraragi');
        $image = LANraragi::Utils::Vips::new_from_buffer($body);
        $width = LANraragi::Utils::Vips::width($image);
        $height = LANraragi::Utils::Vips::height($image);
        1;
    };
    eval { LANraragi::Utils::Vips::unref_image($image) if $image; 1 };
    return unless $ok && $width && $height;
    return ( $width, $height );
}

sub _fully_decode_cbw_image ( $body, $expected_width, $expected_height ) {
    die "CBW raster validation requires libvips.\n" unless LANraragi::Utils::Vips::is_vips_loaded();
    my ( $image, $probe );
    my $ok = eval {
        LANraragi::Utils::Vips::init('LANraragi');
        $image = LANraragi::Utils::Vips::new_from_buffer($body);
        die "decoded dimensions changed during validation\n"
          unless LANraragi::Utils::Vips::width($image) == $expected_width
          && LANraragi::Utils::Vips::height($image) == $expected_height;
        $probe = LANraragi::Utils::Vips::resize_to_width( $body, 1 );
        LANraragi::Utils::Vips::read_pixels($probe);
        1;
    };
    my $error = $@;
    eval { LANraragi::Utils::Vips::unref_image($probe) if $probe; 1 };
    eval { LANraragi::Utils::Vips::unref_image($image) if $image; 1 };
    die "CBW raster image could not be fully decoded.\n" unless $ok && !$error;
    return 1;
}

# use a resizer to make a thumbnail, height = 500px (view in index is 280px tall)
# If use_hq is true, highest-quality resizing will be used (if the resizer support different quality levels).
# $format should be "avif", "jxl", or "jpg".
sub generate_thumbnail ( $data, $thumb_path, $use_hq, $format ) {
    my $quality = 50;
    $quality = 80 if $use_hq;

    my $resized = get_resizer()->resize_thumbnail( $data, $quality, $use_hq, $format );
    if ( defined($resized) ) {
        open my $fh, '>:raw', $thumb_path or die "Cannot write to '$thumb_path': $!";
        print $fh $resized;
        close($fh);
    } else {
        my $logger = get_logger( "Archive", "lanraragi" );
        $logger->debug("Couldn't create thumbnail!");
    }
}

# Extracts a thumbnail from the specified archive ID and page. Returns the path to the thumbnail.
# Non-cover thumbnails land in a folder named after the ID.
# Specify $set_cover if you want the given page to be placed as the cover thumbnail instead.
# Thumbnails will be generated at low quality by default unless you specify use_hq=1.
sub extract_thumbnail ( $thumbdir, $id, $page, $set_cover, $use_hq ) {

    my $logger = get_logger( "Archive", "lanraragi" );

    # JPG is used for thumbnails by default; AVIF and JXL are alternative formats.
    my $use_avif = LANraragi::Model::Config->enable_avif_thumbnails;
    my $use_jxl  = LANraragi::Model::Config->get_jxlthumbpages;
    my $format   = $use_avif ? 'avif' : $use_jxl ? 'jxl' : 'jpg';

    # Another subfolder with the first two characters of the id is used for FS optimization.
    my $subfolder = substr( $id, 0, 2 );
    make_path("$thumbdir/$subfolder");

    my $redis = LANraragi::Model::Config->get_redis;
    my $file  = get_archive_path( $redis, $id );

    # Get first image from archive using filelist
    my @filelist        = get_filelist($file, $id);
    my $requested_image = $filelist[ $page > 0 ? $page - 1 : 0 ];

    die "Requested image not found: $id page $page" unless $requested_image;
    $logger->debug("Extracting thumbnail for $id page $page from $requested_image");

    # Extract requested image to temp dir if it doesn't already exist
    my $arcimg = extract_single_file( $file, $requested_image );

    # For CBW archives, stash the downloaded bytes in PageCache so the
    # reader (get_page_data) hits cache instead of re-fetching from remote.
    if ( is_cbw($file) ) {
        put( "page/$id/" . cbw_content_digest($file) . "/$requested_image", $arcimg );
    }

    my $thumbname;
    unless ($set_cover) {

        # Non-cover thumbnails land in a dedicated folder.
        $thumbname = "$thumbdir/$subfolder/$id/$page.$format";
        make_path("$thumbdir/$subfolder/$id");
    } else {

        $thumbname = "$thumbdir/$subfolder/$id.$format";

        # For cover thumbnails, grab the SHA-1 hash for tag research.
        # That way, no need to repeat a costly extraction later.
        my $shasum = shasum_str( $arcimg, 1 );
        $logger->debug("Setting thumbnail hash: $shasum");
        $redis->hset( $id, "thumbhash", $shasum );
        $redis->quit();
    }

    # Thumbnail generation
    no warnings 'experimental::try';
    try {
        generate_thumbnail( $arcimg, $thumbname, $use_hq, $format );
    } catch ($e) {
        $logger->error("Thumbnail generation failed for archive '$file' entry '$requested_image' -> '$thumbname': $e");
        die $e;
    }

    return $thumbname;
}

#magical sort function used below
sub expand {
    my $file = shift;
    $file =~ s{(\d+)}{sprintf "%04d", $1}eg;
    return lc($file);
}

# Returns a list of all the files contained in the given archive with corresponding archive ID.
# Reads through a Redis-backed cache (`pagefiles` field on the archive hash) to avoid
# re-opening and re-scanning the archive on every reader open. Callers that mutate the
# underlying file (Shinobu arcsize mismatch, change_archive_id) must HDEL `pagefiles`.
sub get_filelist ( $archive, $arcid, $force = 0, $cache_redis_override = undef, $clear_cache = undef, $logger_override = undef ) {

    my $logger = $logger_override // get_logger( "Archive", "lanraragi" );

    my $cache_redis = defined($cache_redis_override) ? $cache_redis_override : eval { LANraragi::Model::Config->get_redis };
    my $cbw_digest = is_cbw($archive) ? cbw_content_digest($archive) : undef;
    if ( $cache_redis && $arcid && !$force ) {
        my $cached = eval { $cache_redis->hget( $arcid, "pagefiles" ) };
        if ( defined $cbw_digest && defined $cached ) {
            my $cached_digest = eval { $cache_redis->hget( $arcid, "pagefiles_cbw_digest" ) };
            if ( !defined($cached_digest) || $cached_digest ne $cbw_digest ) {
                eval { $cache_redis->hdel( $arcid, "pagefiles", "pagefiles_cbw_digest" ) };
                $clear_cache ? $clear_cache->($arcid) : clear_by_id($arcid);
                $cached = undef;
            }
        }
        if ( defined $cached && length $cached ) {
            my $list = eval { thaw($cached) };
            if ( ref $list eq 'ARRAY' && @$list ) {
                eval { $cache_redis->quit };
                return @$list;
            }
        }
    }

    my @files = ();

    if ( is_cbw($archive) ) {

        # CBW files list remote page URLs in authoritative order.
        # We return synthetic page names (0001.jpg, 0002.png...) whose index maps back to the URL.
        # No cover/credit reordering here: the XML order is the intended reading order.
        my @urls  = parse_cbw_urls($archive);
        my $total = scalar @urls;

        for my $i ( 1 .. $total ) {
            push @files, cbw_page_name( $i, $urls[ $i - 1 ], $total );
        }

        if ( $cache_redis && $arcid && @files ) {
            eval {
                $cache_redis->hset( $arcid, "pagefiles", nfreeze( \@files ) );
                $cache_redis->hset( $arcid, "pagefiles_cbw_digest", $cbw_digest );
            };
            eval { $cache_redis->quit };
        } elsif ($cache_redis) {
            eval { $cache_redis->quit };
        }
        return @files;
    }

    if ( is_pdf($archive) ) {
        # For pdfs, extraction returns images from 1.jpg to x.jpg, where x is the pdf pagecount.
        $archive = decode_utf8($archive);    # Decode path before passing it to VIPS
        # This SHOULD only read header data = fast
        my $pdf = LANraragi::Utils::Vips::vips_image_new_from_file($archive);
        my $pages = LANraragi::Utils::Vips::vips_image_get_n_pages($pdf);

        for my $num ( 1 .. $pages ) {
            push @files, "$num.jpg";
        }
        LANraragi::Utils::Vips::unref_image($pdf);
    } else {

        my $r = Archive::Libarchive::ArchiveRead->new;
        $r->support_filter_all;
        $r->support_format_all;

        my $ret = $r->open_filename( $archive, 10240 );
        if ( $ret != ARCHIVE_OK ) {
            my $open_filename_errno     = $r->errno;
            my $open_filename_strerr    = strerror($open_filename_errno);
            my $archive_exists          = -e $archive ? 'yes' : 'no';
            my $archive_readable        = -r $archive ? 'yes' : 'no';
            my $archive_size            = -e $archive ? (-s _) : 'NA';
            my $open_filename_err   = "Couldn't open archive '$archive' (id:$arcid, exists:$archive_exists; readable:$archive_readable; size:$archive_size)"
                . "libarchive: " . $r->error_string . " (errno $open_filename_errno: $open_filename_strerr)";
            $logger->error($open_filename_err);
            die $open_filename_err;
        }

        my $e = Archive::Libarchive::Entry->new;

        # Lazily constructed only when the first Apple-signature-like path is encountered.
        # Avoids opening the archive a second time for archives with no such entries,
        # and avoids re-opening per matching entry for archives that have many.
        my $peek;

        while ( $r->next_header($e) == ARCHIVE_OK ) {

            my $filesize = ( $e->size_is_set eq 64 ) ? $e->size : 0;
            my $filename = $e->pathname;

            unless ( is_image($filename) ) {
                $r->read_data_skip;
                next;
            }

            if ( is_apple_signature_like_path($filename) ) {
                $peek //= Archive::Libarchive::Peek->new( filename => $archive );
                if ( is_apple_signature( $peek, $filename ) ) {
                    $r->read_data_skip;
                    next;
                }
            }

            push @files, $filename;
            $r->read_data_skip;
        }

    }

    @files = sort { &expand($a) cmp &expand($b) } @files;

    # Move front cover pages to the start of a gallery, and miscellaneous pages such as translator credits to the end.
    my @cover_pages  = grep { /^(?!.*(back|end|rear|recover|discover)).*cover.*/i } @files;
    my @credit_pages = grep { /^end_card_save_file|notes\.[^\.]*$|note\.[^\.]*$|^artist_info|credit|^999.*/i } @files;

    # Get all the leftover pages
    my %credit_hash = map  { $_ => 1 } @credit_pages;
    my %cover_hash  = map  { $_ => 1 } @cover_pages;
    my @other_pages = grep { !$credit_hash{$_} && !$cover_hash{$_} } @files;
    @files = ( @cover_pages, @other_pages, @credit_pages );

    # Persist the final ordered list so the next call can skip the extraction.
    # Use Storable rather than JSON: filenames in archives can be non-UTF-8 bytes.
    if ( $cache_redis && $arcid && @files ) {
        eval { $cache_redis->hset( $arcid, "pagefiles", nfreeze( \@files ) ) };
        eval { $cache_redis->quit };
    } elsif ($cache_redis) {
        eval { $cache_redis->quit };
    }

    return @files;
}

# is_apple_signature(peek, path)
# Uses libarchive::peek to check AppleDouble/AppleSingle magic.
# Returns 1 if the file header matches a known Apple fork format, else 0.
sub is_apple_signature ( $peek, $path ) {
    my $logger = get_logger( "Archive", "lanraragi" );
    unless ( defined $peek && defined $path ) {
        $logger->warn("path or peek are undefined. Skipping.");
        return 0;
    }

    $logger->debug("Checking Apple fork magic for: $path");
    my $data = eval { $peek->file($path) };
    if ( !$data ) {
        $logger->debug("Peek returned no data for $path; not ignoring by signature");
        return 0;
    }
    if ( length($data) < 8 ) {
        $logger->debug("Data too short (<8 bytes) for $path; not ignoring by signature");
        return 0;
    }

    my $prefix = substr( $data, 0, 8 );
    return 0 unless defined $prefix && length($prefix) >= 8;

    # https://ciderpress2.com/formatdoc/AppleSingle-notes.html
    # AppleSingle: 00 05 16 00, AppleDouble: 00 05 16 07; both big-endian
    my $is_applesingle = substr( $prefix, 0, 4 ) eq "\x00\x05\x16\x00";
    my $is_appledouble = substr( $prefix, 0, 4 ) eq "\x00\x05\x16\x07";

    if ($is_appledouble) {
        $logger->debug("AppleDouble magic matched for $path");
        return 1;
    }
    if ($is_applesingle) {
        $logger->debug("AppleSingle magic matched for $path");
        return 1;
    }

    $logger->debug("Apple fork magic not matched for $path");
    return 0;
}

# check if image file is garbage or should be ignored.
sub is_apple_signature_like_path ($path) {
    my $p = $path // '';
    return 1 if $p =~ m{(^|/)__MACOSX/};
    my ($name) = fileparse($p);
    return 1 if defined $name && $name =~ /^\._/;
    return 0;
}

# Uses libarchive::peek to figure out if $archive contains $file.
# Returns the exact in-archive path of the file if it exists, undef otherwise.
sub is_file_in_archive ( $archive, $wantedname ) {

    my $logger = get_logger( "Archive", "lanraragi" );

    if ( is_pdf($archive) ) {
        $logger->debug("$archive is a pdf, no sense looking for specific files");
        return;
    }

    if ( is_cbw($archive) ) {
        $logger->debug("$archive is a cbw, its pages are remote URLs with no in-archive files");
        return;
    }

    $logger->debug("Iterating files of archive $archive, looking for '$wantedname'");
    $Data::Dumper::Useqq = 1;

    my $peek = Archive::Libarchive::Peek->new( filename => $archive );
    my $found;
    my @files = $peek->files;

    for my $file (@files) {
        $logger->debug( "Found file " . Dumper($file) );
        my ( $name, $path, $suffix ) = fileparse( $file, qr/\.[^.]*/ );

        # If the end of the file contains $wantedname we're good
        if ( "$name$suffix" =~ /$wantedname$/ ) {
            $logger->debug("OK!");
            $found = $file;
            last;
        }
    }

    return $found;
}

# Extract $file from $archive to $destination and returns the filesystem path it's extracted to.
# If the file doesn't exist in the archive, this will still create a file, but empty.
sub extract_single_file_to_file ( $archive, $filepath, $destination ) {

    my $logger = get_logger( "Archive", "lanraragi" );

    my $outfile = "$destination/$filepath";
    $logger->debug("Output for single file extraction: $outfile");

    # Remove file from $outfile and hand the full directory to make_path
    my ( $name, $path, $suffix ) = fileparse( $outfile, qr/\.[^.]*/ );
    make_path($path);

    my $contents = extract_single_file( $archive, $filepath );

    open( my $fh, '>', $outfile )
      or die "Could not open file '$outfile' $!";
    print $fh $contents;
    close $fh;

    return $outfile;
}

sub extract_single_file ( $archive, $filepath ) {

    my $logger = get_logger( "Archive", "lanraragi" );

    # Remove file from $outfile and hand the full directory to make_path
    if ( is_cbw($archive) ) {

        # CBW page names are synthetic (0001.jpg...); the leading digits are the 1-based index into the URL list.
        my ($index) = $filepath =~ /^(\d+)/;
        die "Invalid CBW page name '$filepath'\n" unless defined $index;

        my @urls = parse_cbw_urls($archive);
        my $url  = $urls[ $index - 1 ];
        die "CBW page $index is out of range (archive has " . scalar(@urls) . " pages)\n" unless defined $url;

        $logger->debug("Fetching CBW page $index from $url");
        return fetch_cbw_image($url);
    }

    if ( is_pdf($archive) ) {

        # For pdfs the filenames are always x.jpg, so we pull the page number from that
        my $page = $filepath;
        $page =~ s/^(\d+).jpg$/$1/;

        # Decode path before passing it to VIPS
        $archive = decode_utf8($archive);
        my $pdf_page = LANraragi::Utils::Vips::pdfload_page_dpi($archive, $page - 1, LANraragi::Model::Config->get_pdfdpi);
        # This is a bit Rube Goldberg, but the rest of the stack assumes that this function returns image file data...
        my $buf = LANraragi::Utils::Vips::write_to_buffer($pdf_page, ".jpg", 80);
        LANraragi::Utils::Vips::unref_image($pdf_page);
        return $buf;
    } else {

        my $contents = "";
        my $peek     = Archive::Libarchive::Peek->new( filename => $archive );

        # Filename can arrive in three flavors depending on caller:
        #   - already libarchive-shaped UTF-8 (from a fresh ArchiveRead walk)
        #   - redis_encode'd (when the name was round-tripped through Redis)
        #   - redis_decode'd (when the cached pagefiles list was decoded once already)
        # Try all three before giving up.
        $contents = $peek->file($filepath)
                 // $peek->file(redis_encode($filepath))
                 // $peek->file(redis_decode($filepath));
        if (defined($contents)) {
            $logger->debug("Found file $filepath in archive $archive");
        } else {
            $logger->debug("Could not extract '$filepath' from $archive (tried raw, encoded, decoded)");
        }

        return $contents;
    }
}

# Variant for plugins.
# Extracts the file to a folder in /temp/plugin.
sub extract_file_from_archive ( $archive, $filename ) {

    my $path = get_temp . "/plugin";
    mkdir $path;

    my $tmp = tempdir( DIR => $path, CLEANUP => 1 );
    return extract_single_file_to_file( $archive, $filename, $tmp );
}

1;
