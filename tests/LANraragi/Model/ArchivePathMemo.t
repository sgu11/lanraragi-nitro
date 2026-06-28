use strict;
use warnings;
use utf8;

use Test::More;

# Exercises the per-worker id -> archive path memo introduced for the reader
# page-serving hot path (REDIS-2). The memo must:
#   - return the cached path on a second resolve without re-opening Redis,
#   - be cleared per-id by LANraragi::Model::Archive::invalidate_archive_path_cache($id),
#   - be cleared wholesale by LANraragi::Model::Archive::invalidate_archive_path_cache() (no arg).

package FakePathRedis {
    sub new {
        my ( $class, %args ) = @_;
        return bless { hashes => $args{hashes} || {}, quit_count => 0 }, $class;
    }
    sub hget {
        my ( $self, $key, $field ) = @_;
        return $self->{hashes}{$key}{$field};
    }
    # Track Redis connection teardown as a proxy for "opened a connection".
    sub quit { my ($self) = @_; $self->{quit_count}++; return 1; }
    sub quit_count { return shift->{quit_count} }
}

package main;

use LANraragi::Model::Archive;

# Start from a clean memo so test ordering does not bleed state.
LANraragi::Model::Archive::invalidate_archive_path_cache();

my $path_redis = FakePathRedis->new(
    hashes => {
        arc1 => { file => "/library/archive-one.cbz" },
        arc2 => { file => "/library/archive-two.cbz" },
    }
);

{
    no warnings 'redefine';
    *LANraragi::Model::Config::get_redis = sub { return $path_redis };

    *LANraragi::Model::Archive::extract_single_file = sub {
        my ( $archive, $path ) = @_;
        return "BLOB-for-$path-from-$archive";
    };

    # Bypass the CHI PageCache so get_page_data always resolves the archive
    # path (the path lookup is what the memo optimizes).
    *LANraragi::Model::Archive::fetch = sub { return undef };
    *LANraragi::Model::Archive::put   = sub { return undef };
}

subtest "get_page_data caches the archive path per id" => sub {
    plan tests => 4;

    my $first_open  = $path_redis->quit_count();
    my $content1    = LANraragi::Model::Archive::get_page_data( "arc1", "001.jpg" );
    my $after_first = $path_redis->quit_count();

    is( $content1, "BLOB-for-001.jpg-from-/library/archive-one.cbz",
        "first miss extracts from the resolved archive path" );

    my $content2     = LANraragi::Model::Archive::get_page_data( "arc1", "002.jpg" );
    my $after_second = $path_redis->quit_count();

    is( $content2, "BLOB-for-002.jpg-from-/library/archive-one.cbz",
        "second miss for the same id resolves the same path" );
    is( $after_first - $first_open, 1, "first resolve opened one Redis connection" );
    is( $after_second - $after_first, 0, "second resolve reused the memo (no new connection)" );
};

subtest "invalidate_archive_path_cache(id) drops only that id" => sub {
    plan tests => 2;

    LANraragi::Model::Archive::invalidate_archive_path_cache("arc1");

    my $before = $path_redis->quit_count();
    LANraragi::Model::Archive::get_page_data( "arc1", "003.jpg" );
    LANraragi::Model::Archive::get_page_data( "arc2", "001.jpg" );
    my $after = $path_redis->quit_count();
    is( $after - $before, 2, "invalidated id and fresh id each re-open Redis" );

    # Now both memoized: two more misses must NOT re-open.
    $before = $path_redis->quit_count();
    LANraragi::Model::Archive::get_page_data( "arc1", "004.jpg" );
    LANraragi::Model::Archive::get_page_data( "arc2", "002.jpg" );
    $after = $path_redis->quit_count();
    is( $after - $before, 0, "both ids memoized again -> no new connections" );
};

subtest "invalidate_archive_path_cache() with no arg drops everything" => sub {
    plan tests => 1;

    LANraragi::Model::Archive::invalidate_archive_path_cache();

    my $before = $path_redis->quit_count();
    LANraragi::Model::Archive::get_page_data( "arc1", "005.jpg" );
    LANraragi::Model::Archive::get_page_data( "arc2", "003.jpg" );
    my $after = $path_redis->quit_count();
    is( $after - $before, 2, "wholesale flush forces both ids to re-open Redis" );
};

done_testing();
