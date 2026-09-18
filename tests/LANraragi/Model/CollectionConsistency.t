use v5.36;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojolicious;
use LANraragi::Model::Stats;
use LANraragi::Model::Search;
use LANraragi::Controller::Api::Category;

require './tests/redis_test_server.pl';
my ($db, $guard) = start_test_redis();
my $search = Redis->new(sock => "$guard->{dir}/redis.sock");
$search->select(3);
my $config = Redis->new(sock => "$guard->{dir}/redis.sock");
$config->select(2);

{ package CollectionTestLogger; sub debug {} sub trace {} sub info {} sub warn {} sub error {} }
no warnings 'redefine';
local *Redis::quit = sub {};
local *LANraragi::Model::Config::get_redis = sub { $db };
local *LANraragi::Model::Config::get_redis_search = sub { $search };
local *LANraragi::Model::Config::get_redis_config = sub { $config };
local *LANraragi::Model::Config::get_pagesize = sub { 30 };
local *LANraragi::Model::Metrics::record_search_metrics = sub {};
for my $package (qw(Stats Search Tankoubon Category)) {
    no strict 'refs';
    *{"LANraragi::Model::${package}::get_logger"} = sub { bless {}, 'CollectionTestLogger' };
}
local *LANraragi::Utils::Database::get_logger = sub { bless {}, 'CollectionTestLogger' };

my @ids = map { $_ x 40 } qw(a b c);
my $tank = 'TANK_1000000000';
my $other_tank = 'TANK_1000000001';
my $category = 'SET_1000000000';

sub reset_library {
    $db->flushdb;
    $search->flushdb;
    $config->flushdb;
    for my $i (0 .. $#ids) {
        $db->hmset($ids[$i], title => "Archive $i", tags => '', isnew => 'true', pagecount => 10);
        $db->sadd('LRR_ALL_ARCHIVES', $ids[$i]);
    }
    LANraragi::Model::Tankoubon::create_tankoubon('Collection', $tank);
    LANraragi::Model::Stats::build_stat_hashes();
}

sub search_ids ($filter, $cat = '', $grouped = 0, $untagged = 0) {
    my (undef, undef, @results) = LANraragi::Model::Search::do_search(
        $filter, $cat, -1, 'title', 0, 0, $untagged, $grouped, 0
    );
    return [sort @results];
}

subtest 'category edits invalidate warm searches and accept an empty predicate' => sub {
    reset_library();
    LANraragi::Utils::Database::set_tags($ids[0], 'genre:alpha');
    LANraragi::Utils::Database::set_tags($ids[1], 'genre:beta');
    LANraragi::Model::Category::create_category('Filter', 'genre:alpha', 1, $category);
    is_deeply(search_ids('', $category), [$ids[0]], 'initial category result');
    LANraragi::Model::Category::create_category('Filter', 'genre:beta', 1, $category);
    is_deeply(search_ids('', $category), [$ids[1]], 'edited predicate replaces cached result');

    my $app = Mojolicious->new;
    $app->helper(openapi => sub { $_[0] });
    $app->helper(valid_input => sub { $_[0] });
    $app->hook(before_render => sub ($c, $args) {
        $args->{json} = delete $args->{openapi} if exists $args->{openapi};
    });
    $app->routes->put('/categories/:id')->to(cb => sub ($c) {
        LANraragi::Controller::Api::Category::update_category($c);
    });
    my $t = Test::Mojo->new($app);
    $t->put_ok("/categories/$category" => form => { search => '' })->status_is(200)->json_is('/success', 1);
    my %updated = LANraragi::Model::Category::get_category($category);
    is($updated{search}, '', 'explicit empty predicate converts to a static category');
    is($updated{pinned}, 1, 'omitted pinned setting is preserved');
    is_deeply(search_ids('', $category), [], 'static category cannot reuse dynamic results');
    LANraragi::Model::Category::delete_category($category);
    is_deeply(search_ids('', $category), [sort @ids], 'deleted category cannot reuse cached restriction');
};

subtest 'incremental and rebuilt indexes preserve archive and unified tank tags' => sub {
    reset_library();
    LANraragi::Utils::Database::set_tags($ids[0], 'artist:alice, date_added:100');
    LANraragi::Utils::Database::set_tags($ids[1], 'artist:bob, date_added:200');
    LANraragi::Model::Tankoubon::set_tank_tags($tank, 'series:exclusive, artist:alice');
    LANraragi::Model::Tankoubon::add_to_tankoubon($tank, $ids[0]);
    LANraragi::Model::Tankoubon::add_to_tankoubon($tank, $ids[1]);
    LANraragi::Model::Tankoubon::create_tankoubon('Second collection', $other_tank);
    LANraragi::Model::Tankoubon::add_to_tankoubon($other_tank, $ids[0]);

    is_deeply(search_ids('series:excl', '', 1), [$tank], 'own-tag prefix search works before rebuild');
    ok(!$search->sismember('INDEX_date_added:100', $tank), 'higher member date replaces the previous imputed date');
    my $before_untagged = search_ids('', '', 0, 1);
    LANraragi::Model::Stats::build_stat_hashes();
    is_deeply(search_ids('series:excl', '', 1), [$tank], 'own-tag prefix search survives rebuild');
    is_deeply(search_ids('', '', 0, 1), $before_untagged, 'member archives remain available to untagged searches');
    is($search->zscore('LRR_STATS', 'artist:alice'), 2, 'shared archive counts once plus the tank own tag');
    ok(!$search->sismember('INDEX_date_added:100', $tank), 'rebuild uses the same coalesced date');

    LANraragi::Model::Tankoubon::set_tank_tags($tank, 'series:exclusive');
    ok($search->sismember('INDEX_artist:alice', $tank), 'removing an own tag preserves the inherited tag');
    LANraragi::Model::Tankoubon::set_tank_tags($tank, 'series:exclusive, date_added:50');
    ok(!$search->sismember('INDEX_date_added:200', $tank), 'own date replaces imputed date');
    LANraragi::Model::Tankoubon::set_tank_tags($tank, 'series:exclusive');
    ok($search->sismember('INDEX_date_added:200', $tank), 'clearing own date restores the imputed date');
    ok(!$search->sismember('INDEX_date_added:50', $tank), 'obsolete own date is removed');
    LANraragi::Model::Stats::build_stat_hashes();
    is($search->zscore('LRR_STATS', 'artist:alice'), 1, 'rebuild agrees with changed own-tag statistics');
};

subtest 'member positions and empty grouping do not depend on metadata offsets' => sub {
    reset_library();
    LANraragi::Model::Tankoubon::update_archive_list($tank, { archives => [@ids] });
    my ($position) = LANraragi::Model::Tankoubon::remove_from_tankoubon($tank, $ids[2]);
    is($position, 3, 'third member reports success and its actual position after bulk ordering');
    LANraragi::Model::Tankoubon::add_to_tankoubon($tank, $ids[2]);
    my %data = LANraragi::Model::Tankoubon::get_tankoubon($tank);
    is_deeply($data{archives}, [@ids], 'single addition appends after bulk ordering');
    ($position) = LANraragi::Model::Tankoubon::remove_from_tankoubon($tank, $ids[0]);
    is($position, 1, 'first member removal signals thumbnail regeneration');
    LANraragi::Model::Tankoubon::create_tankoubon('Other', $other_tank);
    LANraragi::Model::Tankoubon::add_to_tankoubon($other_tank, $ids[1]);
    LANraragi::Model::Tankoubon::remove_from_tankoubon($tank, $ids[1]);
    ok(!$search->sismember('LRR_TANKGROUPED', $ids[1]), 'member in another tank stays grouped');
    ($position) = LANraragi::Model::Tankoubon::remove_from_tankoubon($tank, $ids[2]);
    is($position, 1, 'last member has a positive logical position');
    ok(!$search->sismember('LRR_TANKGROUPED', $tank), 'empty tank leaves the search database grouping set');
    ok($search->sismember('LRR_TANKGROUPED', $ids[2]), 'last unshared member becomes visible');
    is($db->zcard($tank), 4, 'all metadata remains on the empty tank');
};

done_testing();
