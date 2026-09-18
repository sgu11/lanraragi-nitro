use strict;
use warnings;
use v5.36;

use Cwd qw(getcwd);
use File::Temp qw(tempfile);
use Test::More;
use Test::MockModule qw(strict);

my $cwd;
BEGIN {
    $cwd = getcwd();
    require "$cwd/tests/mocks.pl";
    setup_redis_mock();
}

use_ok('LANraragi::Utils::Minion');
require Shinobu;

package IngestTaskMinion {
    our %tasks;
    sub new { bless {}, shift }
    sub add_task { $tasks{$_[1]} = $_[2]; 1 }
    sub on { 1 }
}

package IngestTaskRedis {
    sub new { bless { deleted => [] }, shift }
    sub del { push @{$_[0]->{deleted}}, $_[1]; 1 }
    sub quit { 1 }
}

package IngestTaskJob {
    sub new { bless { state => $_[1], failed => undef }, $_[0] }
    sub fail { $_[0]->{failed} = $_[1]; 1 }
    sub info { +{ state => $_[0]->{state} } }
    sub finish { $_[0]->{finished} = $_[1]; 1 }
}

package IngestTaskLogger {
    sub new { bless {}, shift }
    sub error { 1 }
    sub info { 1 }
}

package main;

my $redis;
my $config_mod = Test::MockModule->new('LANraragi::Model::Config');
$config_mod->redefine('get_redis_config', sub { $redis = IngestTaskRedis->new });

my $lease_mod = Test::MockModule->new('LANraragi::Utils::Minion');
$lease_mod->redefine(_release_owned_lease => sub {
    my ($redis, $key, $token) = @_;
    return unless defined $token;
    return $redis->del($key);
});
my $minion = IngestTaskMinion->new;
LANraragi::Utils::Minion::add_tasks($minion);
my $task = $IngestTaskMinion::tasks{ingest_archive_file};
ok($task, 'ingest task registered');

my ( $fh, $filename ) = tempfile( SUFFIX => '.cbz', UNLINK => 1 );
print {$fh} "archive";
close $fh;

no warnings 'redefine';
local *LANraragi::Utils::Minion::get_logger = sub { IngestTaskLogger->new };
local *Shinobu::add_to_filemap = sub { die "broken ingest\n" };

for my $case (
    [ inactive => 0, 'retryable failure retains the lease' ],
    [ failed   => 1, 'terminal failure clears the lease' ],
) {
    my ($state, $expect_deleted, $description) = @$case;
    my $job = IngestTaskJob->new($state);
    $task->($job, $filename, 'LRR_INGEST_PENDING:test', 'test-owner');
    ok($job->{failed}, "$state attempt is failed through Minion");
    is(scalar @{$redis->{deleted}}, $expect_deleted, $description);
}

my $restore_task = $IngestTaskMinion::tasks{restore_backup};
ok($restore_task, 'restore task registered');

{
    my @lock_args;
    local *LANraragi::Utils::Minion::exec_with_lock_pure = sub {
        @lock_args = @_;
        return ( 0, undef );
    };

    my $job = IngestTaskJob->new('inactive');
    $restore_task->( $job, '{}' );
    is_deeply( $lock_args[0], ['database-restore'], 'restore uses a dedicated global lock' );
    is( $lock_args[3], 86400, 'restore lock covers long-running restores' );
    like( $job->{failed}{error}, qr/Another backup restore is already running/, 'concurrent restore is rejected' );
}

{
    my $restored;
    local *LANraragi::Utils::Minion::exec_with_lock_pure = sub {
        my ( undef, $callback ) = @_;
        return ( 1, $callback->() );
    };
    local *LANraragi::Model::Backup::restore_from_JSON = sub {
        ( $restored ) = @_;
        return;
    };

    my $job = IngestTaskJob->new('inactive');
    $restore_task->( $job, '{"categories":[],"archives":[]}' );
    is( $restored, '{"categories":[],"archives":[]}', 'locked restore invokes the backup model' );
    is_deeply( $job->{finished}, { success => 1 }, 'successful restore finishes the job' );
}

done_testing();
