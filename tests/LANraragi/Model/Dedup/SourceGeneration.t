use v5.36;
use strict;
use warnings;
use Test::More;
use Test::MockModule qw(strict);
use File::Temp qw(tempfile);
use Mojo::JSON qw(encode_json decode_json);
use LANraragi::Model::Dedup;
use LANraragi::Model::Dedup::CoverIndex;
use LANraragi::Model::Dedup::CoverFingerprint;
require './tests/redis_test_server.pl';
my ($redis, $guard) = start_test_redis();
my $cfg = Redis->new(sock => "$guard->{dir}/redis.sock");
$cfg->select(2);
my $config = Test::MockModule->new('LANraragi::Model::Config');
$config->redefine(get_archivedb => sub { 0 });
$config->redefine(get_configdb => sub { 2 });
my ($fh, $file) = tempfile(UNLINK => 1);
close $fh;
my $a = 'a' x 40;
my $b = 'b' x 40;
my $pair = "$a|$b";
my $pairs = LANraragi::Model::Dedup::CoverIndex::PAIR_KEY();
my $metas = LANraragi::Model::Dedup::CoverIndex::PAIR_META_KEY();
my $model = Test::MockModule->new('LANraragi::Model::Dedup');
$model->redefine(_get_archive_path => sub { $file });
$model->redefine(_get_filelist => sub { 'page.jpg' });
$model->redefine(_extract_page => sub { $file });
$model->redefine(_unlink_temp => sub { 1 });
my $during_hash = sub {};
$model->redefine(_compute_phash => sub { $during_hash->(); return '0' x 16 });
my $fingerprint = Test::MockModule->new('LANraragi::Model::Dedup::CoverFingerprint');
$fingerprint->redefine(_get_filelist => sub { 'page.jpg' });
$fingerprint->redefine(_extract_page => sub { $file });
$fingerprint->redefine(_unlink_temp => sub { 1 });
$fingerprint->redefine(pick_cover_page => sub { (0, 'page.jpg') });
$fingerprint->redefine(_compute_phash_fit => sub { $during_hash->(); return '0' x 16 });
$fingerprint->redefine(_compute_phash_crop => sub { '0' x 16 });
$fingerprint->redefine(_compute_dhash => sub { '0' x 16 });
$fingerprint->redefine(_compute_color_histogram => sub { [] });

for my $case (
    [coverhash => \&LANraragi::Model::Dedup::compute_coverhash_for_archive],
    [pagehashes => \&LANraragi::Model::Dedup::compute_pagehashes_for_archive],
    [lead_hashes => \&LANraragi::Model::Dedup::compute_leadhashes_for_archive],
    [cover_fp => \&LANraragi::Model::Dedup::CoverFingerprint::compute_cover_fingerprint_for_archive],
) {
    my ($field, $compute) = @$case;
    subtest "$field publication follows source generation" => sub {
        $redis->del($a);
        $redis->hset($a, file => $file);
        $during_hash = sub { LANraragi::Model::Dedup::CoverIndex::invalidate_cover_dedup_signals($redis, $cfg, $a) };
        is($compute->($redis, $a, {}), 0, 'replacement during hash rejects old result');
        ok(!defined $redis->hget($a, $field), 'old hash is not republished');
        $during_hash = sub {};
        is($compute->($redis, $a, {}), 1, 'new generation remains eligible for computation');
        ok(defined $redis->hget($a, $field), 'fresh result published');
        LANraragi::Model::Dedup::CoverIndex::invalidate_cover_dedup_signals($redis, $cfg, $a);
        $during_hash = sub { $redis->del($a) };
        is($compute->($redis, $a, {}), 0, 'deletion during hash rejects result');
        ok(!$redis->exists($a), 'completed job cannot resurrect deleted archive');
        is($compute->($redis, $a, {}), -1, 'already deleted archive stops before work');
        ok(!$redis->exists($a), 'missing-archive error cannot recreate hash');
    };
}

$redis->hmset($_, file => $file, coverhash => '0' x 16, coverhash_v => 2, dedup_generation => 'source-old') for ($a, $b);
my %sources = map { $_ => ['0' x 16, 2, 'source-old'] } ($a, $b);
my $meta = {generation => 'pair-old', cover_algo_version => 2, pass => 'cover'};
my $publish = \&LANraragi::Model::Dedup::CoverIndex::_publish_cover_pair;
my $patch = \&LANraragi::Model::Dedup::CoverIndex::patch_pair_meta;
is($publish->($cfg, $pair, 0, $meta, \%sources), 1, 'source-matched pair publishes across archive/config DBs');
ok(defined $cfg->zscore($pairs, $pair), 'config client still reads config DB after script');
ok(!defined $redis->zscore($pairs, $pair), 'pair does not leak into archive DB');
$patch->($cfg, $pair, {status => 'same_cover'}, undef, 'pair-old');
is($publish->($cfg, $pair, 0, {generation => 'overwrite'}, \%sources), 0, 'another sweep cannot overwrite human decision');
LANraragi::Model::Dedup::CoverIndex::invalidate_cover_dedup_signals($redis, $cfg, $a);
$redis->hmset($a, coverhash => '0' x 16, coverhash_v => 2);
is($publish->($cfg, $pair, 0, $meta, \%sources), 0, 'same hash but replaced source cannot republish stale candidate');
$sources{$a}[2] = $redis->hget($a, 'dedup_generation');
is($publish->($cfg, $pair, 0, {%$meta, generation => 'pair-new'}, \%sources), 1, 'fresh snapshot can publish replacement candidate');
ok(!defined $patch->($cfg, $pair, {status => 'not_duplicate'}, undef, 'pair-old'), 'stale review token cannot label replacement pair');
is(LANraragi::Model::Dedup::CoverIndex::delete_cover_pair($cfg, $pair, 'pair-old'), 0, 'stale dismissal cannot hide replacement pair');
ok(defined $patch->($cfg, $pair, {status => 'variant'}, undef, 'pair-new'), 'current review token succeeds');
my $raw = $cfg->hget($metas, $pair);
$patch->($cfg, $pair, {status => 'needs_review'}, undef, 'pair-new');
ok(!defined $patch->($cfg, $pair, {verification => {status => 'identical_images'}}, $raw), 'verification still respects full metadata CAS');
is(decode_json($cfg->hget($metas, $pair))->{status}, 'needs_review', 'verification does not overwrite human decision');
is(LANraragi::Model::Dedup::CoverIndex::delete_cover_pair($cfg, $pair, 'pair-new'), 1, 'current dismissal succeeds');
is($publish->($cfg, $pair, 0, $meta, \%sources), 0, 'publication checks newly dismissed state atomically');

$cfg->zadd($pairs, 0, $pair);
$cfg->hset($metas, $pair, encode_json({cover_algo_version => 2}));
my $legacy = $cfg->hget($metas, $pair);
my $upgraded = LANraragi::Model::Dedup::CoverIndex::_pair_generation($cfg, $pair, $legacy);
like($upgraded->{generation}, qr/\A[0-9a-f]{64}\z/, 'historical pair receives opaque generation');
is(LANraragi::Model::Dedup::CoverIndex::_pair_generation($cfg, $pair, $legacy), undef, 'stale metadata read cannot borrow replacement generation');
my $db = Test::MockModule->new('LANraragi::Utils::Database');
$db->redefine(all_archive_ids => sub { ($a, $b) });
my $listed = LANraragi::Model::Dedup::CoverIndex::cover_pairs($cfg, $redis, {});
is($listed->{pairs}[0]{generation}, $upgraded->{generation}, 'review API response exposes generation');

# Generation changes clear every legacy and current signal family in one operation.
$redis->hmset($a, map { $_ => 'old' } qw(pagehashes pagehashes_v lead_hashes lead_hashes_v leadhashes leadhashes_v));
my $before = $redis->hget($a, 'dedup_generation');
LANraragi::Model::Dedup::CoverIndex::invalidate_cover_dedup_signals($redis, $cfg, $a);
isnt($redis->hget($a, 'dedup_generation'), $before, 'successive invalidations never reuse source token');
ok(!defined $redis->hget($a, $_), "invalidation clears $_") for qw(pagehashes pagehashes_v lead_hashes lead_hashes_v leadhashes leadhashes_v);

# Exercise the HTTP controller against real pair metadata, including old clients.
require Mojolicious;
require LANraragi::Controller::Api::Coverduplicates;
my $controller = Test::MockModule->new('LANraragi::Controller::Api::Coverduplicates');
$controller->redefine(_get_redis => sub { Redis->new(sock => "$guard->{dir}/redis.sock") });
$controller->redefine(_get_redis_config => sub {
    my $client = Redis->new(sock => "$guard->{dir}/redis.sock");
    $client->select(2);
    return $client;
});
my $log = Test::MockModule->new('LANraragi::Model::Dedup::ReviewLog');
my $events = 0;
$log->redefine(record_cover_decision => sub { $events++; return {} });
my $app = Mojolicious->new;
$cfg->zadd($pairs, 0, $pair);
$cfg->hset($metas, $pair, encode_json({generation => 'current', status => 'new'}));
for my $action (qw(update_status delete_pair)) {
    for my $generation (undef, 'stale') {
        my $c = $app->build_controller;
        $c->req->headers->content_type('application/json');
        $c->req->body(encode_json({pair => $pair, status => 'same_cover',
            defined($generation) ? (generation => $generation) : ()}));
        LANraragi::Controller::Api::Coverduplicates->can($action)->($c);
        is($c->res->code, 409, "$action rejects " . ($generation // 'absent') . ' generation');
        is(decode_json($cfg->hget($metas, $pair))->{status}, 'new', 'stale request has no mutation');
    }
}
is($events, 0, 'rejected reviews do not create audit events');
my $c = $app->build_controller;
$c->req->headers->content_type('application/json');
$c->req->body(encode_json({pair => $pair, status => 'variant', generation => 'current'}));
LANraragi::Controller::Api::Coverduplicates::update_status($c);
is($c->res->code, 200, 'current generation accepted through controller');
is($events, 1, 'accepted review creates one audit event');
$cfg->zrem($pairs, $pair);
$c = $app->build_controller;
$c->req->headers->content_type('application/json');
$c->req->body(encode_json({pair => $pair, status => 'variant', generation => 'current'}));
LANraragi::Controller::Api::Coverduplicates::update_status($c);
is($c->res->code, 404, 'removed pair returns404 separately from stale generation');
done_testing();
