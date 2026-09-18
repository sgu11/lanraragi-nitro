use v5.36;
use strict;
use warnings;
use Test::More;
use Mojo::JSON qw(encode_json decode_json);
use LANraragi::Model::Dedup::CoverIndex;
require './tests/redis_test_server.pl';
my ($redis, $guard) = start_test_redis();
my $pair = ('a' x 40) . '|' . ('b' x 40);
my $index = 'LANraragi::Model::Dedup::CoverIndex';
my $patch = \&LANraragi::Model::Dedup::CoverIndex::patch_pair_meta;
ok(!defined $patch->($redis, $pair, {status => 'same_cover'}), 'removed pair cannot be recreated by stale review');
$redis->zadd($index->PAIR_KEY, 0, $pair);
$redis->hset($index->PAIR_META_KEY, $pair, encode_json({status => 'new', cover_algo_version => 2}));
is(LANraragi::Model::Dedup::CoverIndex::active_deck_size($redis), 1, 'new candidate consumes one deck slot');
my $previous = $patch->($redis, $pair, {status => 'variant'});
is($previous->{status}, 'new', 'atomic update returns actual previous decision');
$patch->($redis, $pair, {verification => {state => 'same_images'}});
my $meta = decode_json($redis->hget($index->PAIR_META_KEY, $pair));
is($meta->{status}, 'variant', 'background evidence cannot overwrite human review');
is($meta->{verification}{state}, 'same_images', 'evidence is stored alongside decision');
is(LANraragi::Model::Dedup::CoverIndex::active_deck_size($redis), 0, 'reviewed candidate frees its deck slot');
is($redis->zcard($index->PAIR_KEY), 1, 'review history remains queryable');
$patch->($redis, $pair, {status => 'new'});
is(LANraragi::Model::Dedup::CoverIndex::active_deck_size($redis), 1, 'reopened review counts again');
my $old = $redis->hget($index->PAIR_META_KEY, $pair);
$patch->($redis, $pair, {generation => 'replacement'});
ok(!defined $patch->($redis, $pair, {verification => {state => 'same_images'}}, $old),
    'late verification cannot label a changed/replaced candidate');
$redis->hset($index->PAIR_META_KEY, $pair, 'null');
is(LANraragi::Model::Dedup::CoverIndex::active_deck_size($redis), 1, 'corrupt metadata does not crash deck counting');
$redis->zadd($index->PAIR_KEY, 22, $pair);
$patch->($redis, $pair, {status => 'not_duplicate'});
LANraragi::Model::Dedup::CoverIndex::_trim_unreviewed_pairs($redis, 0);
is($redis->zcard($index->PAIR_KEY), 1, 'tightening the threshold preserves a human decision');
$patch->($redis, $pair, {status => 'new'});
LANraragi::Model::Dedup::CoverIndex::_trim_unreviewed_pairs($redis, 0);
is($redis->zcard($index->PAIR_KEY), 0, 'unreviewed high-distance candidate releases its slot');

{
    package CountingRedis;
    sub new { bless {redis => $_[1], calls => 0}, $_[0] }
    sub zrange { shift->{redis}->zrange(@_) }
    sub wait_all_responses { shift->{redis}->wait_all_responses }
    sub hmget { my $self = shift; $self->{calls}++; $self->{redis}->hmget(@_) }
}
for my $n (1 .. 513) {
    my $member = sprintf('%040x|%040x', $n, $n + 1000);
    $redis->zadd($index->PAIR_KEY, 0, $member);
    $redis->hset($index->PAIR_META_KEY, $member, encode_json({status => $n % 2 ? 'new' : 'variant'}));
}
my $counted = CountingRedis->new($redis);
is(LANraragi::Model::Dedup::CoverIndex::active_deck_size($counted), 257, 'batched counting retains exact status filtering');
is($counted->{calls}, 3, '513 historical pairs require three bounded HMGETs rather than 513 commands');
$redis->sadd('LRR_ALL_ARCHIVES', 'valid', 'broken');
$redis->hmset('valid', coverhash_v => 2, coverhash => '0' x 16);
$redis->hmset('broken', coverhash_v => 2, coverhash => 'z' x 16);
my $stats = LANraragi::Model::Dedup::CoverIndex::cover_stats($redis, $redis);
is($stats->{archives_with_coverhashes}, 1, 'Lua stats require valid hash bytes as well as the version');
is($stats->{archives_cover_pending}, 1, 'corrupt current-version hash remains pending repair');
done_testing();
