use strict;
use warnings;
use Cwd qw(getcwd);
use Test::More;
use LANraragi::Model::Search;
use LANraragi::Model::Stats;

require( getcwd() . '/tests/mocks.pl' );
setup_redis_mock();
LANraragi::Model::Stats::build_stat_hashes();
my $redis = LANraragi::Model::Config->get_redis;
my $id = '28697b96f0ac5858be2614ed10ca47742c9522fd';

sub search_ids {
    my ( $filter, $sort, $order, $hide, $category ) = @_;
    my ( $total, $count, @ids ) = LANraragi::Model::Search::do_search(
        $filter // '', $category // '', -1, $sort // 'title', $order // 0, 0, 0, 0, $hide // 0
    );
    return \@ids;
}

subtest 'cache keys preserve filter and namespace boundaries' => sub {
    is( scalar @{ search_ids('Fate GO MEMO', 'date-added') }, 2, 'first query finds two archives' );
    is_deeply( search_ids('Fate GO MEMO-date', 'added'), [], 'different query cannot reuse its cache entry' );
};

subtest 'inverse cached order agrees with cold order for entirely unkeyed results' => sub {
    my $asc = search_ids('', 'absent_namespace', 0);
    my $warm = search_ids('', 'absent_namespace', 1);
    LANraragi::Utils::Database::invalidate_cache();
    my $cold = search_ids('', 'absent_namespace', 1);
    is_deeply( $warm, $cold, 'warm and cold descending agree' );
    is_deeply( $warm, $asc, 'unkeyed partition keeps its order' );
};

subtest 'progress predicates stay current without a metadata invalidation' => sub {
    my $category = 'SET_1589138380';
    $redis->hset( $category, 'search', 'read:>0' );
    for my $case ( ['read:>0', 0, ''], ['', 1, ''], ['', 0, $category] ) {
        my ( $filter, $hide, $cat ) = @$case;
        $redis->hset( $id, 'progress', 0 );
        my $before = search_ids($filter, 'title', 0, $hide, $cat);
        $redis->hset( $id, 'progress', 1 );
        my $after = search_ids($filter, 'title', 0, $hide, $cat);
        is( scalar(grep { $_ eq $id } @$before), $hide ? 1 : 0, 'initial membership' );
        is( scalar(grep { $_ eq $id } @$after), $hide ? 0 : 1, 'membership reflects progress change' );
    }
    $redis->hset( $id, 'progress', 0 );
};

subtest 'numeric searches pipeline reads and do not match literal tags or titles' => sub {
    $redis->sadd( 'INDEX_pages:>150', $id );
    $redis->zadd( 'LRR_TITLES', 0, "pages:>150\x00$id" );
    LANraragi::Utils::Database::invalidate_cache();
    my ( $reads, $waits, $scans ) = (0, 0, 0);
    # Wrap the installed mock methods through can(), preserving fixture data.
    my $mock = $redis->_lrr_redis_handle;
    my $original_hget = $mock->can('hget');
    my $original_wait = $mock->can('wait_all_responses');
    my $original_scan = $mock->can('zscan');
    {
        no warnings qw(redefine once);
        local *Test::MockObject::hget = sub {
            $reads++ if ref($_[-1]) eq 'CODE';
            return $original_hget->(@_);
        };
        local *Test::MockObject::wait_all_responses = sub { $waits++; return $original_wait->(@_); };
        local *Test::MockObject::zscan = sub { $scans++; return $original_scan->(@_); };
        is_deeply( search_ids('pages:>150'), ['e69e43e1355267f7d32a4f9b7f2fe108d2401ebg'], 'numeric predicate ignores literal metadata matches' );
    }
    is( $reads, 13, 'all archive counts use callbacks' );
    is( $waits, 1, 'one pipeline drain for thirteen archives' );
    is( $scans, 0, 'numeric predicate performs no fuzzy title scans' );
};

subtest 'invalidation during search cannot populate the next generation' => sub {
    my $calls = 0;
    {
        no warnings qw(redefine once);
        local *LANraragi::Model::Search::search_uncached = sub {
            $calls++;
            LANraragi::Utils::Database::invalidate_cache() if $calls == 1;
            return (1, $calls == 1 ? 'old-result' : 'new-result');
        };
        is_deeply( search_ids('generation-race'), ['old-result'], 'in-flight request completes' );
        is_deeply( search_ids('generation-race'), ['new-result'], 'next generation recomputes the result' );
        is_deeply( search_ids('generation-race'), ['new-result'], 'stable metadata results still hit cache' );
        is( $calls, 2, 'only the new generation is reusable' );
    }
};

done_testing();
