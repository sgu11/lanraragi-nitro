use strict;
use warnings;
use utf8;

use File::Temp qw(tempfile);
use Image::Magick;
use Mojo::Message::Response;
use Test::More;

use LANraragi::Utils::Archive ();

{
    package FakeCBWRedis;
    sub new { bless { hash => {} }, shift }
    sub hget { return $_[0]{hash}{ $_[1] }{ $_[2] } }
    sub hset { $_[0]{hash}{ $_[1] }{ $_[2] } = $_[3]; return 1 }
    sub hdel { my ( $self, $id, @fields ) = @_; delete $self->{hash}{$id}{$_} for @fields; return 1 }
    sub quit { return 1 }
}

sub dies_like (&$;$) {
    my ( $code, $pattern, $name ) = @_;
    eval { $code->() };
    like( $@, $pattern, $name );
}

sub png_header {
    my ( $width, $height ) = @_;
    return "\x89PNG\r\n\x1a\n" . pack( "N", 13 ) . "IHDR" . pack( "N N", $width, $height ) . "\x08\x02\x00\x00\x00";
}

sub png_blob {
    my ( $width, $height ) = @_;
    my $image = Image::Magick->new( size => "${width}x${height}" );
    $image->ReadImage('xc:red');
    return $image->ImageToBlob( magick => 'png' );
}

subtest "CBW XML and expansion are bounded before allocation" => sub {
    dies_like { LANraragi::Utils::Archive::parse_cbw_xml( "x" x ( 1024 * 1024 + 1 ) ) }
      qr/too large/i, "oversized XML is rejected";

    my $too_many = '<WebComic><Images><Image Url="https://example.com/[00000:1-10001].jpg" /></Images></WebComic>';
    dies_like { LANraragi::Utils::Archive::parse_cbw_xml($too_many) }
      qr/too many/i, "oversized range is rejected without expanding it";

    my $long_url = "https://example.com/" . ( "a" x 8200 ) . ".jpg";
    my $xml = qq{<WebComic><Images><Image Url="$long_url" /></Images></WebComic>};
    dies_like { LANraragi::Utils::Archive::parse_cbw_xml($xml) }
      qr/URL is too long/i, "oversized page URL is rejected";
};

subtest "URL validation rejects SSRF targets and preserves public HTTPS" => sub {
    dies_like { LANraragi::Utils::Archive::_validate_cbw_url('file:///etc/passwd') }
      qr/http/i, "non-HTTP scheme is rejected";
    dies_like { LANraragi::Utils::Archive::_validate_cbw_url('https://user:pass@example.com/a.jpg') }
      qr/credentials/i, "URL credentials are rejected";
    dies_like { LANraragi::Utils::Archive::_validate_cbw_url('http://example.com:22/a.jpg') }
      qr/port/i, "unsafe port is rejected";

    no warnings 'redefine';
    local *LANraragi::Utils::Archive::_resolve_cbw_host_addresses = sub { return ('127.0.0.1') };
    dies_like { LANraragi::Utils::Archive::_validate_cbw_url('https://example.com/a.jpg') }
      qr/unsafe address/i, "loopback resolution is rejected";

    local *LANraragi::Utils::Archive::_resolve_cbw_host_addresses = sub { return ( '93.184.216.34', '10.0.0.1' ) };
    dies_like { LANraragi::Utils::Archive::_validate_cbw_url('https://example.com/a.jpg') }
      qr/unsafe address/i, "mixed public/private DNS answers are rejected";

    local *LANraragi::Utils::Archive::_resolve_cbw_host_addresses = sub { return ('93.184.216.34') };
    my ( $url, $ip ) = LANraragi::Utils::Archive::_validate_cbw_url('https://example.com/a.jpg');
    is( $url->host, 'example.com', "public HTTPS hostname is preserved" );
    is( $ip, '93.184.216.34', "validated public peer is pinned" );
};

subtest "raster validation uses bytes, MIME and decoded dimensions" => sub {
    my $png = png_blob( 640, 480 );
    my $info = LANraragi::Utils::Archive::validate_cbw_image( $png, 'image/png' );
    is_deeply( $info, { format => 'png', mime => 'image/png', width => 640, height => 480 },
        "valid PNG is detected from magic and dimensions" );

    dies_like { LANraragi::Utils::Archive::validate_cbw_image( $png, 'image/jpeg' ) }
      qr/Content-Type/i, "MIME/magic mismatch is rejected";
    dies_like { LANraragi::Utils::Archive::validate_cbw_image( '<svg xmlns="http://www.w3.org/2000/svg"/>', 'image/svg+xml' ) }
      qr/raster|SVG/i, "SVG is rejected";
    dies_like { LANraragi::Utils::Archive::validate_cbw_image( png_header( 50_000, 50_000 ), 'image/png' ) }
      qr/dimensions|pixels/i, "decoded pixel bomb is rejected";
    dies_like { LANraragi::Utils::Archive::validate_cbw_image( png_header( 640, 480 ), 'image/png' ) }
      qr/fully decoded/i, "header-only fake PNG is rejected by the decoder";
};

subtest "same-size CBW replacement invalidates the parsed URL memo" => sub {
    my ( $fh, $path ) = tempfile( SUFFIX => '.cbw' );
    my $one = '<WebComic><Images><Image Url="https://example.com/a.jpg" /></Images></WebComic>';
    my $two = '<WebComic><Images><Image Url="https://example.com/b.jpg" /></Images></WebComic>';
    is( length($one), length($two), "replacement fixture has the same byte size" );
    print {$fh} $one;
    close $fh;

    my @first = LANraragi::Utils::Archive::parse_cbw_urls($path);
    is( $first[0], 'https://example.com/a.jpg', "first content is parsed" );

    open my $replace, '>:raw', $path or die $!;
    print {$replace} $two;
    close $replace;
    my @second = LANraragi::Utils::Archive::parse_cbw_urls($path);
    is( $second[0], 'https://example.com/b.jpg', "content digest replaces same-size cached URLs" );
};

subtest "CBW digest closes Redis filelist and page variant caches" => sub {
    my ( $fh, $path ) = tempfile( SUFFIX => '.cbw' );
    my $one = '<WebComic><Images><Image Url="https://example.com/a.jpg" /></Images></WebComic>';
    my $two = '<WebComic><Images><Image Url="https://example.com/b.jpg" /></Images></WebComic>';
    print {$fh} $one;
    close $fh;
    my $id = 'a' x 40;
    my $redis = FakeCBWRedis->new;
    my @cleared;
    my $clear_cache = sub { push @cleared, @_ };
    my $logger = bless {}, 'FakeCBWLogger';
    my @first = LANraragi::Utils::Archive::get_filelist( $path, $id, 0, $redis, $clear_cache, $logger );
    my $first_digest = $redis->{hash}{$id}{pagefiles_cbw_digest};
    is_deeply( \@first, ['1.jpg'], "first deterministic page list is persisted" );

    open my $replace, '>:raw', $path or die $!;
    print {$replace} $two;
    close $replace;
    my @second = LANraragi::Utils::Archive::get_filelist( $path, $id, 0, $redis, $clear_cache, $logger );
    isnt( $redis->{hash}{$id}{pagefiles_cbw_digest}, $first_digest, "same-size replacement changes authoritative digest" );
    is_deeply( \@cleared, [$id], "digest mismatch clears all page/crop/resize variants for the archive" );
    is_deeply( \@second, ['1.jpg'], "reader page order and deterministic names remain stable" );
};

subtest "every redirect hop is revalidated before the pinned request" => sub {
    my @requested;
    my @resolved;
    no warnings 'redefine';
    local *LANraragi::Utils::Archive::_resolve_cbw_host_addresses = sub {
        my ($host) = @_;
        push @resolved, $host;
        return $host eq 'public.example' ? ('93.184.216.34') : ('10.0.0.8');
    };
    local *LANraragi::Utils::Archive::_fetch_cbw_http_hop = sub {
        my ( $url, $ip ) = @_;
        push @requested, [ $url->host, $ip ];
        my $response = Mojo::Message::Response->new->code(302);
        $response->headers->location('http://private.example/secret.png');
        return $response;
    };
    dies_like { LANraragi::Utils::Archive::fetch_cbw_image('https://public.example/start.png') }
      qr/unsafe address/i, "redirect to a private address is rejected";
    is_deeply( \@requested, [ [ 'public.example', '93.184.216.34' ] ],
        "private redirect is rejected before any request reaches it" );
    is_deeply( \@resolved, [ 'public.example', 'private.example' ], "both redirect hostnames are resolved and validated" );
};

subtest "a public redirect chain preserves a legitimate static raster" => sub {
    my @requested;
    no warnings 'redefine';
    local *LANraragi::Utils::Archive::_resolve_cbw_host_addresses = sub { return ('93.184.216.34') };
    local *LANraragi::Utils::Archive::_fetch_cbw_http_hop = sub {
        my ( $url, $ip ) = @_;
        push @requested, $url->host;
        if ( @requested == 1 ) {
            my $redirect = Mojo::Message::Response->new->code(302);
            $redirect->headers->location('https://cdn.example/page.png');
            return $redirect;
        }
        my $response = Mojo::Message::Response->new->code(200)->body( png_blob( 4, 3 ) );
        $response->headers->content_type('image/png');
        return $response;
    };
    my $body = LANraragi::Utils::Archive::fetch_cbw_image('https://public.example/start.png');
    is_deeply( \@requested, [ 'public.example', 'cdn.example' ], "each public redirect hop is fetched in order" );
    is( detect_png_size($body), '4x3', "legitimate redirected PNG bytes are returned" );
};

sub detect_png_size {
    my ($body) = @_;
    return unpack( 'N', substr( $body, 16, 4 ) ) . 'x' . unpack( 'N', substr( $body, 20, 4 ) );
}

subtest "pinned peer verification fails closed" => sub {
    dies_like { LANraragi::Utils::Archive::_verify_cbw_peer( undef, '93.184.216.34' ) }
      qr/did not report/i, "missing peer address is rejected";
    dies_like { LANraragi::Utils::Archive::_verify_cbw_peer( '93.184.216.35', '93.184.216.34' ) }
      qr/did not match/i, "mismatched peer address is rejected";
    ok( LANraragi::Utils::Archive::_verify_cbw_peer( '93.184.216.34', '93.184.216.34' ),
        "matching numeric peer is accepted" );
};

subtest "CBW user agent has bounded streaming and no implicit redirect or proxy" => sub {
    my $ua = LANraragi::Utils::Archive::_new_cbw_user_agent( 'https', 'cdn.example' );
    is( $ua->max_response_size, 64 * 1024 * 1024, "streamed response has a 64 MiB hard limit" );
    is( $ua->max_redirects, 0, "automatic redirects are disabled" );
    is( $ua->max_connections, 0, "pinned connections cannot be pooled across DNS decisions" );
    ok( !defined $ua->proxy->http && !defined $ua->proxy->https, "environment proxy inheritance is disabled" );
    is( $ua->tls_options->{SSL_hostname}, 'cdn.example', "TLS SNI uses the original hostname" );
    is( $ua->tls_options->{SSL_verifycn_name}, 'cdn.example', "certificate verification uses the original hostname" );
};

done_testing();
