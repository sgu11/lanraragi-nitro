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
    our @hdel_seen;
    our $sweep_calls;
    our $cleanup_calls;
}

package CoverRebuildRedis {
    sub new { bless {}, shift }
    sub hget {
        my ($self, $key, $field) = @_;
        return $CoverRebuildTestData::hash{$key}{$field} // '';
    }
    sub hset {
        my ($self, $key, $field, $value) = @_;
        $CoverRebuildTestData::hash{$key}{$field} = $value;
        return 1;
    }
    sub hdel {
        my ($self, $key, @fields) = @_;
        push @CoverRebuildTestData::hdel_seen, [ $key, @fields ];
        delete $CoverRebuildTestData::hash{$key}{$_} for @fields;
        return 1;
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

package CoverTaskMinion {
    our %tasks;
    sub new { bless {}, shift }
    sub add_task {
        my ($self, $name, $code) = @_;
        $tasks{$name} = $code;
        return 1;
    }
}

package main;

sub reset_cover_rebuild_state {
    %CoverRebuildTestData::hash = ();
    @CoverRebuildTestData::enqueued = ();
    @CoverRebuildTestData::hdel_seen = ();
    %CoverTaskMinion::tasks = ();
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
    is($job->{finished}{in_flight}, 0, "no existing in-flight jobs reported");
    is($job->{finished}{requeued}, 1, "follow-up sweep is reported");
}

note("find_cover_duplicates_isolated does not enqueue duplicate coverhash jobs already in flight");
reset_cover_rebuild_state();
{
    $CoverRebuildTestData::hash{'LRR_COVER_HASH_INFLIGHT'}{id1} = time();

    my $job = CoverRebuildJob->new;
    LANraragi::Utils::Minion::Dedup::_run_find_cover_duplicates_isolated(
        $job,
        CoverRebuildRedis->new,
        CoverRebuildRedis->new,
        22,
    );

    is_deeply(
        [ map { $_->[0] } @CoverRebuildTestData::enqueued ],
        [ 'compute_coverhash', 'find_cover_duplicates_isolated' ],
        "only archives without a fresh in-flight marker are enqueued"
    );
    is($CoverRebuildTestData::enqueued[0][1][0], 'id2', "id2 is the only new coverhash job");
    is($job->{finished}{pending}, 2, "both archives still count as pending");
    is($job->{finished}{enqueued}, 1, "only one new hash job is enqueued");
    is($job->{finished}{in_flight}, 1, "one existing in-flight hash job is reported");
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

note("compute_coverhash clears the in-flight marker when the job finishes");
reset_cover_rebuild_state();
{
    $CoverRebuildTestData::hash{'LRR_COVER_HASH_INFLIGHT'}{id1} = time();
    $config_mod->redefine('get_redis',        sub { CoverRebuildRedis->new });
    $config_mod->redefine('get_redis_config', sub { CoverRebuildRedis->new });

    my $dedup_mod = Test::MockModule->new('LANraragi::Model::Dedup');
    $dedup_mod->redefine('compute_coverhash_for_archive', sub { 1 });

    my $task_minion = CoverTaskMinion->new;
    LANraragi::Utils::Minion::Dedup::add_tasks($task_minion);

    my $job = CoverRebuildJob->new;
    $CoverTaskMinion::tasks{compute_coverhash}->($job, 'id1');

    is($CoverRebuildTestData::hash{'LRR_COVER_HASH_INFLIGHT'}{id1}, undef, "in-flight marker removed");
    is_deeply($CoverRebuildTestData::hdel_seen[-1], [ 'LRR_COVER_HASH_INFLIGHT', 'id1' ], "marker cleanup uses the expected Redis hash");
    is($CoverRebuildTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{band_buckets_built}, 0,
        "successful coverhash write marks band buckets stale");
    is($job->{finished}{rc}, 1, "job result preserved");
}

done_testing();
