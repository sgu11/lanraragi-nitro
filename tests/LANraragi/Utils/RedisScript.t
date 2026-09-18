use v5.36;
use strict;
use warnings;

use Test::More;

use LANraragi::Utils::RedisScript qw(evalsha_cached);

package RedisScriptTestRedis {
    sub new {
        my ($class, %args) = @_;
        return bless {
            load_shas        => $args{load_shas} // [],
            eval_results     => $args{eval_results} // [],
            script_load_seen => [],
            evalsha_seen     => [],
        }, $class;
    }

    sub script_load {
        my ($self, $script) = @_;
        push @{$self->{script_load_seen}}, $script;
        return shift @{$self->{load_shas}};
    }

    sub evalsha {
        my ($self, @args) = @_;
        push @{$self->{evalsha_seen}}, \@args;
        my $result = shift @{$self->{eval_results}};
        die $result->{die} if ref $result eq 'HASH' && exists $result->{die};
        return $result;
    }
}

package main;

my $script = "return ARGV[1]";

subtest 'initial load forwards the zero key count and all arguments' => sub {
    my $redis = RedisScriptTestRedis->new(
        load_shas    => ['sha-initial'],
        eval_results => ['initial result'],
    );

    is(
        evalsha_cached($redis, 'redis-script-initial', $script, 'first', 'second'),
        'initial result',
        'returns the initial EVALSHA result'
    );
    is_deeply($redis->{script_load_seen}, [$script], 'loads the script once initially');
    is_deeply(
        $redis->{evalsha_seen},
        [['sha-initial', 0, 'first', 'second']],
        'uses zero Redis keys and preserves all script arguments'
    );
};

subtest 'reuses the cached SHA for the same script name' => sub {
    my $redis = RedisScriptTestRedis->new(
        load_shas    => ['sha-reused'],
        eval_results => ['first result', 'second result'],
    );

    is(evalsha_cached($redis, 'redis-script-reused', $script, 'one'), 'first result',
        'first invocation succeeds');
    is(evalsha_cached($redis, 'redis-script-reused', $script, 'two'), 'second result',
        'second invocation succeeds');
    is(scalar @{$redis->{script_load_seen}}, 1, 'script body is uploaded only once');
    is_deeply(
        $redis->{evalsha_seen},
        [
            ['sha-reused', 0, 'one'],
            ['sha-reused', 0, 'two'],
        ],
        'both calls use the cached SHA with their own arguments'
    );
};

subtest 'reloads when a logical script name receives a changed body' => sub {
    my $changed_script = "return ARGV[2]";
    my $redis = RedisScriptTestRedis->new(
        load_shas    => ['sha-before-change', 'sha-after-change'],
        eval_results => ['old body result', 'new body result'],
    );

    is(evalsha_cached($redis, 'redis-script-body-change', $script, 'one'), 'old body result',
        'initial body succeeds');
    is(evalsha_cached($redis, 'redis-script-body-change', $changed_script, 'two'), 'new body result',
        'changed body succeeds');
    is_deeply(
        $redis->{script_load_seen},
        [$script, $changed_script],
        'changed script body receives a new SCRIPT LOAD'
    );
    is_deeply(
        $redis->{evalsha_seen},
        [
            ['sha-before-change', 0, 'one'],
            ['sha-after-change', 0, 'two'],
        ],
        'changed body never executes under the previous SHA'
    );
};

subtest 'reloads once after NOSCRIPT and retries the request' => sub {
    my $redis = RedisScriptTestRedis->new(
        load_shas => ['sha-stale', 'sha-reloaded'],
        eval_results => [
            { die => "NOSCRIPT No matching script. Please use EVAL.\n" },
            'retried result',
        ],
    );

    is(evalsha_cached($redis, 'redis-script-noscript', $script, 'retry-arg'), 'retried result',
        'returns the retry result');
    is_deeply($redis->{script_load_seen}, [$script, $script], 'reloads once after NOSCRIPT');
    is_deeply(
        $redis->{evalsha_seen},
        [
            ['sha-stale', 0, 'retry-arg'],
            ['sha-reloaded', 0, 'retry-arg'],
        ],
        'retries the same invocation with the replacement SHA'
    );
};

subtest 'propagates non-NOSCRIPT failures without a reload' => sub {
    my $redis = RedisScriptTestRedis->new(
        load_shas => ['sha-error'],
        eval_results => [
            { die => "ERR user script failed\n" },
        ],
    );

    my $ok = eval {
        evalsha_cached($redis, 'redis-script-error', $script, 'failure-arg');
        1;
    };
    ok(!$ok, 'non-NOSCRIPT error fails the call');
    like($@, qr/ERR user script failed/, 'propagates the original error');
    is(scalar @{$redis->{script_load_seen}}, 1, 'does not reload after another Redis error');
    is(scalar @{$redis->{evalsha_seen}}, 1, 'does not retry after another Redis error');
};

done_testing();
