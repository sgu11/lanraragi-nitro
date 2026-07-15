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
}

package main;

my $redis;
my $config_mod = Test::MockModule->new('LANraragi::Model::Config');
$config_mod->redefine('get_redis_config', sub { $redis = IngestTaskRedis->new });

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
    $task->($job, $filename, 'LRR_INGEST_PENDING:test');
    ok($job->{failed}, "$state attempt is failed through Minion");
    is(scalar @{$redis->{deleted}}, $expect_deleted, $description);
}

done_testing();
