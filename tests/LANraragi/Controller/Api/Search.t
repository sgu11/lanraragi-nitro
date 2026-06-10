use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi::Controller::Api::Search;
use LANraragi::Model::Config;
use LANraragi::Model::Search;

package FakeSearchHeaders {
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }

    sub user_agent { return shift->{user_agent} }
    sub authorization { return shift->{authorization} }
}

package FakeSearchReq {
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }

    sub param {
        my ( $self, $name ) = @_;
        return $self->{params}{$name};
    }

    sub headers { return shift->{headers} }
}

package FakeSearchOpenAPI {
    sub new {
        my ( $class, $controller ) = @_;
        return bless { controller => $controller }, $class;
    }

    sub valid_input { return shift->{controller} }
}

package FakeSearchTx {
    sub remote_address { return "127.0.0.1" }
}

package FakeSearchController {
    sub new {
        my ( $class, %args ) = @_;
        my $headers = FakeSearchHeaders->new(
            user_agent   => $args{user_agent},
            authorization => $args{authorization},
        );
        my $req = FakeSearchReq->new( params => $args{params} || {}, headers => $headers );
        return bless { req => $req, renders => [] }, $class;
    }

    sub openapi { return FakeSearchOpenAPI->new(shift) }
    sub req     { return shift->{req} }
    sub tx      { return FakeSearchTx->new }

    sub render {
        my ( $self, %args ) = @_;
        push @{ $self->{renders} }, \%args;
        return;
    }

    sub last_render { return shift->{renders}[-1] }
}

package FakeSearchRedis {
    sub new { return bless { values => {} }, shift }

    sub get {
        my ( $self, $key ) = @_;
        return $self->{values}{$key};
    }

    sub set {
        my ( $self, $key, $value, @args ) = @_;
        $self->{values}{$key} = $value;
        return 1;
    }

    sub quit { return 1 }
}

package main;

my $archive_id_a = "1111111111111111111111111111111111111111";
my $archive_id_b = "2222222222222222222222222222222222222222";

sub archive_rows {
    return map { { arcid => $_, title => "Archive $_", tags => "", summary => "" } } @_;
}

note("Tachiyomi-compatible search defaults to archive IDs unless caller explicitly requests tank grouping");
{
    no warnings 'redefine';
    my @grouptanks;
    local *LANraragi::Model::Search::do_search = sub {
        push @grouptanks, $_[7];
        return ( 2, 1, $archive_id_a );
    };
    local *LANraragi::Controller::Api::Search::get_archive_json_multi = sub { archive_rows(@_) };
    local *LANraragi::Model::Config::get_redis_search = sub { return FakeSearchRedis->new };

    my $tachiyomi = FakeSearchController->new(
        user_agent => "Mozilla/5.0 Tachiyomi/0.15.3",
        params     => { start => 0 },
    );
    LANraragi::Controller::Api::Search::handle_api($tachiyomi);

    my $explicit_grouping = FakeSearchController->new(
        user_agent => "Mozilla/5.0 Tachiyomi/0.15.3",
        params     => { start => 0, groupby_tanks => "true" },
    );
    LANraragi::Controller::Api::Search::handle_api($explicit_grouping);

    my $browser = FakeSearchController->new(
        user_agent => "Mozilla/5.0 Firefox/139.0",
        params     => { start => 0 },
    );
    LANraragi::Controller::Api::Search::handle_api($browser);

    is_deeply( \@grouptanks, [ 0, 1, 1 ], "only implicit Tachiyomi search disables tank grouping" );
}

note("Tachiyomi-compatible API search responses are cached briefly by identical request");
{
    no warnings 'redefine';
    my $redis = FakeSearchRedis->new;
    my $calls = 0;

    local *LANraragi::Model::Config::get_redis_search = sub { return $redis };
    local *LANraragi::Model::Search::do_search = sub {
        $calls++;
        return ( 2, 1, $archive_id_a );
    };
    local *LANraragi::Controller::Api::Search::get_archive_json_multi = sub { archive_rows(@_) };

    for ( 1 .. 2 ) {
        my $ctx = FakeSearchController->new(
            user_agent   => "Tachiyomi/0.15.3",
            authorization => "Bearer same-client",
            params       => { start => 0, filter => "artist:wada rco" },
        );
        LANraragi::Controller::Api::Search::handle_api($ctx);
        is( $ctx->last_render->{openapi}{data}[0]{arcid}, $archive_id_a, "search response contains archive data" );
    }

    is( $calls, 1, "second identical Tachiyomi API search reuses cached response" );
}

note("Tachiyomi-compatible random count=1 is briefly sticky for the same client/query");
{
    no warnings 'redefine';
    my $redis = FakeSearchRedis->new;
    my $calls = 0;

    local *LANraragi::Model::Config::get_redis_search = sub { return $redis };
    local *LANraragi::Model::Search::do_search = sub {
        $calls++;
        return $calls == 1 ? ( 2, 1, $archive_id_a ) : ( 2, 1, $archive_id_b );
    };
    local *LANraragi::Controller::Api::Search::get_archive_json_multi = sub { archive_rows(@_) };

    my @seen;
    for ( 1 .. 2 ) {
        my $ctx = FakeSearchController->new(
            user_agent   => "Tachiyomi/0.15.3",
            authorization => "Bearer same-client",
            params       => { count => 1, filter => "fruit:banana" },
        );
        LANraragi::Controller::Api::Search::get_random_archives($ctx);
        push @seen, $ctx->last_render->{openapi}{data}[0]{arcid};
    }

    is_deeply( \@seen, [ $archive_id_a, $archive_id_a ], "same random query stays stable across immediate repeat" );
    is( $calls, 1, "second sticky random response does not redo search" );
}

done_testing();
