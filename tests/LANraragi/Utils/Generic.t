use strict;
use warnings;
use utf8;
use Data::Dumper;
use Encode qw(decode_utf8);

use Test::More;
use Test::Deep;

BEGIN { use_ok('LANraragi::Utils::Generic'); }

package FakeLockRedis {
    sub new {
        my ($class) = @_;
        return bless { set_calls => [], eval_calls => [] }, $class;
    }

    sub set {
        my ( $self, @args ) = @_;
        push @{ $self->{set_calls} }, \@args;
        return 1;
    }

    sub eval {
        my ( $self, @args ) = @_;
        push @{ $self->{eval_calls} }, \@args;
        return 1;
    }
}

package main;

note('testing rules flattening...');

{
    my $tagrules = [
        [ 'strip_ns', 'namespace', '' ],
        [ 'replace', 'scream', 'Please Stop' ],
        [ 'remove', 'ping', '']
    ];

    my @flattened_rules = LANraragi::Utils::Generic::flat(@$tagrules);
    cmp_deeply(
        \@flattened_rules,
        [
            'strip_ns',
            'namespace',
            '',
            'replace',
            'scream',
            'Please Stop',
            'remove',
            'ping',
            ''
        ],
        'flattened rules');
}

note('testing lock names...');

{
    my $redis = FakeLockRedis->new;
    my ( $acquired, $response );
    my $err = "";

    eval {
        ( $acquired, $response ) = LANraragi::Utils::Generic::exec_with_lock_pure(
            ["upload:한글.zip"],
            sub { return "locked"; },
            $redis
        );
        1;
    } or $err = $@;

    is( $err,      "",       "unicode lock names do not fail digest token generation" );
    ok( $acquired,           "unicode lock is acquired" );
    is( $response, "locked", "unicode lock callback response is returned" );
    my $lock_key = $redis->{set_calls}[0] ? $redis->{set_calls}[0][0] : "";
    ok( $lock_key ne "" && !utf8::is_utf8($lock_key), "unicode lock key is passed to redis as bytes" );
    is( $lock_key ne "" ? decode_utf8($lock_key) : "", "upload:한글.zip", "unicode lock key preserves its text" );
}

note('testing bounded Minion and nested MCE concurrency...');

{
    local $ENV{LRR_CPU_COUNT};
    local $ENV{LRR_MINION_JOBS};
    local $ENV{LRR_MCE_WORKERS};
    is( LANraragi::Utils::Generic::get_effective_cpu_count( 16, '0,2-4,7-9,11', 'max 100000' ), 8,
        'cpuset restriction wins over host CPU count' );
    is( LANraragi::Utils::Generic::get_effective_cpu_count( 16, '0-15', '400000 100000' ), 4,
        'cgroup quota wins over host and cpuset counts' );
    is( LANraragi::Utils::Generic::get_effective_cpu_count( 16, '0-15', '50000 100000' ), 1,
        'fractional CPU quota still permits one worker' );
    is( LANraragi::Utils::Generic::get_minion_job_count(8), 2, 'defaults to two concurrent Minion jobs' );
    is( LANraragi::Utils::Generic::get_minion_mce_worker_count( 8, 2 ), 4, 'splits the CPU budget across nested MCE workers' );
    is( LANraragi::Utils::Generic::get_minion_job_count(1), 1, 'single-CPU hosts stay single-job' );

    local $ENV{LRR_CPU_COUNT} = 6;
    is( LANraragi::Utils::Generic::get_effective_cpu_count( 16, '0-3', '200000 100000' ), 6,
        'explicit CPU budget override remains authoritative' );
    local $ENV{LRR_MINION_JOBS} = 3;
    local $ENV{LRR_MCE_WORKERS} = 2;
    is( LANraragi::Utils::Generic::get_minion_job_count(8), 3, 'LRR_MINION_JOBS overrides the safe default' );
    is( LANraragi::Utils::Generic::get_minion_mce_worker_count( 8, 3 ), 2, 'LRR_MCE_WORKERS overrides the derived nested budget' );
}

done_testing();
