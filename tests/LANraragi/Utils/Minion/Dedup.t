use strict;
use warnings;
use v5.36;
use Test::More;
use Test::MockModule qw(strict);
use Cwd qw(getcwd);

my $cwd = getcwd();
require "$cwd/tests/mocks.pl";
setup_redis_mock();

use_ok('LANraragi::Utils::Minion::Dedup');

package CoverRebuildTestData {
    our %hash;
    our @enqueued;
    our $sweep_calls;
    our $cleanup_calls;
}

package CoverRebuildRedis {
    sub new { bless {}, shift }
    sub hget {
        my ($self, $key, $field) = @_;
        return $CoverRebuildTestData::hash{$key}{$field} // '';
    }
    sub hgetall {
        my ($self, $key) = @_;
        return (cover_algo_version => 1) if $key eq 'LRR_DEDUP_CONFIG';
        return ();
    }
    sub quit { 1 }
}

package CoverRebuildMinion {
    sub new { bless {}, shift }
    sub enqueue {
        my ($self, $task, $args, $opts) = @_;
        push @CoverRebuildTestData::enqueued, [ $task, $args, $opts ];
        return scalar @CoverRebuildTestData::enqueued;
    }
}

package CoverRebuildJob {
    sub new { bless { finished => undef }, shift }
    sub finish {
        my ($self, $payload) = @_;
        $self->{finished} = $payload;
    }
}

package main;

sub reset_cover_rebuild_state {
    %CoverRebuildTestData::hash = ();
    @CoverRebuildTestData::enqueued = ();
    $CoverRebuildTestData::sweep_calls = 0;
    $CoverRebuildTestData::cleanup_calls = 0;
}

my $config_mod = Test::MockModule->new('LANraragi::Model::Config');
$config_mod->redefine('get_minion', sub { CoverRebuildMinion->new });

my $db_mod = Test::MockModule->new('LANraragi::Utils::Database');
$db_mod->redefine('all_archive_ids', sub { ('id1', 'id2') });

my $cover_index_mod = Test::MockModule->new('LANraragi::Model::Dedup::CoverIndex');
$cover_index_mod->redefine('cleanup_legacy_cover_pairs', sub {
    $CoverRebuildTestData::cleanup_calls++;
    return 0;
});
$cover_index_mod->redefine('run_cover_candidate_sweep', sub {
    $CoverRebuildTestData::sweep_calls++;
    return { stored => 1, candidates => 1, truncated => 0, sweep_done => 1 };
});

note("find_cover_duplicates_isolated reschedules itself after queuing missing cover hashes");
reset_cover_rebuild_state();
{
    my $job = CoverRebuildJob->new;
    LANraragi::Utils::Minion::Dedup::_run_find_cover_duplicates_isolated(
        $job,
        CoverRebuildRedis->new,
        CoverRebuildRedis->new,
        22,
    );

    is($CoverRebuildTestData::sweep_calls, 0, "sweep deferred while hashes are missing");
    is_deeply(
        [ map { $_->[0] } @CoverRebuildTestData::enqueued ],
        [ 'compute_coverhash', 'compute_coverhash', 'find_cover_duplicates_isolated' ],
        "hash jobs and follow-up sweep job enqueued from one rebuild"
    );
    is($CoverRebuildTestData::enqueued[-1][1][0], 22, "threshold forwarded to follow-up sweep");
    ok($job->{finished}{sweep_deferred}, "job reports deferred sweep");
    is($job->{finished}{pending}, 2, "pending count reported");
    is($job->{finished}{requeued}, 1, "follow-up sweep is reported");
}

note("find_cover_duplicates_isolated runs sweep when hashes are ready");
reset_cover_rebuild_state();
{
    $CoverRebuildTestData::hash{id1}{coverhash_v} = '1';
    $CoverRebuildTestData::hash{id2}{coverhash_v} = '1';
    my $job = CoverRebuildJob->new;
    LANraragi::Utils::Minion::Dedup::_run_find_cover_duplicates_isolated(
        $job,
        CoverRebuildRedis->new,
        CoverRebuildRedis->new,
        22,
    );

    is($CoverRebuildTestData::sweep_calls, 1, "sweep runs once hashes are ready");
    is(scalar @CoverRebuildTestData::enqueued, 0, "no unnecessary jobs enqueued");
    is($job->{finished}{sweep_deferred}, 0, "job reports completed sweep");
    is($job->{finished}{stored}, 1, "sweep result returned");
}

done_testing();
