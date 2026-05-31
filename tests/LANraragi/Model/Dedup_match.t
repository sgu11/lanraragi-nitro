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
    $redis->mock('zscore',   sub { undef });
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
    $redis->mock('zscore',   sub { undef });
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
    $redis->mock('zscore',   sub { undef });
    $redis->mock('quit',     sub { 1 });

    my $config = { loose_max_score => 40, pcount_tolerance_pct => 20, candidate_pair_cap => 100, algo_version => 1 };
    my $result = LANraragi::Model::Dedup::find_duplicate_pairs_in_memory(\%page_data, $redis, $config);
    is($result->{truncated}, 1, "truncated flag set when candidate count exceeds cap");
    cmp_ok($result->{candidates}, "<=", 100, "candidate count clamped to cap");
}

note("match: target_pairs caps the run + cursor tracks resume position");
{
    my %page_data;
    # 6 archives with identical hashes and same pagecount -> all pairs score 0,
    # all within tolerance, all stored unless target_pairs caps it.
    $page_data{"id_$_"} = { hashes => ["0000000000000000"], n => 50 } for 1 .. 6;

    my @stored;
    my $redis = Test::MockObject->new();
    $redis->mock('zadd',     sub { shift; push @stored, $_[1]; 1 });
    $redis->mock('hset',     sub { 1 });
    $redis->mock('del',      sub { 1 });
    $redis->mock('sismember',sub { 0 });
    $redis->mock('zscore',   sub { undef });
    $redis->mock('quit',     sub { 1 });

    my $config = {
        loose_max_score      => 40,
        pcount_tolerance_pct => 20,
        candidate_pair_cap   => 1_000_000,
        algo_version         => 1,
        target_pairs         => 3,
    };
    my $r = LANraragi::Model::Dedup::find_duplicate_pairs_in_memory(\%page_data, $redis, $config);
    is($r->{stored}, 3, "stops at target_pairs=3");
    is($r->{sweep_done}, 0, "sweep not done when capped by target_pairs");
    cmp_ok($r->{cur_i}, ">=", 0, "cursor i set");
    cmp_ok($r->{cur_j}, ">",  $r->{cur_i}, "cursor j past current i");
}

note("match: resume from cursor skips already-emitted pairs");
{
    my %page_data;
    $page_data{"id_$_"} = { hashes => ["0000000000000000"], n => 50 } for 1 .. 4;

    my @stored;
    my $redis = Test::MockObject->new();
    $redis->mock('zadd',     sub { shift; push @stored, $_[1]; 1 });
    $redis->mock('hset',     sub { 1 });
    $redis->mock('del',      sub { 1 });
    $redis->mock('sismember',sub { 0 });
    $redis->mock('zscore',   sub { undef });
    $redis->mock('quit',     sub { 1 });

    # Run 1: take 2 pairs.
    my $cfg = {
        loose_max_score => 40, pcount_tolerance_pct => 20,
        candidate_pair_cap => 1_000_000, algo_version => 1,
        target_pairs => 2,
    };
    my $r1 = LANraragi::Model::Dedup::find_duplicate_pairs_in_memory(\%page_data, $redis, $cfg);
    is($r1->{stored}, 2, "first run stores 2");

    # Run 2: resume from cursor.
    @stored = ();
    $cfg->{cur_i} = $r1->{cur_i};
    $cfg->{cur_j} = $r1->{cur_j};
    delete $cfg->{target_pairs};
    my $r2 = LANraragi::Model::Dedup::find_duplicate_pairs_in_memory(\%page_data, $redis, $cfg);
    # 4 ids -> C(4,2) = 6 total pairs. First run took 2. Second run takes the rest.
    is($r2->{stored}, 4, "second run stores remaining 4 pairs");
    is($r2->{sweep_done}, 1, "sweep done after second run");
}

note("match: zscore guard skips pairs already in the deck");
{
    my %page_data = (
        "id_a" => { hashes => ["0000000000000000"], n => 50 },
        "id_b" => { hashes => ["0000000000000000"], n => 50 },
    );
    my %already_in_deck = ("id_a|id_b" => 1);
    my @stored;
    my $redis = Test::MockObject->new();
    $redis->mock('zadd',     sub { shift; push @stored, $_[1]; 1 });
    $redis->mock('hset',     sub { 1 });
    $redis->mock('del',      sub { 1 });
    $redis->mock('sismember',sub { 0 });
    $redis->mock('zscore',   sub { my (undef, undef, $m) = @_; exists $already_in_deck{$m} ? 0 : undef });
    $redis->mock('quit',     sub { 1 });

    my $cfg = { loose_max_score => 40, pcount_tolerance_pct => 20, candidate_pair_cap => 1_000_000, algo_version => 1 };
    my $r = LANraragi::Model::Dedup::find_duplicate_pairs_in_memory(\%page_data, $redis, $cfg);
    is($r->{stored}, 0, "no zadd when pair already in deck");
}

# Stateful mock Redis backing the relation deck (zset + meta hash), so the
# matcher's upsert + GC paths can be exercised.
sub stateful_redis {
    my (%seed) = @_;
    my %zset = %{ $seed{zset} // {} };
    my %meta = %{ $seed{meta} // {} };
    my $r = Test::MockObject->new();
    $r->mock('zadd',      sub { shift; my ($s, $m) = @_; $zset{$m} = $s; 1 });
    $r->mock('hset',      sub { shift; my ($k, $m, $v) = @_; $meta{$m} = $v; 1 });
    $r->mock('hget',      sub { shift; my ($k, $m) = @_; $meta{$m} });
    $r->mock('hdel',      sub { shift; my ($k, @ms) = @_; delete $meta{$_} for @ms; 1 });
    $r->mock('zscore',    sub { shift; my ($k, $m) = @_; exists $zset{$m} ? $zset{$m} : undef });
    $r->mock('zrange',    sub { shift; sort keys %zset });
    $r->mock('zrem',      sub { shift; my ($k, @ms) = @_; delete $zset{$_} for @ms; 1 });
    $r->mock('sismember', sub { 0 });
    return ($r, \%zset, \%meta);
}

note("relation matcher: store metadata, then upsert + preserve status on re-run");
{
    my %signals = (
        small => {
            id => "small", title => "Same Work ch 01", tags => "artist:x, language:korean",
            pagecount => 20, arcsize => 500_000_000,
            lead_hashes => ["0000000000000000"],
        },
        large => {
            id => "large", title => "Same Work complete", tags => "artist:x, language:japanese",
            pagecount => 100, arcsize => 1_000_000_000,
            lead_hashes => ["0000000000000001"],
        },
        other => {
            id => "other", title => "Different Work", tags => "artist:y",
            pagecount => 100, arcsize => 1_000_000_000,
            lead_hashes => ["ffffffffffffffff"],
        },
    );

    my ($redis, $zset, $meta) = stateful_redis();

    my $r1 = LANraragi::Model::Dedup::find_relation_duplicates_in_memory(\%signals, $redis, {});
    is($r1->{stored},  1, "first run stores one relation pair");
    is($r1->{updated}, 0, "nothing to update on first run");
    is($r1->{removed}, 0, "nothing to GC on first run");
    ok(exists $zset->{"large|small"}, "stores canonical sorted pair id");
    like($meta->{"large|small"}, qr/"relation":"subset"/,        "meta stores subset relation");
    like($meta->{"large|small"}, qr/"suggested_delete":"small"/, "meta stores suggested delete");
    like($meta->{"large|small"}, qr/"pass":"relation"/,          "meta stores relation pass");
    like($meta->{"large|small"}, qr/"status":"new"/,             "fresh pair gets status new");

    # Re-run is non-destructive: the pair is refreshed in place, not wiped.
    my $r2 = LANraragi::Model::Dedup::find_relation_duplicates_in_memory(\%signals, $redis, {});
    is($r2->{stored},  0, "re-run adds no new pair");
    is($r2->{updated}, 1, "re-run refreshes the existing pair in place");
    is($r2->{removed}, 0, "re-run GCs nothing while the pair still classifies");
    ok(exists $zset->{"large|small"}, "pair survives the re-run (no wholesale wipe)");

    # A status set by a later phase must survive subsequent matcher runs.
    $meta->{"large|small"} =~ s/"status":"new"/"status":"reviewed"/;
    LANraragi::Model::Dedup::find_relation_duplicates_in_memory(\%signals, $redis, {});
    like($meta->{"large|small"}, qr/"status":"reviewed"/, "re-run preserves existing review status");
}

note("relation matcher: GC drops stale relation pairs, keeps other passes");
{
    my %signals = (
        keepA => { id => "keepA", title => "Work ch 1", tags => "artist:x", pagecount => 20,  arcsize => 5e8, lead_hashes => ["0000000000000000"] },
        keepB => { id => "keepB", title => "Work full",  tags => "artist:x", pagecount => 100, arcsize => 1e9, lead_hashes => ["0000000000000001"] },
    );
    # Seed: a stale relation pair (archives gone) and a cover-pass pair that
    # must be left untouched.
    my ($redis, $zset, $meta) = stateful_redis(
        zset => { "ghost|gone" => 0.1, "cov1|cov2" => 5 },
        meta => {
            "ghost|gone" => '{"pass":"relation","relation":"duplicate","status":"new"}',
            "cov1|cov2"  => '{"pass":"cover","cover_hamming":5}',
        },
    );

    my $r = LANraragi::Model::Dedup::find_relation_duplicates_in_memory(\%signals, $redis, {});
    ok(!exists $zset->{"ghost|gone"}, "stale relation pair GC'd from deck");
    ok(!exists $meta->{"ghost|gone"}, "stale relation pair meta removed");
    ok(exists $zset->{"cov1|cov2"},   "cover-pass pair left untouched by relation GC");
    is($r->{removed}, 1, "removed count reflects only the stale relation pair");
}

done_testing();
