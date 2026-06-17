use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi::Model::Archive;

package FakeArchiveDeleteRedis {
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            hashes => $args{hashes} || {},
            srem   => [],
            zrem   => [],
            del    => [],
        }, $class;
    }

    sub hget {
        my ( $self, $key, $field ) = @_;
        return $self->{hashes}{$key}{$field};
    }

    sub hexists {
        my ( $self, $key, $field ) = @_;
        return exists $self->{hashes}{$key}{$field} ? 1 : 0;
    }

    sub del {
        my ( $self, @keys ) = @_;
        push @{ $self->{del} }, @keys;
        delete @{ $self->{hashes} }{@keys};
        return scalar @keys;
    }

    sub srem {
        my ( $self, @args ) = @_;
        push @{ $self->{srem} }, \@args;
        return 1;
    }

    sub zrem {
        my ( $self, @args ) = @_;
        push @{ $self->{zrem} }, \@args;
        return 1;
    }

    sub quit { return 1 }
}

package main;

my $id = "1111111111111111111111111111111111111111";

my $archive_redis = FakeArchiveDeleteRedis->new(
    hashes => {
        $id => {
            file  => "missing-file.cbz",
            tags  => "artist:someone, parody:something",
            title => "Archive To Delete",
        },
    },
);
my $search_redis = FakeArchiveDeleteRedis->new;
my $invalidations = 0;

{
    no warnings 'redefine';
    local *LANraragi::Model::Config::get_redis = sub { return $archive_redis };
    local *LANraragi::Model::Config::get_redis_search = sub { return $search_redis };
    local *LANraragi::Model::Tankoubon::get_tankoubons_containing_archive = sub { return () };
    local *LANraragi::Model::Category::get_categories_containing_archive = sub { return () };
    local *LANraragi::Utils::Database::update_indexes = sub { return 1 };
    local *LANraragi::Model::Archive::get_archive_path = sub { return "missing-file.cbz" };
    local *LANraragi::Model::Archive::invalidate_cache = sub { $invalidations++; return 1 };

    my $status = LANraragi::Model::Archive::delete_archive($id);

    is( $status, "0", "missing archive file delete returns existing missing-file status" );
}

is( $invalidations, 1, "delete_archive invalidates search cache generation after index cleanup" );
is_deeply( $archive_redis->{del}, [$id], "archive hash is deleted" );
is_deeply( $search_redis->{srem}[0], [ "LRR_NEW", $id ], "archive is removed from NEW search set" );

done_testing();
