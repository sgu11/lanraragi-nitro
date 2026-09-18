use v5.36;
use strict;
use warnings;
use Test::More;
use LANraragi::Utils::Minion::Dedup;
require './tests/redis_test_server.pl';
my ($redis, $guard) = start_test_redis();
my $claim = \&LANraragi::Utils::Minion::Dedup::_claim_coverhash_inflight;
my $release = \&LANraragi::Utils::Minion::Dedup::_clear_coverhash_inflight;
my $token = $claim->($redis, 'archive');
ok(defined $token, 'first caller claims the lease');
ok(!defined $claim->($redis, 'archive'), 'second caller cannot claim the same lease');
$redis->hset('LRR_COVER_HASH_INFLIGHT', 'archive', '1:expired');
my $next = $claim->($redis, 'archive');
ok(defined $next && $next ne $token, 'expired lease has a new owner');
$release->($redis, 'archive', $token);
is($redis->hget('LRR_COVER_HASH_INFLIGHT', 'archive'), $next, 'old owner cannot release new work');
$release->($redis, 'archive', $next);
ok(!defined $redis->hget('LRR_COVER_HASH_INFLIGHT', 'archive'), 'current owner releases lease');

package FailedEnqueue {
    sub new { bless {}, shift }
    sub enqueue { die "queue unavailable\n" }
}
package main;
eval { LANraragi::Utils::Minion::Dedup::_enqueue_coverhash_unless_inflight($redis, FailedEnqueue->new, 'archive'); };
like($@, qr/queue unavailable/, 'enqueue failure is reported');
ok(!defined $redis->hget('LRR_COVER_HASH_INFLIGHT', 'archive'), 'enqueue failure returns its lease');
$redis->hset('LRR_COVER_HASH_INFLIGHT', 'archive', time());
ok(!defined $claim->($redis, 'archive'), 'fresh legacy timestamp remains protected during upgrade');
done_testing();
