use v5.36;
use strict;
use warnings;
use Test::More;
use Test::MockModule qw(strict);
use LANraragi::Model::Dedup::CoverIndex;
require './tests/redis_test_server.pl';
my ($redis, $guard) = start_test_redis();
my $config_db = Test::MockModule->new('LANraragi::Model::Config');
$config_db->redefine(get_configdb => sub { 0 });
my @ids;
my $db = Test::MockModule->new('LANraragi::Utils::Database');
$db->redefine(all_archive_ids => sub { @ids });
my $logging = Test::MockModule->new('LANraragi::Utils::Logging');
{
    package QuietCoverLogger;
    sub info { 1 }
    sub warn { 1 }
}
$logging->redefine(get_logger => sub { bless {}, 'QuietCoverLogger' });
my $key = LANraragi::Model::Dedup::CoverIndex::CONFIG_KEY();
my $pairs = LANraragi::Model::Dedup::CoverIndex::PAIR_KEY();
my $sweep = \&LANraragi::Model::Dedup::CoverIndex::run_cover_candidate_sweep;
sub id { sprintf '%040x', $_[0] }

@ids = (id(1), id(2));
$redis->hmset($ids[0], coverhash => '0000000000000000', coverhash_v => 2);
$redis->hmset($ids[1], coverhash => '0001000100010001', coverhash_v => 2);
$redis->hset($key, cover_sweep_mode => 'banded');
is($sweep->($redis, $redis, 4)->{stored}, 1, 'distance-four pair with no shared 16-bit band is still found');

# This server is isolated, Unix-socket-only and has no persistence.
$redis->flushdb;
@ids = (id(0), id(2), id(3));
$redis->hmset($ids[0], coverhash => '0' x 16, coverhash_v => 2);
$redis->hmset($ids[1], coverhash => 'f' x 16, coverhash_v => 2);
$redis->hmset($ids[2], coverhash => '0' x 16, coverhash_v => 2);
$redis->hmset($key, cover_cursor_threshold => 0, cover_cursor_i => 1,
    cover_cursor_j => 2, cover_inventory => 'previous library');
is($sweep->($redis, $redis, 0)->{stored}, 1, 'changed inventory restarts numeric cursor and finds a newly inserted first ID');
ok(defined $redis->zscore($pairs, id(0) . '|' . id(3)), 'new exact-cover candidate is retained');

$redis->flushdb;
@ids = map { id($_) } 1 .. 101;
$redis->hmset($_, coverhash => '0' x 16, coverhash_v => 2) for @ids;
$redis->hmset($key, cover_sweep_mode => 'banded', candidate_bucket_cap => 100);
is($sweep->($redis, $redis, 0)->{stored}, 100, 'oversized bucket falls back to exact sweep instead of silently losing all candidates');

$redis->sadd(LANraragi::Model::Dedup::CoverIndex::DISMISSED_KEY(), id(1) . '|' . id(2), id(3) . '|' . id(4));
LANraragi::Model::Dedup::CoverIndex::invalidate_cover_dedup_signals($redis, $redis, id(1));
ok(!$redis->sismember(LANraragi::Model::Dedup::CoverIndex::DISMISSED_KEY(), id(1) . '|' . id(2)),
    'same-ID replacement clears obsolete dismissal');
ok($redis->sismember(LANraragi::Model::Dedup::CoverIndex::DISMISSED_KEY(), id(3) . '|' . id(4)),
    'replacement preserves unrelated decisions');
done_testing();
