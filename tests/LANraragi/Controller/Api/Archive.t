use strict;
use warnings;
use utf8;

use Test::More;
use Digest::SHA qw(sha1_hex);

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

    sub upload {
        my ( $self, $name ) = @_;
        return $self->{uploads}{$name};
    }
}

# Minimal response mock so controllers under test can set Cache-Control/Vary
# headers (filelist, metadata) the same way the real Mojo controller does.
package FakeArchiveResHeaders {
    sub new { return bless { set => [] }, shift }
    sub cache_control {
        my ( $self, $value ) = @_;
        push @{ $self->{set} }, [ cache_control => $value ];
    }
    sub vary {
        my ( $self, $value ) = @_;
        push @{ $self->{set} }, [ vary => $value ];
    }
}

package FakeArchiveRes {
    sub new { return bless { headers => FakeArchiveResHeaders->new }, shift }
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
        my $req     = FakeArchiveReq->new(
            params  => $args{params} || {},
            uploads => $args{uploads} || {},
            headers => $headers,
        );
        return bless {
            req     => $req,
            res     => FakeArchiveRes->new,
            stash   => $args{stash} || {},
            minion  => $args{minion} || FakeArchiveMinion->new,
            renders => [],
        }, $class;
    }

    sub openapi   { return FakeArchiveOpenAPI->new(shift) }
    sub req       { return shift->{req} }
    sub res       { return shift->{res} }
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

package FakeArchiveUploadHeaders {
    sub new { return bless {}, shift }
    sub content_type { return "application/zip" }
}

package FakeArchiveChunkedAsset {
    sub new {
        my ( $class, $content ) = @_;
        return bless { content => $content }, $class;
    }

    sub get_chunk {
        my ( $self, $offset, $max ) = @_;
        $max //= 131072;
        return substr $self->{content}, $offset, $max;
    }
}

package FakeArchiveLargeUpload {
    sub new {
        my ( $class, %args ) = @_;
        return bless \%args, $class;
    }

    sub filename { return shift->{filename} }
    sub headers  { return FakeArchiveUploadHeaders->new }
    sub size     { return 2 * 1024 * 1024 * 1024 + 1 }
    sub asset    { return FakeArchiveChunkedAsset->new( shift->{content} ) }

    sub slurp {
        die "slurp should not be called for large API upload checksum validation\n";
    }

    sub move_to {
        my ( $self, $path ) = @_;
        open( my $fh, '>:raw', $path ) or return 0;
        print {$fh} $self->{content};
        close $fh;
        return 1;
    }
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

note("Editable metadata responses require browser revalidation");
{
    no warnings 'redefine';

    local *LANraragi::Controller::Api::Archive::get_archive_json = sub {
        return { arcid => $_[1], title => "Editable title", tags => "artist:someone", summary => "Editable" };
    };

    my $ctx = FakeArchiveController->new( stash => { id => $archive_id } );
    LANraragi::Controller::Api::Archive::serve_metadata($ctx);

    my ($cache_control) = map { $_->[1] } grep { $_->[0] eq "cache_control" } @{ $ctx->res->headers->{set} };
    is( $cache_control, "private, no-cache", "metadata is private but must revalidate after edits" );
}

note("API upload checksum validation streams large uploads instead of slurping");
{
    no warnings 'redefine';
    my $payload = "small fixture content standing in for a sparse >2GiB upload";
    my $upload = FakeArchiveLargeUpload->new(
        filename => "large-api-upload.zip",
        content  => $payload,
    );
    my $ctx = FakeArchiveController->new(
        params => {
            file_checksum => sha1_hex($payload),
            category_id   => "SET_1234567890",
            tags          => "source:test",
            title         => "Large API Upload",
            summary       => "checksum streaming regression",
        },
        uploads => { file => $upload },
    );

    local *LANraragi::Controller::Api::Archive::exec_with_lock = sub {
        my ( $self, $key, $operation, $name, $callback ) = @_;
        return $callback->();
    };
    local *LANraragi::Model::Upload::handle_incoming_file = sub {
        my ( $tempfile, $catid, $tags, $title, $summary ) = @_;
        return ( 200, "2222222222222222222222222222222222222222", $title, "uploaded" );
    };

    my $ok = eval {
        LANraragi::Controller::Api::Archive::create_archive($ctx);
        1;
    };

    ok( $ok, "large API upload with checksum does not slurp the whole file" ) or diag($@);
    SKIP: {
        skip "upload did not render after checksum failure", 2 unless $ok && $ctx->last_render;
        is( $ctx->last_render->{openapi}{success}, 1, "upload succeeds after streamed checksum validation" );
        is( $ctx->last_render->{openapi}{id}, "2222222222222222222222222222222222222222", "uploaded archive id returned" );
    }
}

done_testing();
