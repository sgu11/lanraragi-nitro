use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use Mojolicious;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Image::Magick;

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

note("archive page crop=border serves and reuses a cropped page variant");
{
    my $id = "1234567890abcdef1234567890abcdef12345678";
    my $page_path = "page-001.png";
    my $source = make_page_blob( 100, 100, "#f8f8f8", [ 12, 10, 76, 82 ], "#222222" );
    my %cache;
    my $extracts = 0;

    no warnings 'redefine';
    local *LANraragi::Model::Archive::get_page_data = sub {
        my ( $id, $path, $metrics ) = @_;
        $extracts++;
        $metrics->{cache_status} = "miss" if defined $metrics;
        return $source;
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

done_testing();
