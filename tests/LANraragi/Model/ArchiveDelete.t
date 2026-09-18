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
            sets   => $args{sets} || {},
            scores => $args{scores} || {},
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
        my ( $self, $key, $member ) = @_;
        push @{ $self->{srem} }, [ $key, $member ];
        delete $self->{sets}{$key}{$member};
        return 1;
    }

    sub sadd {
        my ( $self, $key, $member ) = @_;
        $self->{sets}{$key}{$member} = 1;
        return 1;
    }

    sub zincrby {
        my ( $self, $key, $increment, $member ) = @_;
        return $self->{scores}{$key}{$member} += $increment;
    }

    sub zrem {
        my ( $self, @args ) = @_;
        push @{ $self->{zrem} }, \@args;
        return 1;
    }

    sub multi { return 1 }
    sub exec  { return 1 }
    sub quit  { return 1 }
}

package main;

my $id = "1111111111111111111111111111111111111111";
my $other_id = "2222222222222222222222222222222222222222";
my @tags = ( "artist:someone", "parody:something" );

my $archive_redis = FakeArchiveDeleteRedis->new(
    hashes => {
        $id => {
            file  => "missing-file.cbz",
            tags  => join( ", ", @tags ),
            title => "Archive To Delete",
        },
    },
    sets => { LRR_ALL_ARCHIVES => { $id => 1, $other_id => 1 } },
);
my @search_sets = ( "LRR_NEW", "LRR_UNTAGGED", "LRR_TANKGROUPED", map { "INDEX_$_" } @tags );
my $search_redis = FakeArchiveDeleteRedis->new(
    sets   => { map { $_ => { $id => 1, $other_id => 1 } } @search_sets },
    scores => { LRR_STATS => { map { $_ => 2 } @tags } },
);
my $config_redis = FakeArchiveDeleteRedis->new;
my $invalidations = 0;
my @memberships_at_invalidation;
my @page_cache_clears;

{
    no warnings 'redefine';
    local *LANraragi::Model::Config::get_redis = sub { return $archive_redis };
    local *LANraragi::Model::Config::get_redis_search = sub { return $search_redis };
    local *LANraragi::Model::Config::get_redis_config = sub { return $config_redis };
    local *LANraragi::Model::Tankoubon::get_tankoubons_containing_archive = sub { return () };
    local *LANraragi::Model::Category::get_categories_containing_archive = sub { return () };
    local *LANraragi::Model::Dedup::CoverIndex::remove_pairs_for_archive = sub { return 0 };
    local *LANraragi::Model::Archive::get_archive_path = sub { return "missing-file.cbz" };
    local *LANraragi::Model::Archive::invalidate_cache = sub {
        $invalidations++;
        @memberships_at_invalidation = grep { exists $search_redis->{sets}{$_}{$id} } @search_sets;
        return 1;
    };
    local *LANraragi::Model::Archive::clear_by_id = sub { push @page_cache_clears, @_ };

    my $status = LANraragi::Model::Archive::delete_archive($id);

    is( $status, "0", "missing archive file delete returns existing missing-file status" );
}

is( $invalidations, 1, "delete_archive invalidates search cache generation after index cleanup" );
is_deeply( \@memberships_at_invalidation, [], "search cache is invalidated after all deleted archive memberships are removed" );
is_deeply( \@page_cache_clears, [$id], "delete_archive clears page-cache variants for the deleted archive" );
is_deeply( $archive_redis->{del}, [$id], "archive hash is deleted" );
is_deeply( $archive_redis->{sets}{LRR_ALL_ARCHIVES}, { $other_id => 1 }, "only the deleted archive is removed from the maintained IDs" );
is_deeply( $search_redis->{zrem}, [ [ "LRR_TITLES", "archive to delete\0$id" ] ], "archive is removed from the title index" );

for my $key (@search_sets) {
    is_deeply( $search_redis->{sets}{$key}, { $other_id => 1 }, "$key retains only the unrelated archive after deletion" );
}
is_deeply( $search_redis->{scores}{LRR_STATS}, { map { $_ => 1 } @tags }, "tag counts retain the unrelated archive after deletion" );

done_testing();
