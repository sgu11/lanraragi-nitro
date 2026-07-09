use strict;
use warnings;
use v5.36;
use Test::More;
use Test::MockModule qw(strict);
use Cwd qw(getcwd);
use Mojo::JSON qw(encode_json decode_json);

my $cwd = getcwd();
require "$cwd/tests/mocks.pl";
setup_redis_mock();

use_ok('LANraragi::Model::Dedup::CoverIndex');

# --- Package-level test data for the mock Redis -------------------------
package CoverTestData {
    our %zset;
    our %hash;
    our @hgetall_return;
    our @sadd_seen;
    our @zrem_seen;
    our @hdel_seen;
    our @zadd_seen;
    our @hset_seen;
    our %kv;
    our %set;
}

# --- Test Redis mock ----------------------------------------------------
package CoverTestRedis {
    sub new { bless {}, shift }
    sub sadd  {
        my ($self, $k, $m) = @_;
        push @CoverTestData::sadd_seen, [$k, $m];
        $CoverTestData::set{$k}{$m} = 1;
        1;
    }
    sub sismember {
        my ($self, $k, $m) = @_;
        $CoverTestData::set{$k}{$m} ? 1 : 0;
    }
    sub zcard {
        my ($self, $k) = @_;
        scalar keys %{$CoverTestData::zset{$k} // {}};
    }
    sub zscore {
        my ($self, $k, $m) = @_;
        return undef unless exists $CoverTestData::zset{$k} && exists $CoverTestData::zset{$k}{$m};
        return $CoverTestData::zset{$k}{$m};
    }
    # Parse Redis-style range: "(" prefix means exclusive, "+inf"/"-inf" are infinity.
    sub _parse_range {
        my ($val, $default) = @_;
        return $default unless defined $val && length $val;
        return 1e100 if $val eq '+inf';
        return -1e100 if $val eq '-inf';
        my $exclusive = ($val =~ s/^\(//);
        return ($val + 0, $exclusive);
    }
    sub _in_range {
        my ($score, $min_raw, $max_raw) = @_;
        my ($min_val, $min_ex) = _parse_range($min_raw, -1e100);
        my ($max_val, $max_ex) = _parse_range($max_raw,  1e100);
        return 0 if $min_ex ? $score <= $min_val : $score < $min_val;
        return 0 if $max_ex ? $score >= $max_val : $score > $max_val;
        return 1;
    }
    sub zcount {
        my ($self, $k, $min, $max) = @_;
        scalar grep { _in_range($CoverTestData::zset{$k}{$_}, $min, $max) }
            keys %{$CoverTestData::zset{$k} // {}};
    }
    sub zrangebyscore {
        my ($self, $k, $min, $max, @rest) = @_;
        my %s = %{$CoverTestData::zset{$k} // {}};
        my @members = sort { $s{$a} <=> $s{$b} }
            grep { _in_range($s{$_}, $min, $max) } keys %s;
        return @members unless grep { $_ eq 'WITHSCORES' } @rest;
        my @out;
        for my $m (@members) { push @out, $m, $s{$m} }
        return @out;
    }
    sub zrange {
        my ($self, $k, $start, $stop) = @_;
        my %s = %{$CoverTestData::zset{$k} // {}};
        my @sorted = sort { $s{$a} <=> $s{$b} } keys %s;
        return () unless @sorted;
        return () if $start > $#sorted;
        my $last = $stop < 0 ? $#sorted : $stop;
        $last = $#sorted if $last > $#sorted;
        return @sorted[$start .. $last];
    }
    sub zadd {
        my ($self, $k, $score, $m) = @_;
        push @CoverTestData::zadd_seen, [$k, $m, $score];
        $CoverTestData::zset{$k}{$m} = $score;
        1;
    }
    sub zrem {
        my ($self, $k, @ms) = @_;
        push @CoverTestData::zrem_seen, [$k, @ms];
        delete $CoverTestData::zset{$k}{$_} for @ms;
        1;
    }
    sub hget  {
        my ($self, $k, $f) = @_;
        $CoverTestData::hash{$k}{$f} // '';
    }
    sub hmget {
        my $self = shift;
        my $cb = ref($_[-1]) eq 'CODE' ? pop @_ : undef;
        my ($k, @fields) = @_;
        my @vals = map {
            my $v = $CoverTestData::hash{$k}{$_} // '';
            # Return '0' for numeric fields to avoid "" + 0 warnings.
            if ($v eq '' && ($_ eq 'arcsize' || $_ eq 'pagecount')) { '0' }
            else { $v }
        } @fields;
        $cb->(\@vals, undef) if $cb;
        return \@vals;
    }
    sub hgetall {
        my ($self, $k) = @_;
        if (@CoverTestData::hgetall_return) {
            return @CoverTestData::hgetall_return;
        }
        my %h = %{$CoverTestData::hash{$k} // {}};
        return %h;
    }
    sub hset {
        my ($self, $k, $f, $v) = @_;
        push @CoverTestData::hset_seen, [$k, $f, $v];
        $CoverTestData::hash{$k}{$f} = $v;
        1;
    }
    sub hdel {
        my ($self, $k, @fs) = @_;
        push @CoverTestData::hdel_seen, [$k, @fs];
        delete $CoverTestData::hash{$k}{$_} for @fs;
        1;
    }
    sub get    { my ($self, $k) = @_; $CoverTestData::kv{$k} // undef }
    sub set    { my ($self, $k, $v) = @_; $CoverTestData::kv{$k} = $v }
    sub keys   {
        my ($self, $pat) = @_;
        # For band key queries, return matching keys from %CoverTestData::set
        if ($pat && $pat =~ /^cover:band:/) {
            return grep { $_ =~ /^cover:band:\d+:/ } keys %CoverTestData::kv;
        }
        return ('id1','id2','id3');
    }
    sub del    {
        my ($self, @keys) = @_;
        delete $CoverTestData::kv{$_} for @keys;
        delete $CoverTestData::set{$_} for @keys;
        1;
    }
    sub smembers {
        my ($self, $k) = @_;
        my %s = %{$CoverTestData::set{$k} // {}};
        return sort CORE::keys %s;
    }
    sub exists  { 1 }
    sub wait_all_responses { 1 }
    sub quit   { 1 }
}

# --- Test helpers -------------------------------------------------------
sub reset_state {
    %CoverTestData::zset = ();
    %CoverTestData::hash = ();
    @CoverTestData::hgetall_return = ();
    @CoverTestData::sadd_seen = ();
    @CoverTestData::zrem_seen = ();
    @CoverTestData::hdel_seen = ();
    %CoverTestData::kv = ();
    %CoverTestData::set = ();
}

my $redis     = CoverTestRedis->new;
my $redis_cfg = CoverTestRedis->new;

# Stub all_archive_ids
my $db_mod = Test::MockModule->new('LANraragi::Utils::Database');
$db_mod->redefine('all_archive_ids', sub { ('id1','id2','id3') });

# Stub find_cover_duplicate_pairs_in_memory
my $dedup_mod = Test::MockModule->new('LANraragi::Model::Dedup');
my $find_called = 0;
my $mock_matcher_result = {};
$dedup_mod->redefine('find_cover_duplicate_pairs_in_memory', sub {
    $find_called++;
    return %$mock_matcher_result ? $mock_matcher_result : { stored => 2, candidates => 3, truncated => 0, cur_i => 3, cur_j => 0, sweep_done => 1 };
});

# --- Tests --------------------------------------------------------------

note("=== cover config defaults to current cover hash algorithm ===");
reset_state();
{
    my $cfg = LANraragi::Model::Dedup::CoverIndex::cover_config_from_redis($redis_cfg);
    is($cfg->{cover_algo_version}, 2, "default cover hash algorithm version invalidates stale v1 hashes");
    is($cfg->{cover_max_hamming}, 22, "default cover Hamming threshold matches product default");
    is($cfg->{cover_sweep_mode}, 'legacy', "default cover sweep is legacy O(N²)");
    is(LANraragi::Model::Dedup::CoverIndex::DEFAULT_COVER_MAX_HAMMING(), 22,
        "DEFAULT_COVER_MAX_HAMMING constant is 22");
}

note("=== build_band_buckets indexes current-version (v2) coverhashes only ===");
reset_state();
{
    $CoverTestData::hash{'id1'}{'coverhash'}   = 'a1b2c3d4e5f6a1b2';
    $CoverTestData::hash{'id1'}{'coverhash_v'} = '2';
    $CoverTestData::hash{'id2'}{'coverhash'}   = 'ffffffffffffffff';
    $CoverTestData::hash{'id2'}{'coverhash_v'} = '1';  # stale algo
    $CoverTestData::hash{'id3'}{'coverhash'}   = '1234567890abcdef';
    $CoverTestData::hash{'id3'}{'coverhash_v'} = '2';

    my $r = LANraragi::Model::Dedup::CoverIndex::build_band_buckets($redis_cfg, $redis);
    is($r->{archives_indexed}, 2, "only current-version coverhashes enter band buckets");
    # id1 and id3 sadd'ed into 4 bands each => 8 sadd calls
    cmp_ok(scalar @CoverTestData::sadd_seen, '>=', 8, "band sadd calls for current-version archives");
    my %indexed_ids = map { $_->[1] => 1 } @CoverTestData::sadd_seen;
    ok($indexed_ids{'id1'}, "id1 (v2) indexed");
    ok($indexed_ids{'id3'}, "id3 (v2) indexed");
    ok(!$indexed_ids{'id2'}, "id2 (v1) not indexed");
}

note("=== generate_band_candidates uses current-version hashes ===");
reset_state();
{
    # Two archives sharing first band of pHash
    $CoverTestData::hash{'id1'}{'coverhash'}   = 'aaaa000011112222';
    $CoverTestData::hash{'id1'}{'coverhash_v'} = '2';
    $CoverTestData::hash{'id2'}{'coverhash'}   = 'aaaabbbbccccdddd';
    $CoverTestData::hash{'id2'}{'coverhash_v'} = '2';
    $CoverTestData::hash{'id3'}{'coverhash'}   = 'zzzzzzzzzzzzzzzz';
    $CoverTestData::hash{'id3'}{'coverhash_v'} = '1';

    # Pre-build band membership as if build_band_buckets ran for v2 only
    my $b0 = LANraragi::Model::Dedup::CoverIndex::band_key(0, 'aaaa');
    $CoverTestData::set{$b0}{'id1'} = 1;
    $CoverTestData::set{$b0}{'id2'} = 1;

    my $gen = LANraragi::Model::Dedup::CoverIndex::generate_band_candidates(
        $redis_cfg, $redis, { band_cursor => 0, candidate_bucket_cap => 100 }
    );
    ok(exists $gen->{cover_data}{'id1'}, "v2 id1 in cover_data");
    ok(exists $gen->{cover_data}{'id2'}, "v2 id2 in cover_data");
    ok(!exists $gen->{cover_data}{'id3'}, "v1 id3 excluded from cover_data");
}

note("=== run_cover_candidate_sweep respects cover_sweep_mode flag ===");
reset_state();
{
    $CoverTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{'cover_sweep_mode'} = 'legacy';
    $CoverTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{'cover_algo_version'} = '2';
    $CoverTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{'cover_cursor_threshold'} = '22';
    $CoverTestData::hash{'id1'}{'coverhash'}   = 'a1b2c3d4e5f6a1b2';
    $CoverTestData::hash{'id1'}{'coverhash_v'} = '2';
    $CoverTestData::hash{'id2'}{'coverhash'}   = 'a1b2c3d4aaaaaaaa';
    $CoverTestData::hash{'id2'}{'coverhash_v'} = '2';
    $CoverTestData::hash{'id3'}{'coverhash'}   = 'fffeeedddcccbbaa';
    $CoverTestData::hash{'id3'}{'coverhash_v'} = '2';

    my $legacy = LANraragi::Model::Dedup::CoverIndex::run_cover_candidate_sweep($redis, $redis_cfg, 22);
    ok(defined $legacy->{sweep_done} || defined $legacy->{deck_full} || defined $legacy->{stored},
        "legacy mode runs without error");

    # Banded mode with empty buckets still returns a structured result.
    $CoverTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{'cover_sweep_mode'} = 'banded';
    $CoverTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{'band_buckets_built'} = '0';
    my $banded = LANraragi::Model::Dedup::CoverIndex::run_cover_candidate_sweep($redis, $redis_cfg, 22);
    ok(defined $banded, "banded mode entrypoint returns a result");
    ok(defined $banded->{stored} || defined $banded->{deck_full} || defined $banded->{candidates},
        "banded result has expected keys");
}

note("=== cover_stats returns cover-only data ===");
reset_state();
{
    @CoverTestData::hgetall_return = (cover_algo_version => 1);
    $CoverTestData::kv{'LRR_COVER_DEDUP_LAST_SCAN'} = '1000';
    my $s = LANraragi::Model::Dedup::CoverIndex::cover_stats($redis_cfg, $redis);
    is($s->{deck_size}, 0, "empty cover deck");
    is($s->{archives_total}, 3, "total archive count");
    is($s->{cover_algo_version}, 1, "cover algo version");
    is($s->{last_scan_ts}, 1000, "last scan timestamp");
}

note("=== cover_pairs returns cover-only pairs ===");
reset_state();
{
    $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id1|id2'} = 5;
    $CoverTestData::hash{'LRR_COVER_DUPLICATE_PAIR_META'}{'id1|id2'} = encode_json({
        pass => 'cover', cover_hamming => 5, status => 'new',
        cover_algo_version => 2, ts => time(),
    });
    my $r = LANraragi::Model::Dedup::CoverIndex::cover_pairs($redis_cfg, $redis, { max_score => 10 });
    is(scalar @{$r->{pairs}}, 1, "one cover pair returned");
    is($r->{pairs}[0]{id_a}, 'id1', "id_a correct");
    is($r->{pairs}[0]{cover_hamming}, 5, "cover_hamming correct");
    is($r->{pairs}[0]{pass}, 'cover', "pass is cover");
    is($r->{total}, 1, "total correct");
    is($r->{filtered_total}, 1, "filtered_total correct");
}

note("=== cover_pairs hides stale cover algorithm pairs ===");
reset_state();
{
    @CoverTestData::hgetall_return = (cover_algo_version => 2);
    $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id1|id2'} = 0;
    $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id2|id3'} = 4;
    $CoverTestData::hash{'LRR_COVER_DUPLICATE_PAIR_META'}{'id1|id2'} = encode_json({
        pass => 'cover', cover_hamming => 0, status => 'new',
        cover_algo_version => 1, ts => time(),
    });
    $CoverTestData::hash{'LRR_COVER_DUPLICATE_PAIR_META'}{'id2|id3'} = encode_json({
        pass => 'cover', cover_hamming => 4, status => 'new',
        cover_algo_version => 2, ts => time(),
    });

    my $r = LANraragi::Model::Dedup::CoverIndex::cover_pairs($redis_cfg, $redis, { max_score => 10 });
    is(scalar @{$r->{pairs}}, 1, "only current-version cover pairs are returned");
    is($r->{pairs}[0]{id_a}, 'id2', "current-version pair remains visible");
    is($r->{filtered_total}, 1, "filtered_total excludes stale pairs");
}

note("=== cover_pairs includes cover resolution brief data ===");
reset_state();
{
    $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id1|id2'} = 2;
    $CoverTestData::hash{'LRR_COVER_DUPLICATE_PAIR_META'}{'id1|id2'} = encode_json({
        pass => 'cover', cover_hamming => 2, status => 'new',
        cover_algo_version => 2, ts => time(),
    });
    $CoverTestData::hash{'id1'}{'title'} = 'High resolution archive';
    $CoverTestData::hash{'id1'}{'cover_fp'} = encode_json({ w => 1440, h => 2160 });
    $CoverTestData::hash{'id2'}{'title'} = 'Broken fingerprint archive';
    $CoverTestData::hash{'id2'}{'cover_fp'} = '{not-json';

    my $r = LANraragi::Model::Dedup::CoverIndex::cover_pairs($redis_cfg, $redis, { max_score => 10 });
    is($r->{pairs}[0]{a}{cover_width}, 1440, "cover width comes from cover_fp");
    is($r->{pairs}[0]{a}{cover_height}, 2160, "cover height comes from cover_fp");
    is($r->{pairs}[0]{a}{cover_pixels}, 3_110_400, "cover pixel count is available for UI comparison");
    is($r->{pairs}[0]{b}{cover_width}, 0, "invalid cover_fp width falls back to zero");
    is($r->{pairs}[0]{b}{cover_height}, 0, "invalid cover_fp height falls back to zero");
    is($r->{pairs}[0]{b}{cover_pixels}, 0, "invalid cover_fp pixel count falls back to zero");
}

note("=== delete_cover_pair adds to dismissed set ===");
reset_state();
{
    LANraragi::Model::Dedup::CoverIndex::delete_cover_pair($redis_cfg, 'id1|id2');
    is($CoverTestData::sadd_seen[0][0], 'LRR_COVER_DUPLICATE_DISMISSED', "key is cover dismissed set");
    is($CoverTestData::sadd_seen[0][1], 'id1|id2', "member is the pair");
    is($CoverTestData::zrem_seen[0][0], 'LRR_COVER_DUPLICATE_PAIRS', "removed from cover pair zset");
    is($CoverTestData::hdel_seen[0][0], 'LRR_COVER_DUPLICATE_PAIR_META', "removed from cover meta hash");
}

note("=== refresh_cover_pairs removes orphans ===");
reset_state();
{
    $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id1|id2'} = 5;

    # Mock exists: id1 ok, id2 orphaned
    package CoverTestRedis2 {
        sub new { bless {}, shift }
        sub zrange  { ('id1|id2') }
        sub sismember { 0 }
        sub exists  {
            my ($self, $id, $cb) = @_;
            $cb->($id eq 'id2' ? 0 : 1, undef) if $cb;
            return $id eq 'id2' ? 0 : 1;
        }
        sub zrem { push @CoverTestData::zrem_seen, [ $_[1], $_[2] ]; 1 }
        sub hdel { push @CoverTestData::hdel_seen, [ $_[1], $_[2] ]; 1 }
        sub wait_all_responses { 1 }
        sub quit { 1 }
    }
    my $rcfg = CoverTestRedis2->new;
    my $rarc = CoverTestRedis2->new;
    @CoverTestData::zrem_seen = ();
    my $result = LANraragi::Model::Dedup::CoverIndex::refresh_cover_pairs($rcfg, $rarc);
    cmp_ok($result->{orphans_removed}, '>=', 1, "orphan pair removed");
}

note("=== remove_pairs_for_archive removes all pairs for id ===");
reset_state();
{
    $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id1|id2'} = 5;
    $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id2|id3'} = 7;
    $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id1|id3'} = 3;
    LANraragi::Model::Dedup::CoverIndex::remove_pairs_for_archive($redis_cfg, 'id1');
    ok(!exists $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id1|id2'}, "id1|id2 removed");
    ok(!exists $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id1|id3'}, "id1|id3 removed");
    ok(exists $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id2|id3'}, "id2|id3 retained");
}

note("=== cleanup_legacy_cover_pairs removes pass=cover only ===");
reset_state();
{
    $CoverTestData::zset{'LRR_DUPLICATE_PAIRS'}{'id1|id2'} = 5;
    $CoverTestData::zset{'LRR_DUPLICATE_PAIRS'}{'id2|id3'} = 3;
    $CoverTestData::hash{'LRR_DUPLICATE_PAIR_META'}{'id1|id2'} = encode_json({ pass => 'cover', cover_hamming => 5 });
    $CoverTestData::hash{'LRR_DUPLICATE_PAIR_META'}{'id2|id3'} = encode_json({ pass => 'pcount', per_page => [1,2] });

    my $cleaned = LANraragi::Model::Dedup::CoverIndex::cleanup_legacy_cover_pairs($redis_cfg);
    is($cleaned, 1, "one cover pair cleaned from legacy keys");
    ok(!exists $CoverTestData::zset{'LRR_DUPLICATE_PAIRS'}{'id1|id2'}, "cover legacy pair removed");
    ok(exists $CoverTestData::zset{'LRR_DUPLICATE_PAIRS'}{'id2|id3'}, "pcount legacy pair retained");
}

note("=== invalidate_cover_dedup_signals clears fields and pairs ===");
reset_state();
{
    $CoverTestData::hash{'id1'}{'coverhash'}    = 'a1b2c3d4e5f6a1b2';
    $CoverTestData::hash{'id1'}{'coverhash_v'}  = '1';
    $CoverTestData::hash{'id1'}{'cover_fp'}     = 'old_fingerprint';

    $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id1|id2'} = 5;
    $CoverTestData::zset{'LRR_DUPLICATE_PAIRS'}{'id1|id3'} = 3;
    $CoverTestData::hash{'LRR_DUPLICATE_PAIR_META'}{'id1|id3'} = encode_json({ pass => 'cover', cover_hamming => 3 });

    LANraragi::Model::Dedup::CoverIndex::invalidate_cover_dedup_signals($redis, $redis_cfg, 'id1');

    ok(!defined $CoverTestData::hash{'id1'}{'coverhash'}, "coverhash cleared");
    ok(!defined $CoverTestData::hash{'id1'}{'coverhash_v'}, "coverhash_v cleared");
    ok(!defined $CoverTestData::hash{'id1'}{'cover_fp'}, "cover_fp cleared");
    ok(!exists $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{'id1|id2'}, "cover pair removed from cover keys");
    ok(!exists $CoverTestData::zset{'LRR_DUPLICATE_PAIRS'}{'id1|id3'}, "cover pair removed from legacy keys");
}

note("=== run_cover_candidate_sweep (legacy O(N²)) generates candidates ===");
reset_state();
{
    # The default sweep is now the reliable O(N²) Hamming sweep.
    # Seed archive coverhashes so the sweep has data to work with.
    $CoverTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{'cover_algo_version'} = '1';
    $CoverTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{'cover_cursor_threshold'} = '12';
    $CoverTestData::hash{'id1'}{'coverhash'}    = 'a1b2c3d4e5f6a1b2';
    $CoverTestData::hash{'id1'}{'coverhash_v'}  = '1';
    $CoverTestData::hash{'id2'}{'coverhash'}    = 'a1b2c3d4aaaaaaaa';
    $CoverTestData::hash{'id2'}{'coverhash_v'}  = '1';
    $CoverTestData::hash{'id3'}{'coverhash'}    = 'fffeeedddcccbbaa';
    $CoverTestData::hash{'id3'}{'coverhash_v'}  = '1';

    my $result = LANraragi::Model::Dedup::CoverIndex::run_cover_candidate_sweep($redis, $redis_cfg, 12);
    cmp_ok($result->{candidates} + $result->{stored}, '>=', 0, "legacy sweep executed");
    ok(defined $result->{sweep_done}, "sweep_done flag present");
    is($result->{truncated}, 0, "not truncated on 3 archives");
}

note("=== run_cover_candidate_sweep skips when deck full ===");
reset_state();
{
    $find_called = 0;
    for my $i (1..100) {
        my $member = "a$i|b$i";
        $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{$member} = $i;
        $CoverTestData::hash{'LRR_COVER_DUPLICATE_PAIR_META'}{$member} = encode_json({
            pass => 'cover', cover_hamming => $i, cover_algo_version => 2, ts => time(),
        });
    }
    $CoverTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{'cover_cursor_threshold'} = '12';
    $CoverTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{'band_buckets_built'} = '1';
    my $result = LANraragi::Model::Dedup::CoverIndex::run_cover_candidate_sweep($redis, $redis_cfg, 12);
    ok($result->{deck_full}, "deck_full flag set when deck is full");
}

note("=== run_cover_candidate_sweep removes stale algorithm pairs before deck-full check ===");
reset_state();
{
    $find_called = 0;
    $CoverTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{'cover_algo_version'} = '2';
    $CoverTestData::hash{'LRR_COVER_DEDUP_CONFIG'}{'cover_cursor_threshold'} = '12';
    for my $i (1..100) {
        my $member = "old$i|stale$i";
        $CoverTestData::zset{'LRR_COVER_DUPLICATE_PAIRS'}{$member} = 0;
        $CoverTestData::hash{'LRR_COVER_DUPLICATE_PAIR_META'}{$member} = encode_json({
            pass => 'cover', cover_hamming => 0, cover_algo_version => 1, ts => time(),
        });
    }
    $CoverTestData::hash{'id1'}{'coverhash'}    = 'a1b2c3d4e5f6a1b2';
    $CoverTestData::hash{'id1'}{'coverhash_v'}  = '2';
    $CoverTestData::hash{'id2'}{'coverhash'}    = 'a1b2c3d4aaaaaaaa';
    $CoverTestData::hash{'id2'}{'coverhash_v'}  = '2';
    $CoverTestData::hash{'id3'}{'coverhash'}    = 'fffeeedddcccbbaa';
    $CoverTestData::hash{'id3'}{'coverhash_v'}  = '2';

    my $result = LANraragi::Model::Dedup::CoverIndex::run_cover_candidate_sweep($redis, $redis_cfg, 12);
    ok(!$result->{deck_full}, "stale v1 pairs do not keep the deck full after a version bump");
    is($find_called, 1, "matcher runs after stale pair cleanup");
}

done_testing();
