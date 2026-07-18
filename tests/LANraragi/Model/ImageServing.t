use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use Mojolicious;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

# Most fixtures in this file (make_page_blob, make_noisy_blob, image_dimensions)
# call Image::Magick directly, so the whole file requires a working install.
# A broken dylib (require succeeds at compile time but later calls die) used
# to abort compilation here, which also made the no-PerlMagick SKIP block
# below unreachable. Guard the load so the file skips cleanly instead.
#
# When Image::Magick's bundle is missing, its compiled .pm still registers
# an END block that dies ("Image::Magick::constant not defined") during
# interpreter cleanup, clobbering the skip exit code. We register our own
# END first (so it runs last, LIFO) and restore $? on the skip path.
our $IM_LOAD_OK;
END { $? = 0 if !$IM_LOAD_OK }

BEGIN {
    eval { require Image::Magick; 1 }
        or plan skip_all => "Image::Magick is not available: $@";
    $IM_LOAD_OK = 1;
}

use LANraragi::Model::Archive;
use LANraragi::Model::Tankoubon;
use LANraragi::Utils::ImageBorderCrop qw(CROP_ALGORITHM_VERSION);

package FakeImageHeaders {
    sub new { bless {}, shift }
    sub accept { return "" }
}

package FakeImageReq {
    sub new {
        my ( $class, $params ) = @_;
        return bless { params => $params || {}, headers => FakeImageHeaders->new }, $class;
    }

    sub param {
        my ( $self, $name ) = @_;
        return $self->{params}{$name};
    }

    sub headers { return shift->{headers} }
}

package FakeImageJob {
    sub new {
        my ( $class, $id ) = @_;
        return bless { id => $id, removed => 0 }, $class;
    }

    sub id { return shift->{id} }
    sub info { return { state => "inactive" } }
    sub remove { shift->{removed} = 1 }
}

package FakeImageMinion {
    sub new { return bless { next_id => 9000, jobs => {}, enqueued => [] }, shift }

    sub enqueue {
        my ( $self, $task, $args ) = @_;
        my $id = $self->{next_id}++;
        push @{ $self->{enqueued} }, { id => $id, task => $task, args => $args };
        $self->{jobs}{$id} = FakeImageJob->new($id);
        return $id;
    }

    sub job {
        my ( $self, $id ) = @_;
        return $self->{jobs}{$id};
    }
}

package FakeImageLogger {
    sub new { return bless {}, shift }
    sub debug { return 1 }
}

package FakeImageLockRedis {
    sub new { return bless { values => {} }, shift }

    sub get {
        my ( $self, $key ) = @_;
        return $self->{values}{$key};
    }

    sub set {
        my ( $self, $key, $value, @args ) = @_;
        my %flags = map { $args[$_] => $args[ $_ + 1 ] } grep { $_ % 2 == 0 } 0 .. $#args;
        if ( exists $flags{NX} && exists $self->{values}{$key} ) {
            return undef;
        }
        $self->{values}{$key} = $value;
        return 1;
    }

    sub del {
        my ( $self, @keys ) = @_;
        delete @{ $self->{values} }{@keys};
        return scalar @keys;
    }

    sub quit { return 1 }
}

package FakeImageController {
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }

    sub req { return shift->{req} }
    sub minion { return shift->{minion} }

    sub render {
        my ( $self, %args ) = @_;
        $self->{last_render} = \%args;
        return;
    }
}

package main;

my $thumbdir = tempdir( CLEANUP => 1 );
my $lock_redis;

sub install_config_mocks {
    no warnings 'redefine';
    *LANraragi::Model::Config::get_thumbdir = sub { return $thumbdir };
    *LANraragi::Model::Config::enable_avif_thumbnails = sub { return 0 };
    *LANraragi::Model::Config::get_jxlthumbpages = sub { return 0 };
    *LANraragi::Model::Config::get_redis_config = sub { return $lock_redis };
    *LANraragi::Model::Config::enable_resize = sub { return 0 };
}

install_config_mocks();

sub build_image_app {
    my $app = Mojolicious->new;
    $app->plugin('RenderFile');
    $app->routes->get('/archives/:id/thumbnail')->to(
        cb => sub {
            my $c = shift;
            LANraragi::Model::Archive::serve_thumbnail( $c, $c->param('id') );
        }
    );
    $app->routes->get('/archives/:id/page')->to(
        cb => sub {
            my $c = shift;
            LANraragi::Model::Archive::serve_page( $c, $c->param('id'), $c->param('path') );
        }
    );
    $app->routes->get('/tankoubons/:id/thumbnail')->to(
        cb => sub {
            my $c = shift;
            LANraragi::Model::Tankoubon::serve_tankoubon_thumbnail( $c, $c->param('id') );
        }
    );
    return Test::Mojo->new($app);
}

sub make_page_blob {
    my ( $width, $height, $background, $rect, $content ) = @_;
    my $img = Image::Magick->new( size => "${width}x${height}" );
    $img->Read("xc:$background");
    my ( $x, $y, $w, $h ) = @$rect;
    $img->Draw(
        primitive => "rectangle",
        points    => "$x,$y " . ( $x + $w - 1 ) . "," . ( $y + $h - 1 ),
        fill      => $content,
    );
    return $img->ImageToBlob( magick => "png" );
}

sub make_format_blob {
    my ( $width, $height, $format ) = @_;
    my $img = Image::Magick->new( size => "${width}x${height}" );
    $img->Read("xc:#336699");
    return $img->ImageToBlob( magick => $format );
}

sub make_noisy_blob {
    my ( $width, $height ) = @_;
    my $pixels = "";
    for my $index ( 0 .. ( $width * $height - 1 ) ) {
        $pixels .= pack(
            "C3",
            ( $index * 37 + 17 ) % 256,
            ( $index * 73 + 41 ) % 256,
            ( $index * 109 + 89 ) % 256
        );
    }

    my $img = Image::Magick->new;
    my $err = $img->BlobToImage( "P6\n$width $height\n255\n$pixels" );
    die "$err\n" if $err;
    return $img->ImageToBlob( magick => "png" );
}

sub image_dimensions {
    my ($blob) = @_;
    my $img = Image::Magick->new;
    my $err = $img->BlobToImage($blob);
    die "$err\n" if $err;
    return ( $img->Get("width"), $img->Get("height") );
}

sub missing_thumbnail_controller {
    my ( $minion, $params ) = @_;
    return FakeImageController->new(
        req    => FakeImageReq->new($params),
        minion => $minion,
    );
}

note("archive thumbnail no_fallback reuses an active per-thumbnail job");
{
    my $id = "abcdef0123456789abcdef0123456789abcdef01";
    $lock_redis = FakeImageLockRedis->new;
    my $minion = FakeImageMinion->new;

    my $first = missing_thumbnail_controller( $minion, { no_fallback => "true", page => 21 } );
    LANraragi::Model::Archive::serve_thumbnail( $first, $id );

    my $second = missing_thumbnail_controller( $minion, { no_fallback => "true", page => 21 } );
    LANraragi::Model::Archive::serve_thumbnail( $second, $id );

    is( scalar @{ $minion->{enqueued} }, 1, "only one thumbnail_task is queued for duplicate misses" );
    is( $first->{last_render}{openapi}{job}, $second->{last_render}{openapi}{job}, "duplicate callers receive the same job id" );
}

note("tankoubon thumbnail no_fallback reuses an active per-thumbnail job");
{
    my $tank_id = "TANK_1234567890";
    $lock_redis = FakeImageLockRedis->new;
    my $minion = FakeImageMinion->new;

    my $first = missing_thumbnail_controller( $minion, { no_fallback => "true" } );
    LANraragi::Model::Tankoubon::serve_tankoubon_thumbnail( $first, $tank_id );

    my $second = missing_thumbnail_controller( $minion, { no_fallback => "true" } );
    LANraragi::Model::Tankoubon::serve_tankoubon_thumbnail( $second, $tank_id );

    is( scalar @{ $minion->{enqueued} }, 1, "only one tank_thumbnail_task is queued for duplicate misses" );
    is( $first->{last_render}{openapi}{job}, $second->{last_render}{openapi}{job}, "duplicate tank callers receive the same job id" );
}

note("archive thumbnails are served as inline cacheable image responses");
{
    my $id = "abcdef0123456789abcdef0123456789abcdef01";
    make_path("$thumbdir/ab");
    open my $fh, ">", "$thumbdir/ab/$id.jpg" or die "Could not create thumbnail fixture: $!";
    binmode $fh;
    print {$fh} "\xff\xd8\xff\xd9";
    close $fh;

    my $t = build_image_app();
    $t->get_ok("/archives/$id/thumbnail")
      ->status_is(200)
      ->header_like( "Content-Type", qr{^image/jpeg}, "archive thumbnail content type is image/jpeg" )
      ->header_like( "Content-Disposition", qr{\binline\b}, "archive thumbnail is displayed inline" )
      ->header_like( "Cache-Control", qr{public, max-age=2592000, immutable}, "archive thumbnail has long cache headers" )
      ->header_like( "Vary", qr{\bAccept\b}, "archive thumbnail varies on Accept" );
}

note("archive thumbnail placeholder is served inline with cache headers");
{
    my $id = "feedfacefeedfacefeedfacefeedfacefeedface";
    my $t = build_image_app();
    $t->get_ok("/archives/$id/thumbnail")
      ->status_is(200)
      ->header_like( "Content-Type", qr{^image/png}, "archive placeholder content type is image/png" )
      ->header_like( "Content-Disposition", qr{\binline\b}, "archive placeholder is displayed inline" )
      ->header_like( "Cache-Control", qr{public, max-age=86400}, "archive placeholder has cache headers" );
}

note("tankoubon thumbnails are served as inline cacheable image responses");
{
    my $tank_id = "TANK_1234567890";
    make_path("$thumbdir/TA");
    open my $fh, ">", "$thumbdir/TA/$tank_id.jpg" or die "Could not create tank thumbnail fixture: $!";
    binmode $fh;
    print {$fh} "\xff\xd8\xff\xd9";
    close $fh;

    my $t = build_image_app();
    $t->get_ok("/tankoubons/$tank_id/thumbnail")
      ->status_is(200)
      ->header_like( "Content-Type", qr{^image/jpeg}, "tank thumbnail content type is image/jpeg" )
      ->header_like( "Content-Disposition", qr{\binline\b}, "tank thumbnail is displayed inline" )
      ->header_like( "Cache-Control", qr{public, max-age=2592000, immutable}, "tank thumbnail has long cache headers" )
      ->header_like( "Vary", qr{\bAccept\b}, "tank thumbnail varies on Accept" );
}

note("tankoubon thumbnail placeholder is served inline with cache headers");
{
    my $tank_id = "TANK_0000000000";
    my $t = build_image_app();
    $t->get_ok("/tankoubons/$tank_id/thumbnail")
      ->status_is(200)
      ->header_like( "Content-Type", qr{^image/png}, "tank placeholder content type is image/png" )
      ->header_like( "Content-Disposition", qr{\binline\b}, "tank placeholder is displayed inline" )
      ->header_like( "Cache-Control", qr{public, max-age=86400}, "tank placeholder has cache headers" );
}

note("CBW pages use the raster bytes' authoritative MIME instead of the synthetic filename suffix");
{
    my $id = "abcdefabcdefabcdefabcdefabcdefabcdefabcd";
    my $source = make_format_blob( 8, 6, "webp" );

    no warnings 'redefine';
    local *LANraragi::Model::Archive::_resolve_archive_path = sub { return "/tmp/example.cbw" };
    local *LANraragi::Model::Archive::is_cbw = sub { return 1 };
    local *LANraragi::Model::Archive::cbw_content_digest = sub { return "d" x 64 };
    local *LANraragi::Model::Archive::get_page_data = sub {
        my ( undef, undef, $metrics ) = @_;
        $metrics->{cache_status} = "miss" if defined $metrics;
        return $source;
    };
    local *LANraragi::Model::Archive::get_logger = sub { return FakeImageLogger->new };
    local *LANraragi::Model::Metrics::record_image_serving_metrics = sub { return 1 };

    my $t = build_image_app();
    $t->get_ok("/archives/$id/page?path=page-001.jpg")
      ->status_is(200)
      ->header_like( "Content-Type", qr{^image/webp}, "CBW WebP is rendered with image/webp despite the .jpg page name" )
      ->header_like( "Content-Disposition", qr{\binline\b}, "CBW WebP remains inline" );
}

note("ordinary archive pages use an image MIME derived from the page extension");
{
    my $id     = "fedcbafedcbafedcbafedcbafedcbafedcbafedc";
    my $source = make_format_blob( 8, 6, "webp" );

    no warnings 'redefine';
    local *LANraragi::Model::Archive::_resolve_archive_path = sub { return "/tmp/example.cbz" };
    local *LANraragi::Model::Archive::is_cbw = sub { return 0 };
    local *LANraragi::Model::Archive::get_page_data = sub {
        my ( undef, undef, $metrics ) = @_;
        $metrics->{cache_status} = "miss" if defined $metrics;
        return $source;
    };
    local *LANraragi::Model::Archive::get_logger = sub { return FakeImageLogger->new };
    local *LANraragi::Model::Metrics::record_image_serving_metrics = sub { return 1 };

    my $t = build_image_app();
    $t->get_ok("/archives/$id/page?path=page-001.webp")
      ->status_is(200)
      ->header_like( "Content-Type", qr{^image/webp}, "ordinary WebP page is rendered with image/webp" )
      ->header_like( "Content-Disposition", qr{\binline\b}, "ordinary WebP page remains inline" );
}

note("archive page crop=border serves and reuses a cropped page variant");
{
    my $id = "1234567890abcdef1234567890abcdef12345678";
    my $page_path = "page-001.png";
    my $source = make_page_blob( 100, 100, "#f8f8f8", [ 12, 10, 76, 82 ], "#222222" );
    $source .= "x" x 20_000;
    my $cropped = make_page_blob( 80, 86, "#222222", [ 0, 0, 80, 86 ], "#222222" );
    my %cache;
    my $extracts = 0;

    no warnings 'redefine';
    local *LANraragi::Model::Archive::get_page_data = sub {
        my ( $id, $path, $metrics ) = @_;
        $extracts++;
        $metrics->{cache_status} = "miss" if defined $metrics;
        return $source;
    };
    local *LANraragi::Model::Archive::crop_blank_borders = sub {
        return $cropped;
    };
    local *LANraragi::Model::Archive::fetch = sub {
        my ($key) = @_;
        return $cache{$key};
    };
    local *LANraragi::Model::Archive::put = sub {
        my ( $key, $value ) = @_;
        $cache{$key} = $value;
        return 1;
    };
    local *LANraragi::Model::Archive::get_logger = sub { return FakeImageLogger->new };
    local *LANraragi::Model::Metrics::record_image_serving_metrics = sub { return 1 };

    my $t = build_image_app();
    $t->get_ok("/archives/$id/page?path=$page_path&crop=border")
      ->status_is(200)
      ->header_like( "Content-Disposition", qr{\binline\b}, "cropped page is displayed inline" )
      ->header_like( "Cache-Control", qr{private, max-age=3600, immutable}, "cropped page has reader cache headers" );

    my ( $w, $h ) = image_dimensions( $t->tx->res->body );
    is( $w, 80, "cropped page width includes safety padding" );
    is( $h, 86, "cropped page height includes safety padding" );
    is( $extracts, 1, "first cropped page request extracts the original page once" );

    my $cache_key = "crop_page/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path/png";
    ok( exists $cache{$cache_key}, "cropped page variant is cached separately" );

    $t->get_ok("/archives/$id/page?path=$page_path&crop=border")->status_is(200);
    is( $extracts, 1, "second cropped page request reuses the cropped variant cache" );
}

note("archive page crop=border waits briefly for an in-flight crop result");
{
    my $id = "1234567890abcdef1234567890abcdef12345679";
    my $page_path = "page-inflight.png";
    my $source = make_page_blob( 100, 100, "#f8f8f8", [ 12, 10, 76, 82 ], "#222222" );
    my $cropped = make_page_blob( 80, 86, "#222222", [ 0, 0, 80, 86 ], "#222222" );
    my $crop_key = "crop_page/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path/png";
    my $lock_key = "LRR_PAGECROPJOB:v" . CROP_ALGORITHM_VERSION . ":$id:$page_path:png";
    my %cache;
    my $extracts = 0;
    my $crop_calls = 0;
    my $sleeps = 0;

    $lock_redis = FakeImageLockRedis->new;
    $lock_redis->{values}{$lock_key} = "other-worker";

    no warnings 'redefine';
    local *LANraragi::Model::Archive::get_page_data = sub {
        my ( $id, $path, $metrics ) = @_;
        $extracts++;
        $metrics->{cache_status} = "miss" if defined $metrics;
        return $source;
    };
    local *LANraragi::Model::Archive::crop_blank_borders = sub {
        $crop_calls++;
        return $cropped;
    };
    local *LANraragi::Model::Archive::fetch = sub {
        my ($key) = @_;
        return $cache{$key};
    };
    local *LANraragi::Model::Archive::put = sub {
        my ( $key, $value ) = @_;
        $cache{$key} = $value;
        return 1;
    };
    local *LANraragi::Model::Archive::usleep = sub {
        $sleeps++;
        $cache{$crop_key} = $cropped;
    };
    local *LANraragi::Model::Archive::get_logger = sub { return FakeImageLogger->new };
    local *LANraragi::Model::Metrics::record_image_serving_metrics = sub { return 1 };

    my $t = build_image_app();
    $t->get_ok("/archives/$id/page?path=$page_path&crop=border")->status_is(200);
    is( $t->tx->res->body, $cropped, "loser request serves the crop written by the in-flight winner" );
    is( $crop_calls, 0, "loser request does not duplicate crop detection after the winner writes the crop" );
    is( $extracts, 1, "loser request still extracts the original page needed for bounded fallback" );
    cmp_ok( $sleeps, ">=", 1, "loser request waits before re-checking the crop cache" );
}

note("archive page crop=border rejects zero area savings even when encoded bytes grow");
{
    my $id = "2234567890abcdef1234567890abcdef12345678";
    my $page_path = "page-002.png";
    my $source = make_page_blob( 36, 36, "#f8f8f8", [ 8, 8, 20, 20 ], "#222222" );
    my %cache;
    my $extracts = 0;
    my $crop_calls = 0;

    no warnings 'redefine';
    local *LANraragi::Model::Archive::get_page_data = sub {
        my ( $id, $path, $metrics ) = @_;
        $extracts++;
        $metrics->{cache_status} = "miss" if defined $metrics;
        return $source;
    };
    local *LANraragi::Model::Archive::crop_blank_borders = sub {
        $crop_calls++;
        return $source . ( "x" x 64 );
    };
    local *LANraragi::Model::Archive::fetch = sub {
        my ($key) = @_;
        return $cache{$key};
    };
    local *LANraragi::Model::Archive::put = sub {
        my ( $key, $value ) = @_;
        $cache{$key} = $value;
        return 1;
    };
    local *LANraragi::Model::Archive::get_logger = sub { return FakeImageLogger->new };
    local *LANraragi::Model::Metrics::record_image_serving_metrics = sub { return 1 };

    my $t = build_image_app();
    $t->get_ok("/archives/$id/page?path=$page_path&crop=border")->status_is(200);
    is( $t->tx->res->body, $source, "zero-area-savings crop falls back to the original page bytes" );
    is( $crop_calls, 1, "first request attempts crop detection once" );

    my $crop_key = "crop_page/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path/png";
    my $nocrop_key = "crop_page_nocrop/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path";
    ok( !exists $cache{$crop_key}, "zero-area-savings crop is not cached as a crop variant" );
    ok( exists $cache{$nocrop_key}, "zero-area-savings crop writes a nocrop marker" );

    $t->get_ok("/archives/$id/page?path=$page_path&crop=border")->status_is(200);
    is( $crop_calls, 1, "second request reuses nocrop marker instead of retrying zero-area crop" );
    is( $extracts, 2, "nocrop marker still serves the original page data on each request" );
}

note("archive page crop=border rejects tiny area savings even when encoded bytes shrink");
{
    my $id = "2f34567890abcdef1234567890abcdef12345678";
    my $page_path = "page-002-small-area.png";
    my $source = make_noisy_blob( 100, 100 );
    my $cropped = make_page_blob( 98, 98, "#f8f8f8", [ 8, 8, 82, 82 ], "#222222" );
    my %cache;
    my $crop_calls = 0;

    ok( length($cropped) < length($source), "fixture crop is byte-smaller than the original page" );

    no warnings 'redefine';
    local *LANraragi::Model::Archive::get_page_data = sub {
        my ( $id, $path, $metrics ) = @_;
        $metrics->{cache_status} = "miss" if defined $metrics;
        return $source;
    };
    local *LANraragi::Model::Archive::crop_blank_borders = sub {
        $crop_calls++;
        return $cropped;
    };
    local *LANraragi::Model::Archive::fetch = sub {
        my ($key) = @_;
        return $cache{$key};
    };
    local *LANraragi::Model::Archive::put = sub {
        my ( $key, $value ) = @_;
        $cache{$key} = $value;
        return 1;
    };
    local *LANraragi::Model::Archive::get_logger = sub { return FakeImageLogger->new };
    local *LANraragi::Model::Metrics::record_image_serving_metrics = sub { return 1 };

    my $t = build_image_app();
    $t->get_ok("/archives/$id/page?path=$page_path&crop=border")->status_is(200);
    is( $t->tx->res->body, $source, "crop below minimum area savings falls back to original page bytes" );
    is( $crop_calls, 1, "first request attempts crop detection once" );

    my $crop_key = "crop_page/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path/png";
    my $nocrop_key = "crop_page_nocrop/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path";
    ok( !exists $cache{$crop_key}, "tiny-area crop result is not cached as a crop variant" );
    ok( exists $cache{$nocrop_key}, "tiny-area crop result writes a nocrop marker" );
}

note("archive page crop=border keeps meaningful crops even when encoded bytes grow");
{
    my $id = "3234567890abcdef1234567890abcdef12345678";
    my $page_path = "page-003.png";
    my $source = make_page_blob( 100, 100, "#f8f8f8", [ 10, 10, 80, 80 ], "#222222" );
    my $cropped = make_noisy_blob( 80, 80 );
    my %cache;
    my $crop_calls = 0;

    ok( length($cropped) > length($source), "fixture crop is byte-larger than the original page" );

    no warnings 'redefine';
    local *LANraragi::Model::Archive::get_page_data = sub {
        my ( $id, $path, $metrics ) = @_;
        $metrics->{cache_status} = "miss" if defined $metrics;
        return $source;
    };
    local *LANraragi::Model::Archive::crop_blank_borders = sub {
        $crop_calls++;
        return $cropped;
    };
    local *LANraragi::Model::Archive::fetch = sub {
        my ($key) = @_;
        return $cache{$key};
    };
    local *LANraragi::Model::Archive::put = sub {
        my ( $key, $value ) = @_;
        $cache{$key} = $value;
        return 1;
    };
    local *LANraragi::Model::Archive::get_logger = sub { return FakeImageLogger->new };
    local *LANraragi::Model::Metrics::record_image_serving_metrics = sub { return 1 };

    my $t = build_image_app();
    $t->get_ok("/archives/$id/page?path=$page_path&crop=border")->status_is(200);
    is( $t->tx->res->body, $cropped, "visually meaningful crop is served despite larger encoded bytes" );
    is( $crop_calls, 1, "first request attempts crop detection once" );

    my ( $w, $h ) = image_dimensions( $t->tx->res->body );
    is( $w, 80, "meaningful byte-larger crop preserves cropped width" );
    is( $h, 80, "meaningful byte-larger crop preserves cropped height" );

    my $crop_key = "crop_page/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path/png";
    my $nocrop_key = "crop_page_nocrop/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path";
    ok( exists $cache{$crop_key}, "meaningful byte-larger crop is cached as a crop variant" );
    ok( !exists $cache{$nocrop_key}, "meaningful byte-larger crop does not write a nocrop marker" );
}

note("image dimension probe tolerates a broken Image::Magick runtime");
{
    # Force the Image::Magick fallback path by stubbing out the Vips probe.
    no warnings 'redefine';
    local *LANraragi::Model::Archive::_image_dimensions_from_blob_vips = sub { return };

    # Simulate a broken PerlMagick install (dylib load fails at ->new or
    # BlobToImage dies). The probe must return empty, never propagate the die.
    local *Image::Magick::new = sub { die "Image::Magick runtime broken\n" };

    my @dims = LANraragi::Model::Archive::_image_dimensions_from_blob("\x89PNG\r\n\x1a\n");
    ok( !@dims, "_image_dimensions_from_blob returns empty list when Image::Magick dies" );
    is( scalar(@dims), 0, "broken Image::Magick probe does not propagate a die" );

    # Sanity check: when Image::Magick->new succeeds but BlobToImage dies on
    # malformed content, the probe still returns empty rather than dying.
    local *Image::Magick::new = sub { bless {}, "Image::Magick" };
    local *Image::Magick::BlobToImage = sub { die "BlobToImage runtime broken\n" };
    my @dims2 = LANraragi::Model::Archive::_image_dimensions_from_blob("not an image");
    ok( !@dims2, "_image_dimensions_from_blob returns empty list when BlobToImage dies" );
}

SKIP: {
    skip "libvips is not installed", 6 unless LANraragi::Utils::Vips::is_vips_loaded();

    note("archive page crop=border does not require Image::Magick for area savings when Vips is available");
    my $id = "4234567890abcdef1234567890abcdef12345678";
    my $page_path = "page-004.png";
    my $source = make_page_blob( 120, 160, "#f8f8f8", [ 14, 12, 92, 132 ], "#222222" );
    my $cropped = make_page_blob( 96, 136, "#222222", [ 0, 0, 96, 136 ], "#222222" );
    my %cache;
    my $crop_calls = 0;

    no warnings 'redefine';
    local *LANraragi::Model::Archive::get_page_data = sub {
        my ( $id, $path, $metrics ) = @_;
        $metrics->{cache_status} = "miss" if defined $metrics;
        return $source;
    };
    local *LANraragi::Model::Archive::crop_blank_borders = sub {
        $crop_calls++;
        return $cropped;
    };
    local *LANraragi::Model::Archive::fetch = sub {
        my ($key) = @_;
        return $cache{$key};
    };
    local *LANraragi::Model::Archive::put = sub {
        my ( $key, $value ) = @_;
        $cache{$key} = $value;
        return 1;
    };
    local *LANraragi::Model::Archive::get_logger = sub { return FakeImageLogger->new };
    local *LANraragi::Model::Metrics::record_image_serving_metrics = sub { return 1 };

    local $INC{"Image/Magick.pm"};
    delete $INC{"Image/Magick.pm"};
    local @INC = (
        sub {
            die "Image::Magick deliberately unavailable\n" if $_[1] eq "Image/Magick.pm";
            return;
        },
        @INC
    );

    my $t = build_image_app();
    $t->get_ok("/archives/$id/page?path=$page_path&crop=border")->status_is(200);
    is( $t->tx->res->body, $cropped, "Vips dimensions allow cropped page response without Image::Magick" );
    is( $crop_calls, 1, "crop detection is attempted once" );

    my $crop_key = "crop_page/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path/png";
    my $nocrop_key = "crop_page_nocrop/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path";
    ok( exists $cache{$crop_key}, "Vips-dimensioned crop is cached as a crop variant" );
    ok( !exists $cache{$nocrop_key}, "Vips-dimensioned crop does not write a nocrop marker" );
}

done_testing();
