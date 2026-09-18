use v5.36;
use strict;
use warnings;
use Test::More;
use Test::MockModule qw(strict);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Mojo::JSON qw(encode_json);
use Mojolicious;
use LANraragi::Controller::Api::Archive;
use LANraragi::Model::Dedup::CoverIndex;
use LANraragi::Model::Upload;
use LANraragi::Utils::Generic qw(exec_with_lock_pure);
require './tests/redis_test_server.pl';
my ($redis, $guard) = start_test_redis();
my $cfg = Redis->new(sock => "$guard->{dir}/redis.sock");
$cfg->select(2);
my $search = Redis->new(sock => "$guard->{dir}/redis.sock");
$search->select(3);
my $tmp = tempdir(CLEANUP => 1);
my $file = "$tmp/archive.cbz";
my $a = 'a' x 40;
my $b = 'b' x 40;
my $pair = "$a|$b";
my $pair_key = LANraragi::Model::Dedup::CoverIndex::PAIR_KEY();
my $meta_key = LANraragi::Model::Dedup::CoverIndex::PAIR_META_KEY();
{
    package CoverDeleteController;
    use parent 'Mojolicious::Controller';
    sub openapi { shift }
    sub valid_input { shift }
    sub render {
        my ($self, %args) = @_;
        $args{json} = delete $args{openapi} if exists $args{openapi};
        return $self->SUPER::render(%args);
    }
}
my $app = Mojolicious->new;
$app->log->level('fatal');
my $config = Test::MockModule->new('LANraragi::Model::Config');
$config->redefine(get_redis => sub { $redis });
$config->redefine(get_redis_config => sub { $cfg });
$config->redefine(get_redis_search => sub { $search });
$config->redefine(get_thumbdir => sub { "$tmp/thumbs" });
my $arc = Test::MockModule->new('LANraragi::Model::Archive');
$arc->redefine(clear_by_id => sub { 1 });
$arc->redefine(invalidate_cache => sub { 1 });
my $tanks = Test::MockModule->new('LANraragi::Model::Tankoubon');
$tanks->redefine(get_tankoubons_containing_archive => sub { () });
my $categories = Test::MockModule->new('LANraragi::Model::Category');
$categories->redefine(get_categories_containing_archive => sub { () });
my $db = Test::MockModule->new('LANraragi::Utils::Database');
$db->redefine(update_indexes => sub { 1 });
no warnings 'redefine';
local *Redis::quit = sub { 1 };
sub fixture {
    path($file)->spew('replacement bytes');
    $redis->hmset($a, file => $file, title => 'replacement title', tags => 'language:english', dedup_generation => 'source-new');
    $redis->sadd('LRR_ALL_ARCHIVES', $a);
    $cfg->zadd($pair_key, 0, $pair);
    $cfg->hset($meta_key, $pair, encode_json({generation => 'pair-new', cover_algo_version => 2}));
}
sub request {
    my (@query) = @_;
    my $c = bless $app->build_controller, 'CoverDeleteController';
    $c->stash(id => $a);
    $c->req->url->query(\@query);
    LANraragi::Controller::Api::Archive::delete_archive($c);
    return $c;
}
fixture();
for my $case (
    [400, cover_pair => $pair],
    [400, cover_generation => 'pair-new'],
    [400, cover_pair => $pair, cover_generation => ''],
    [400, cover_pair => "$b|" . ('c' x 40), cover_generation => 'pair-new'],
    [409, cover_pair => $pair, cover_generation => 'pair-old'],
) {
    my ($expected, @query) = @$case;
    my $before = $redis->dump($a);
    my $pair_before = $cfg->hget($meta_key, $pair);
    is(request(@query)->res->code, $expected, 'invalid or stale conditional delete rejected');
    is($redis->dump($a), $before, 'rejected delete leaves archive metadata byte-for-byte intact');
    is(path($file)->slurp, 'replacement bytes', 'rejected delete preserves replacement file');
    is($cfg->hget($meta_key, $pair), $pair_before, 'rejected delete preserves candidate metadata');
}
$cfg->zrem($pair_key, $pair);
is(request(cover_pair => $pair, cover_generation => 'pair-new')->res->code, 404, 'removed pair rejected');
ok(-f $file && $redis->exists($a), 'removed pair cannot delete archive file or metadata');

fixture();
my ($acquired) = exec_with_lock_pure(["archive-write:$a"], sub {
    is(request(cover_pair => $pair, cover_generation => 'pair-new')->res->code, 423, 'same-ID upload mutex blocks conditional delete');
    # Same-ID replacement changes source and pair while holding its archive lock.
    LANraragi::Model::Dedup::CoverIndex::invalidate_cover_dedup_signals($redis, $cfg, $a);
    $cfg->zadd($pair_key, 0, $pair);
    $cfg->hset($meta_key, $pair, encode_json({generation => 'pair-replaced'}));
    return 1;
}, $cfg, 300);
ok($acquired, 'test acquired the same archive-write lock used by Upload');
is(request(cover_pair => $pair, cover_generation => 'pair-new')->res->code, 409, 'delete rechecks generation after upload releases mutex');
ok(-f $file && $redis->exists($a), 'same-ID replacement survives delayed delete');

{
    # Exercise the actual upload path as a contender while the API deletion owns
    # its ID lock, rather than relying only on matching literal lock names.
    path("$tmp/incoming")->make_path;
    my $incoming = "$tmp/incoming/archive.cbz";
    path($incoming)->spew('competing replacement bytes');
    $config->redefine(get_userdir => sub { $tmp });
    $config->redefine(get_replacedupe => sub { 1 });
    my $upload = Test::MockModule->new('LANraragi::Model::Upload');
    $upload->redefine(compute_id => sub { $a });
    my $delete = LANraragi::Model::Archive->can('delete_archive');
    $arc->redefine(delete_archive => sub {
        my ($upload_status) = LANraragi::Model::Upload::handle_incoming_file($incoming, undef, undef, undef, undef);
        is($upload_status, 409, 'actual same-ID Upload path cannot publish while conditional delete owns mutex');
        is(path($file)->slurp, 'replacement bytes', 'blocked upload has not changed the deletion target');
        return $delete->(@_);
    });
    is(request(cover_pair => $pair, cover_generation => 'pair-replaced')->res->code, 200, 'current displayed generation permits deletion');
    $arc->redefine(delete_archive => $delete);
}
ok(!-e $file && !$redis->exists($a), 'accepted conditional delete removes actual file and metadata');
fixture();
is(request()->res->code, 200, 'ordinary DELETE without both optional fields preserves existing contract');
ok(!-e $file && !$redis->exists($a), 'ordinary DELETE still removes actual file and metadata');
done_testing();
