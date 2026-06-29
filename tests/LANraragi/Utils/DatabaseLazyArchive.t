use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi::Model::Backup;
use LANraragi::Utils::Database;

package FakeCleanDatabaseRedis {
    sub new { return bless { quit_count => 0 }, shift }
    sub exists { return 0 }
    sub hexists { return 0 }
    sub hget { return undef }
    sub hvals { return () }
    sub smembers { return () }
    sub keys { return () }
    sub quit { shift->{quit_count}++; return 1 }
}

package main;

ok( !exists $INC{"LANraragi/Model/Archive.pm"}, "Backup/Database load path has not loaded Model::Archive yet" );

my $archive_redis = FakeCleanDatabaseRedis->new;
my $config_redis  = FakeCleanDatabaseRedis->new;
my $autobackup_dir;

{
    no warnings 'redefine';
    local *LANraragi::Model::Config::get_redis        = sub { return $archive_redis };
    local *LANraragi::Model::Config::get_redis_config = sub { return $config_redis };
    local *LANraragi::Model::Backup::build_backup_JSON = sub { return "{}" };
    local *LANraragi::Utils::Database::getcwd = sub {
        require File::Temp;
        $autobackup_dir //= File::Temp::tempdir( CLEANUP => 1 );
        return $autobackup_dir;
    };

    my $ok = eval {
        LANraragi::Utils::Database::clean_database();
        1;
    };

    ok( $ok, "clean_database can lazy-load Model::Archive before cache invalidation" ) or diag($@);
}

done_testing();
