use v5.36;
use strict;
use warnings;
use lib 'lib';
use Test::More;
use Time::HiRes qw(time);
use Mojo::JSON qw(encode_json decode_json);
use LANraragi::Model::Dedup::CoverIndex;
require './tests/redis_test_server.pl';

# Synthetic records on an isolated Unix-socket Redis. Never uses app data.
my $n = $ARGV[0] // 10_000;
die "Expected 1..50000 records\n" unless $n =~ /\A\d+\z/ && $n >= 1 && $n <= 50_000;
my ($redis, $guard) = start_test_redis();
my $pair_key = LANraragi::Model::Dedup::CoverIndex::PAIR_KEY();
my $meta_key = LANraragi::Model::Dedup::CoverIndex::PAIR_META_KEY();
for my $i (1 .. $n) {
    my $member = sprintf '%040x|%040x', $i, $i + $n;
    $redis->zadd($pair_key, 0, $member, sub {});
    $redis->hset($meta_key, $member, encode_json({status => $i % 2 ? 'new' : 'variant', cover_algo_version => 2}), sub {});
}
$redis->wait_all_responses;
my (@before, @after);
for (1 .. 5) {
    my $start = time();
    my @members = $redis->zrange($pair_key, 0, -1);
    my $old_count = 0;
    for my $member (@members) {
        $redis->hmget($meta_key, $member, sub {
            my $meta = decode_json($_[0][0]);
            $old_count++ if ($meta->{status} // 'new') eq 'new';
        });
    }
    $redis->wait_all_responses;
    push @before, 1000 * (time() - $start);
    $start = time();
    my $new_count = LANraragi::Model::Dedup::CoverIndex::active_deck_size($redis);
    push @after, 1000 * (time() - $start);
    die "Result mismatch\n" unless $new_count == $old_count && $old_count == int(($n + 1) / 2);
}
@before = sort {$a <=> $b} @before;
@after = sort {$a <=> $b} @after;
print encode_json({ records => 0 + $n, runs => 5, before_ms => $before[2], after_ms => $after[2],
    before_metadata_commands => 0 + $n, after_metadata_commands => int(($n + 255) / 256) }), "\n";
