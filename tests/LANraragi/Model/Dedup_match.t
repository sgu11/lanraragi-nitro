use strict;
use warnings;
use v5.36;
use Test::More;
use Test::MockObject;

use_ok('LANraragi::Model::Dedup');

note("match: bucket by page count, score within tolerance, store pairs <= cap");
{
    my %page_data = (
        "id_a" => { hashes => ["0000000000000000", "0000000000000000", "0000000000000000", "0000000000000000", "0000000000000000"], n => 100 },
        "id_b" => { hashes => ["0000000000000000", "0000000000000000", "0000000000000000", "0000000000000000", "0000000000000000"], n => 105 },
        "id_c" => { hashes => ["ffffffffffffffff", "ffffffffffffffff", "ffffffffffffffff", "ffffffffffffffff", "ffffffffffffffff"], n => 102 },
    );

    my @zadds;
    my @hsets;
    my %dismissed = ();
    my $redis = Test::MockObject->new();
    $redis->mock('zadd',     sub { shift; push @zadds, [ @_ ]; 1 });
    $redis->mock('hset',     sub { shift; push @hsets, [ @_ ]; 1 });
    $redis->mock('del',      sub { 1 });
    $redis->mock('sismember',sub { my (undef, undef, $member) = @_; exists $dismissed{$member} ? 1 : 0 });
    $redis->mock('quit',     sub { 1 });

    my $config = {
        loose_max_score      => 40,
        pcount_tolerance_pct => 20,
        candidate_pair_cap   => 1_000_000,
        algo_version         => 1,
    };

    my $result = LANraragi::Model::Dedup::find_duplicate_pairs_in_memory(\%page_data, $redis, $config);

    is($result->{stored},    1,  "stores 1 pair (a,b)");
    is($result->{candidates},3,  "evaluates 3 candidate pairs (a-b, a-c, b-c)");
    is($result->{truncated}, 0,  "not truncated under cap");

    my ($pair_member) = map { $_->[2] } @zadds;
    is($pair_member, "id_a|id_b", "stored pair member is lex-sorted ids joined by |");
}

note("match: dismissed pairs are skipped");
{
    my %page_data = (
        "id_x" => { hashes => ["0000000000000000"], n => 50 },
        "id_y" => { hashes => ["0000000000000000"], n => 50 },
    );
    my @zadds;
    my %dismissed = ("id_x|id_y" => 1);
    my $redis = Test::MockObject->new();
    $redis->mock('zadd',     sub { shift; push @zadds, [ @_ ]; 1 });
    $redis->mock('hset',     sub { 1 });
    $redis->mock('del',      sub { 1 });
    $redis->mock('sismember',sub { my (undef, undef, $member) = @_; exists $dismissed{$member} ? 1 : 0 });
    $redis->mock('quit',     sub { 1 });

    my $config = { loose_max_score => 40, pcount_tolerance_pct => 20, candidate_pair_cap => 1_000_000, algo_version => 1 };
    my $result = LANraragi::Model::Dedup::find_duplicate_pairs_in_memory(\%page_data, $redis, $config);
    is(scalar(@zadds), 0, "no zadds when pair is dismissed");
    is($result->{stored}, 0, "stored count is 0");
}

note("match: candidate cap truncates and reports");
{
    my %page_data;
    $page_data{"id_$_"} = { hashes => ["0000000000000000"], n => 50 } for 1 .. 50;

    my @zadds;
    my $redis = Test::MockObject->new();
    $redis->mock('zadd',     sub { shift; push @zadds, [ @_ ]; 1 });
    $redis->mock('hset',     sub { 1 });
    $redis->mock('del',      sub { 1 });
    $redis->mock('sismember',sub { 0 });
    $redis->mock('quit',     sub { 1 });

    my $config = { loose_max_score => 40, pcount_tolerance_pct => 20, candidate_pair_cap => 100, algo_version => 1 };
    my $result = LANraragi::Model::Dedup::find_duplicate_pairs_in_memory(\%page_data, $redis, $config);
    is($result->{truncated}, 1, "truncated flag set when candidate count exceeds cap");
    cmp_ok($result->{candidates}, "<=", 100, "candidate count clamped to cap");
}

done_testing();
