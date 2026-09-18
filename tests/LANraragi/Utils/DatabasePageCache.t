use strict;
use warnings;
use utf8;

use File::Temp qw(tempfile);
use Test::More;

use LANraragi::Utils::Database;
use LANraragi::Model::Archive;

require './tests/redis_test_server.pl';
my ($redis, $redis_guard) = start_test_redis();

my $old_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
my $new_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
my ( $fh, $archive_path ) = tempfile( UNLINK => 1 );
print {$fh} "archive bytes";
close $fh;

$redis->hset($old_id, file => $archive_path, tags => 'artist:someone', title => 'Old title',
    firstspreadstart => '4', firstspreadstart_reason => 'user_slide', firstspreadstart_revision => 2,
    pagefiles => '["old"]', firstspreadstart_status => 'detected');
my @path_clears;
my @page_cache_clears;

{
    no warnings 'redefine';
    local *Redis::quit = sub { 1 };
    local *LANraragi::Model::Config::get_redis = sub { return $redis };
    local *LANraragi::Utils::Database::get_archive_path = sub { return $archive_path };
    local *LANraragi::Model::Archive::invalidate_archive_path_cache = sub { push @path_clears, @_ };
    local *LANraragi::Utils::Database::clear_by_id = sub { push @page_cache_clears, @_ };
    local *LANraragi::Model::Category::get_categories_containing_archive = sub { return () };
    local *LANraragi::Model::Tankoubon::get_tankoubons_containing_archive = sub { return () };

    LANraragi::Utils::Database::change_archive_id( $old_id, $new_id );
}

is_deeply( \@path_clears, [ $old_id, $new_id ], "change_archive_id invalidates archive path memo for old and new ids" );
is_deeply( \@page_cache_clears, [ $old_id, $new_id ], "change_archive_id clears page-cache variants for old and new ids" );

ok(!$redis->exists($old_id), 'old content identity removed');
ok(!defined $redis->hget($new_id, 'firstspreadstart'), 'old correction cleared on content identity change');
ok(!defined $redis->hget($new_id, 'pagefiles'), 'old page list cleared');
is($redis->hget($new_id, 'firstspreadstart_revision'), 3, 'in-flight revision invalidated on rename');
is($redis->hget($new_id, 'title'), 'Old title', 'unrelated archive metadata retained');
done_testing();
