use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use Mojolicious;

use LANraragi::Model::Archive;
use LANraragi::Utils::ImageBorderCrop qw(CROP_ALGORITHM_VERSION);

package FakeCropLockRedis {
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

package FakeCropLogger {
    sub new { return bless {}, shift }
    sub debug { return 1 }
    sub warn  { return 1 }
}

package main;

my $lock_redis;

{
    no warnings 'redefine';
    *LANraragi::Model::Config::get_redis_config = sub { return $lock_redis };
    *LANraragi::Model::Config::enable_resize = sub { return 0 };
}

sub build_crop_app {
    my $app = Mojolicious->new;
    $app->plugin('RenderFile');
    $app->routes->get('/archives/:id/page')->to(
        cb => sub {
            my $c = shift;
            LANraragi::Model::Archive::serve_page( $c, $c->param('id'), $c->param('path') );
        }
    );
    return Test::Mojo->new($app);
}

note("crop loser waits for an in-flight positive crop result instead of duplicating detection");
{
    my $id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    my $page_path = "page.jpg";
    my $source = "ORIGINAL-PAGE";
    my $winner_crop = "CACHED-CROP";
    my $duplicate_crop = "DUPLICATE-CROP";
    my $crop_key = "crop_page/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path/jpg";
    my $lock_key = "LRR_PAGECROPJOB:v" . CROP_ALGORITHM_VERSION . ":$id:$page_path:jpg";
    my %cache;
    my $crop_calls = 0;
    my $sleeps = 0;

    $lock_redis = FakeCropLockRedis->new;
    $lock_redis->{values}{$lock_key} = "other-worker";

    no warnings 'redefine';
    local *LANraragi::Model::Archive::get_page_data = sub { return $source };
    local *LANraragi::Model::Archive::crop_blank_borders = sub {
        $crop_calls++;
        return $duplicate_crop;
    };
    local *LANraragi::Model::Archive::_crop_area_savings_ratio = sub { return 0.50 };
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
        $cache{$crop_key} = $winner_crop;
    };
    local *LANraragi::Model::Archive::get_logger = sub { return FakeCropLogger->new };
    local *LANraragi::Model::Metrics::record_image_serving_metrics = sub { return 1 };

    my $t = build_crop_app();
    $t->get_ok("/archives/$id/page?path=$page_path&crop=border")->status_is(200);
    is( $t->tx->res->body, $winner_crop, "loser returns the winner's cached crop" );
    is( $crop_calls, 0, "loser does not duplicate crop detection" );
    cmp_ok( $sleeps, ">=", 1, "loser waits before re-checking the crop key" );
}

note("crop loser waits for an in-flight nocrop marker");
{
    my $id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    my $page_path = "page.jpg";
    my $source = "ORIGINAL-PAGE";
    my $duplicate_crop = "DUPLICATE-CROP";
    my $nocrop_key = "crop_page_nocrop/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path";
    my $lock_key = "LRR_PAGECROPJOB:v" . CROP_ALGORITHM_VERSION . ":$id:$page_path:jpg";
    my %cache;
    my $crop_calls = 0;
    my $sleeps = 0;

    $lock_redis = FakeCropLockRedis->new;
    $lock_redis->{values}{$lock_key} = "other-worker";

    no warnings 'redefine';
    local *LANraragi::Model::Archive::get_page_data = sub { return $source };
    local *LANraragi::Model::Archive::crop_blank_borders = sub {
        $crop_calls++;
        return $duplicate_crop;
    };
    local *LANraragi::Model::Archive::_crop_area_savings_ratio = sub { return 0.50 };
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
        $cache{$nocrop_key} = "1";
    };
    local *LANraragi::Model::Archive::get_logger = sub { return FakeCropLogger->new };
    local *LANraragi::Model::Metrics::record_image_serving_metrics = sub { return 1 };

    my $t = build_crop_app();
    $t->get_ok("/archives/$id/page?path=$page_path&crop=border")->status_is(200);
    is( $t->tx->res->body, $source, "loser returns original bytes after the winner writes a nocrop marker" );
    is( $crop_calls, 0, "loser does not duplicate crop detection after a nocrop marker appears" );
    cmp_ok( $sleeps, ">=", 1, "loser waits before re-checking the nocrop key" );
}

note("crop winner writes the crop before releasing its lock");
{
    my $id = "cccccccccccccccccccccccccccccccccccccccc";
    my $page_path = "page.jpg";
    my $source = "ORIGINAL-PAGE";
    my $cropped = "WINNER-CROP";
    my $crop_key = "crop_page/v" . CROP_ALGORITHM_VERSION . "/$id/$page_path/jpg";
    my $lock_key = "LRR_PAGECROPJOB:v" . CROP_ALGORITHM_VERSION . ":$id:$page_path:jpg";
    my %cache;
    my $crop_calls = 0;

    $lock_redis = FakeCropLockRedis->new;

    no warnings 'redefine';
    local *LANraragi::Model::Archive::get_page_data = sub { return $source };
    local *LANraragi::Model::Archive::crop_blank_borders = sub {
        $crop_calls++;
        return $cropped;
    };
    local *LANraragi::Model::Archive::_crop_area_savings_ratio = sub { return 0.50 };
    local *LANraragi::Model::Archive::fetch = sub {
        my ($key) = @_;
        return $cache{$key};
    };
    local *LANraragi::Model::Archive::put = sub {
        my ( $key, $value ) = @_;
        $cache{$key} = $value;
        return 1;
    };
    local *LANraragi::Model::Archive::get_logger = sub { return FakeCropLogger->new };
    local *LANraragi::Model::Metrics::record_image_serving_metrics = sub { return 1 };

    my $t = build_crop_app();
    $t->get_ok("/archives/$id/page?path=$page_path&crop=border")->status_is(200);
    is( $t->tx->res->body, $cropped, "winner returns the computed crop" );
    is( $cache{$crop_key}, $cropped, "winner writes the positive crop cache key" );
    is( $lock_redis->{values}{$lock_key}, undef, "winner releases the crop lock after writing the cache key" );
    is( $crop_calls, 1, "winner computes crop exactly once" );
}

done_testing();
