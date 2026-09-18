use v5.36;
use strict;
use warnings;
use utf8;
use Test::More;
use Mojo::JSON qw(decode_json encode_json);
use LANraragi::Model::Backup;

require './tests/redis_test_server.pl';
my ($db, $guard) = start_test_redis();
my $search = Redis->new(sock => "$guard->{dir}/redis.sock");
$search->select(3);
my $config = Redis->new(sock => "$guard->{dir}/redis.sock");
$config->select(2);
{ package RestoreTestLogger; sub debug {} sub trace {} sub info {} sub warn {} sub error {} }
{ package RestoreTestJob; sub note { my ($self, %notes) = @_; @$self{keys %notes} = values %notes; } }
no warnings 'redefine';
local *Redis::quit = sub {};
local *LANraragi::Model::Config::get_redis = sub { $db };
local *LANraragi::Model::Config::get_redis_search = sub { $search };
local *LANraragi::Model::Config::get_redis_config = sub { $config };
local *LANraragi::Model::Config::get_pagesize = sub { 30 };
local *LANraragi::Utils::Database::clean_database = sub { (0, 0) };
for my $package (qw(Backup Category Tankoubon)) {
    no strict 'refs';
    *{"LANraragi::Model::${package}::get_logger"} = sub { bless {}, 'RestoreTestLogger' };
}

my $id = 'a' x 40;
my $tank = 'TANK_1000000000';
my $category = 'SET_1000000000';
sub seed_archive {
    $db->hmset($id, name => 'sample.cbz', title => 'Original', tags => '', summary => '', file => 'package.json');
    $db->sadd('LRR_ALL_ARCHIVES', $id);
}
seed_archive();
LANraragi::Utils::Database::set_title($id, '복원할 책');
LANraragi::Utils::Database::set_tags($id, 'artist:fixture');
LANraragi::Utils::Database::set_summary($id, 'Archive summary');
$db->hset($id, spreadstart => 'pair2');
$db->hset($id, toc => '{"1":"Chapter"}');
LANraragi::Model::Tankoubon::create_tankoubon('복원할 모음', $tank);
LANraragi::Model::Tankoubon::update_metadata($tank, { metadata => { summary => 'Nonempty summary', tags => 'series:fixture' } });
LANraragi::Model::Tankoubon::add_to_tankoubon($tank, $id);
LANraragi::Model::Category::create_category('복원할 분류', '', 0, $category);
LANraragi::Model::Category::add_to_category($category, $tank);
LANraragi::Model::Category::add_to_category($category, $id);
my $backup = LANraragi::Model::Backup::build_backup_JSON();

subtest 'successful backup round trip restores tank metadata before category relationships' => sub {
    $db->flushdb;
    $search->flushdb;
    $config->flushdb;
    seed_archive();
    my $ok = eval { LANraragi::Model::Backup::restore_from_JSON($backup); 1 };
    ok($ok, 'exported backup restores successfully') or diag $@;
    my %restored = LANraragi::Model::Tankoubon::get_tankoubon($tank);
    is($restored{name}, '복원할 모음', 'Unicode tank name restored');
    is($restored{summary}, 'Nonempty summary', 'nonempty tank summary restored');
    is($restored{tags}, 'series:fixture', 'own tags restored');
    is_deeply($restored{archives}, [$id], 'ordered tank members restored');
    my %cat = LANraragi::Model::Category::get_category($category);
    is($cat{name}, '복원할 분류', 'Unicode category name restored');
    is_deeply($cat{archives}, [$tank, $id], 'category retains newly restored tank and archive');
    is(LANraragi::Utils::Redis::redis_decode($db->hget($id, 'title')), '복원할 책', 'archive metadata restored');
    is($db->hget($id, 'spreadstart'), 'pair2', 'fork spread setting preserved');
    is($db->hget($id, 'toc'), '{"1":"Chapter"}', 'chapter metadata preserved');

    LANraragi::Model::Backup::restore_from_JSON($backup);
    is($db->zcount($tank, -1, -1), 1, 'repeated restore does not duplicate summary metadata');
    is($search->zscore('LRR_STATS', 'series:fixture'), 1, 'repeated restore does not duplicate own-tag statistics');
};

subtest 'partial matching libraries retain available members and report missing references' => sub {
    my $data = decode_json($backup);
    my $missing = 'b' x 40;
    push @{ $data->{tankoubons}[0]{archives} }, $missing;
    push @{ $data->{categories}[0]{archives} }, $missing;
    my $job = bless {}, 'RestoreTestJob';
    LANraragi::Model::Backup::restore_from_JSON(encode_json($data), $job);
    my %restored = LANraragi::Model::Tankoubon::get_tankoubon($tank);
    is_deeply($restored{archives}, [$id], 'existing member survives an unavailable member');
    my %cat = LANraragi::Model::Category::get_category($category);
    is_deeply($cat{archives}, [$tank, $id], 'existing category references survive');
    is($job->{skipped_memberships}, 2, 'restore reports both skipped references');
};

subtest 'model failure cannot be reported as a successful restore' => sub {
    local *LANraragi::Model::Tankoubon::update_metadata = sub { (0, 'injected write rejection') };
    my $ok = eval { LANraragi::Model::Backup::restore_from_JSON($backup); 1 };
    ok(!$ok, 'rejected metadata update stops the restore');
    like($@, qr/injected write rejection/, 'original model error is retained');
};

done_testing();
