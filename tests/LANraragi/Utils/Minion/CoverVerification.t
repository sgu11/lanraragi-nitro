use v5.36;
use strict;
use warnings;
use Test::More;
use Test::MockModule qw(strict);
use Archive::Zip qw(AZ_OK);
use File::Temp qw(tempdir);
use Mojo::JSON qw(encode_json decode_json);
use LANraragi::Utils::Minion::Dedup;
require './tests/redis_test_server.pl';
my ($redis, $server) = start_test_redis();
my $dir = tempdir(CLEANUP => 1);
my ($a, $b) = ('a' x 40, 'b' x 40);
my $pair = "$a|$b";
my $key = LANraragi::Model::Dedup::CoverIndex::PAIR_KEY();
my $meta_key = LANraragi::Model::Dedup::CoverIndex::PAIR_META_KEY();
my %paths;
for my $id ($a, $b) {
    my $zip = Archive::Zip->new;
    $zip->addString('identical cover', '1.jpg');
    $zip->addString('identical interior', '2.jpg');
    $paths{$id} = "$dir/$id.cbz";
    die 'fixture write failed' unless $zip->writeToFileNamed($paths{$id}) == AZ_OK;
}
my $config = Test::MockModule->new('LANraragi::Model::Config');
$config->redefine(get_redis => sub { Redis->new(sock => "$server->{dir}/redis.sock") });
$config->redefine(get_redis_config => sub { Redis->new(sock => "$server->{dir}/redis.sock") });
my $path = Test::MockModule->new('LANraragi::Utils::Path');
$path->redefine(get_archive_path => sub { $paths{$_[1]} });
{
    package VerificationMinion;
    sub new { bless {tasks => {}, locked => 0}, shift }
    sub add_task { $_[0]{tasks}{$_[1]} = $_[2] }
    sub guard { $_[0]{locked} ? undef : bless({}, 'VerificationGuard') }
    package VerificationJob;
    sub new { bless {}, shift }
    sub finish { $_[0]{result} = $_[1] }
    sub retry { $_[0]{retry} = $_[1] }
    sub note { my $self = shift; $self->{notes} = {@_}; }
}
my $minion = VerificationMinion->new;
LANraragi::Utils::Minion::Dedup::add_tasks($minion);
my $task = $minion->{tasks}{verify_cover_duplicates};
$redis->zadd($key, 0, $pair);
$redis->hset($meta_key, $pair, encode_json({status => 'needs_review', generation => 'original'}));
my $job = VerificationJob->new;
$task->($job, [$pair]);
is($job->{result}{counts}{same_images}, 1, 'registered job verifies all image bytes');
is($job->{result}{pairs}{$pair}{state}, 'same_images', 'job returns bounded evidence by exact pair for deep history views');
is($job->{notes}{completed}, 1, 'job publishes progress');
my $stored = decode_json($redis->hget($meta_key, $pair));
is($stored->{status}, 'needs_review', 'verification preserves human status');
is($stored->{verification}{state}, 'same_images', 'job stores its evidence');

$minion->{locked} = 1;
$job = VerificationJob->new;
$task->($job, [$pair]);
is($job->{retry}{delay}, 10, 'concurrent batches retry instead of multiplying disk work');
$minion->{locked} = 0;

my $verify = Test::MockModule->new('LANraragi::Model::Dedup::ContentVerification');
$verify->redefine(verify_pair => sub {
    $redis->hset($meta_key, $pair, encode_json({status => 'new', generation => 'replacement'}));
    return {state => 'same_images'};
});
$job = VerificationJob->new;
$task->($job, [$pair]);
is_deeply($job->{result}{pairs}, {}, 'changed candidate rejects late verification evidence');
$stored = decode_json($redis->hget($meta_key, $pair));
ok(!exists $stored->{verification}, 'replacement stays unverified');

$verify->redefine(verify_pair => sub { die "Cannot verify\n" });
$job = VerificationJob->new;
$task->($job, [$pair]);
is($job->{result}{counts}{unavailable}, 1, 'unreadable content is unknown, not a mismatch or duplicate');
$redis->zrem($key, $pair);
$job = VerificationJob->new;
$task->($job, [$pair]);
is_deeply($job->{result}{pairs}, {}, 'removed candidate is not recreated');
done_testing();
