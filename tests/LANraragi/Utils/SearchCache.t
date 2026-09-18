use v5.36;
use strict;
use warnings;
use Test::More;
use LANraragi::Utils::SearchCache qw(store_results read_result_page);
require './tests/redis_test_server.pl';
my ($redis, $guard) = start_test_redis();
my @ids = map { sprintf('%040x', $_) } 0..9999;
$ids[-1] = 'TANK_1234567890';
store_results($redis, 'asc', 7500, \@ids);
for my $start (0, 7485, 7500, 9990, 10000, -1) {
    for my $inverse (0, 1) {
        my @expected = $inverse ? (reverse(@ids[0..7499]), @ids[7500..9999]) : @ids;
        @expected = $start >= @expected ? () : @expected[$start .. List::Util::min($start+29, $#expected)] if $start >= 0;
        my ($hit, $count, @actual) = read_result_page($redis, $inverse ? 'missing' : 'asc', 'asc', $start, 30);
        ok($hit, 'cached result is present');
        is($count, 10000, 'full result count is independent of page size');
        is_deeply(\@actual, \@expected, "page $start inverse=$inverse preserves keyed boundary and tank IDs");
    }
}
store_results($redis, 'empty', -1, []);
is_deeply([read_result_page($redis, 'empty', 'none', 0, 30)], [1, 0], 'empty cached results are hits');
$redis->set('broken', pack('NN', 100, 100));
is_deeply([read_result_page($redis, 'broken', 'none', 0, 30)], [0, 0], 'truncated/expired payload is a miss');
cmp_ok($redis->ttl('asc'), '>', 0, 'result has bounded retention');
done_testing();
