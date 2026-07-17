use strict;
use warnings;
use utf8;

use Test::More;
use Cwd qw(getcwd);

BEGIN {
    my $cwd = getcwd;
    require "$cwd/tests/mocks.pl";
    setup_redis_mock();
}

use LANraragi::Controller::Api::Archive;
use LANraragi::Controller::Api::Tankoubon;

package FakeProgressOpenAPI {
    sub new {
        my ( $class, $controller ) = @_;
        return bless { controller => $controller }, $class;
    }

    sub valid_input { return shift->{controller} }
}

package FakeProgressRequest {
    sub new {
        my ( $class, %args ) = @_;
        return bless { params => $args{params} || {} }, $class;
    }

    sub param {
        my ( $self, $name ) = @_;
        return $self->{params}{$name};
    }
}

package FakeProgressRedis {
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            hashes => $args{hashes} || {},
            increments => {},
            quits => 0,
        }, $class;
    }

    sub hget {
        my ( $self, $key, $field ) = @_;
        return $self->{hashes}{$key}{$field};
    }

    sub hset {
        my ( $self, $key, $field, $value ) = @_;
        $self->{hashes}{$key}{$field} = $value;
        return 1;
    }

    sub incr {
        my ( $self, $key ) = @_;
        return ++$self->{increments}{$key};
    }

    sub quit {
        my ($self) = @_;
        $self->{quits}++;
        return 1;
    }
}

package FakeProgressConfig {
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            redis      => $args{redis},
            redis_cfg  => $args{redis_cfg},
        }, $class;
    }

    sub get_redis        { return shift->{redis} }
    sub get_redis_config { return shift->{redis_cfg} }
}

package FakeProgressController {
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            req     => FakeProgressRequest->new( params => $args{params} ),
            config  => $args{config},
            stash   => $args{stash} || {},
            renders => [],
        }, $class;
    }

    sub openapi { return FakeProgressOpenAPI->new(shift) }
    sub req     { return shift->{req} }
    sub LRR_CONF { return shift->{config} }

    sub stash {
        my ( $self, $name ) = @_;
        return $self->{stash}{$name};
    }

    sub render {
        my ( $self, %args ) = @_;
        push @{ $self->{renders} }, \%args;
        return;
    }

    sub last_render { return shift->{renders}[-1] }
}

package main;

my $archive_id = "1111111111111111111111111111111111111111";
my $tank_id    = "TANK_1234567890";

note("Controllers are invoked with route-shaped stashes; OpenAPI path/schema validation is covered by npm run lint-openapi");

sub controller_response {
    my ( $ctx ) = @_;
    return $ctx->last_render->{openapi};
}

note("Archive progress controller persists zero, accepts positive pages, and rejects negatives");
{
    no warnings 'redefine';
    local *LANraragi::Model::Config::enable_authprogress = sub { 0 };
    local *LANraragi::Model::Config::enable_localprogress = sub { 0 };
    local *LANraragi::Controller::Api::Archive::exec_with_lock = sub {
        my ( $self, $key, $operation, $id, $callback ) = @_;
        return $callback->();
    };

    my $archive_redis = FakeProgressRedis->new(
        hashes => {
            $archive_id => { pagecount => 12, progress => 7 },
        },
    );
    my $config_redis = FakeProgressRedis->new;
    my $config        = FakeProgressConfig->new( redis => $archive_redis, redis_cfg => $config_redis );

    my $zero = FakeProgressController->new(
        config => $config,
        stash  => { id => $archive_id, page => 0 },
    );
    LANraragi::Controller::Api::Archive::update_progress($zero);
    is( $archive_redis->{hashes}{$archive_id}{progress}, 0, "archive page 0 is persisted" );
    is( controller_response($zero)->{page}, 0, "archive page 0 is returned" );
    is( controller_response($zero)->{success}, 1, "archive page 0 succeeds" );

    my $positive = FakeProgressController->new(
        config => $config,
        stash  => { id => $archive_id, page => 5 },
    );
    LANraragi::Controller::Api::Archive::update_progress($positive);
    is( $archive_redis->{hashes}{$archive_id}{progress}, 5, "archive positive page is persisted" );
    is( controller_response($positive)->{page}, 5, "archive positive page is returned" );
    is( controller_response($positive)->{success}, 1, "archive positive page succeeds" );

    my $negative = FakeProgressController->new(
        config => $config,
        stash  => { id => $archive_id, page => -1 },
    );
    LANraragi::Controller::Api::Archive::update_progress($negative);
    is( $archive_redis->{hashes}{$archive_id}{progress}, 5, "archive negative page does not overwrite progress" );
    is( controller_response($negative)->{success}, 0, "archive negative page is rejected" );
    is( controller_response($negative)->{error}, "Invalid progress value.", "archive negative page reports validation error" );
    is( $negative->last_render->{status}, 400, "archive negative page returns HTTP 400" );
}

note("Tankoubon progress controller persists zero, accepts positive pages, and rejects negatives");
{
    no warnings 'redefine';
    local *LANraragi::Model::Config::enable_authprogress = sub { 0 };
    local *LANraragi::Model::Config::enable_localprogress = sub { 0 };

    my %progress = ( $tank_id => 7 );
    my @updates;
    local *LANraragi::Model::Tankoubon::update_tank_progress = sub {
        my ( $id, $page ) = @_;
        push @updates, [ $id, $page ];
        $progress{$id} = $page;
        return ( 1, undef );
    };

    my $zero = FakeProgressController->new(
        stash => { id => $tank_id, page => 0 },
    );
    LANraragi::Controller::Api::Tankoubon::update_tank_progress($zero);
    is( $progress{$tank_id}, 0, "Tankoubon page 0 is persisted" );
    is_deeply( $updates[-1], [ $tank_id, 0 ], "Tankoubon page 0 reaches the model" );
    is( controller_response($zero)->{page}, 0, "Tankoubon page 0 is returned" );
    is( controller_response($zero)->{success}, 1, "Tankoubon page 0 succeeds" );

    my $positive = FakeProgressController->new(
        stash => { id => $tank_id, page => 9 },
    );
    LANraragi::Controller::Api::Tankoubon::update_tank_progress($positive);
    is( $progress{$tank_id}, 9, "Tankoubon positive page is persisted" );
    is( controller_response($positive)->{page}, 9, "Tankoubon positive page is returned" );
    is( controller_response($positive)->{success}, 1, "Tankoubon positive page succeeds" );

    my $negative = FakeProgressController->new(
        stash => { id => $tank_id, page => -1 },
    );
    LANraragi::Controller::Api::Tankoubon::update_tank_progress($negative);
    is( $progress{$tank_id}, 9, "Tankoubon negative page does not overwrite progress" );
    is( scalar @updates, 2, "Tankoubon negative page does not call the model" );
    is( controller_response($negative)->{success}, 0, "Tankoubon negative page is rejected" );
    is( controller_response($negative)->{error}, "Invalid progress value.", "Tankoubon negative page reports validation error" );
    is( $negative->last_render->{status}, 400, "Tankoubon negative page returns HTTP 400" );
}

done_testing();
