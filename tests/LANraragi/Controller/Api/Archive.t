use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi::Controller::Api::Archive;

package FakeArchiveHeaders {
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }

    sub user_agent { return shift->{user_agent} }
}

package FakeArchiveReq {
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

package FakeArchiveRedis {
    sub new { return bless {}, shift }
    sub quit { return 1 }
}

package FakeArchiveConfig {
    sub new { return bless {}, shift }
    sub get_redis { return FakeArchiveRedis->new }
}

package FakeArchiveMinion {
    sub new { return bless { enqueued => [] }, shift }

    sub enqueue {
        my ( $self, $task, $args, @rest ) = @_;
        push @{ $self->{enqueued} }, { task => $task, args => $args, rest => \@rest };
        return scalar @{ $self->{enqueued} };
    }
}

package FakeArchiveOpenAPI {
    sub new {
        my ( $class, $controller ) = @_;
        return bless { controller => $controller }, $class;
    }

    sub valid_input { return shift->{controller} }
}

package FakeArchiveController {
    sub new {
        my ( $class, %args ) = @_;
        my $headers = FakeArchiveHeaders->new( user_agent => $args{user_agent} );
        my $req     = FakeArchiveReq->new( params => $args{params} || {}, headers => $headers );
        return bless {
            req     => $req,
            stash   => $args{stash} || {},
            minion  => $args{minion} || FakeArchiveMinion->new,
            renders => [],
        }, $class;
    }

    sub openapi   { return FakeArchiveOpenAPI->new(shift) }
    sub req       { return shift->{req} }
    sub minion    { return shift->{minion} }
    sub LRR_CONF  { return FakeArchiveConfig->new }

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

note("Tachiyomi-compatible metadata requests reuse a short in-worker cache and enqueue filelist warming");
{
    no warnings 'redefine';
    my $metadata_calls = 0;
    my $minion = FakeArchiveMinion->new;

    local *LANraragi::Controller::Api::Archive::get_archive_json = sub {
        $metadata_calls++;
        return { arcid => $_[1], title => "Cached title", tags => "", summary => "", isnew => "false" };
    };

    for ( 1 .. 2 ) {
        my $ctx = FakeArchiveController->new(
            user_agent => "Tachiyomi/0.15.3",
            stash      => { id => $archive_id },
            minion     => $minion,
        );
        LANraragi::Controller::Api::Archive::serve_metadata($ctx);
        is( $ctx->last_render->{openapi}{arcid}, $archive_id, "metadata response rendered" );
    }

    is( $metadata_calls, 1, "second Tachiyomi metadata request reuses short cache" );
    is( scalar @{ $minion->{enqueued} }, 1, "metadata miss queues one warm_filelist job" );
    is( $minion->{enqueued}[0]{task}, "warm_filelist", "warm_filelist task queued" );
    is_deeply( $minion->{enqueued}[0]{args}, [$archive_id], "warm_filelist receives archive id" );
}

done_testing();
