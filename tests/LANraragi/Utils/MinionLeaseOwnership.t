use v5.36;
use strict;
use warnings;
use Test::More;
use Test::MockModule qw(strict);
use File::Temp qw(tempfile);
use LANraragi::Utils::Minion;
use Shinobu;
require './tests/redis_test_server.pl';
my ($redis, $guard) = start_test_redis();
my $config = Test::MockModule->new('LANraragi::Model::Config');
$config->redefine(get_redis_config => sub { Redis->new(sock => "$guard->{dir}/redis.sock") });
$config->redefine(get_redis => sub { Redis->new(sock => "$guard->{dir}/redis.sock") });
{
    package LeaseMinion;
    sub add_task { $_[0]{tasks}{$_[1]} = $_[2] }
    sub on { $_[0]{events}{$_[1]} = $_[2] }
    package LeaseJob;
    sub id { $_[0]{id} }
    sub task { $_[0]{task} }
    sub args { $_[0]{args} }
    sub info { +{state => $_[0]{state} // 'failed'} }
    sub fail { $_[0]{failed} = $_[1] }
    sub finish { $_[0]{finished} = $_[1] }
    package LeaseLogger;
    sub error { 1 }
    sub info { 1 }
    sub debug { 1 }
    sub warn { 1 }
}
my $minion = bless {}, 'LeaseMinion';
LANraragi::Utils::Minion::add_tasks($minion);
my $utils = Test::MockModule->new('LANraragi::Utils::Minion');
$utils->redefine(get_logger => sub { bless {}, 'LeaseLogger' });
my $watcher = Test::MockModule->new('Shinobu');
my ($fh, $file) = tempfile(UNLINK => 1);
close $fh;
my $key = 'LRR_INGEST_PENDING:synthetic';
for my $failure (0, 1) {
    $redis->set($key, 'old-owner');
    $watcher->redefine(add_to_filemap => sub {
        # The old lease expires and another ingest acquires it before this work returns.
        $redis->del($key);
        $redis->set($key, 'new-owner', 'NX', 'EX', 900);
        die "synthetic ingest error\n" if $failure;
        return 1;
    });
    my $job = bless {}, 'LeaseJob';
    $minion->{tasks}{ingest_archive_file}->($job, $file, $key, 'old-owner');
    is($redis->get($key), 'new-owner', ($failure ? 'failed' : 'successful') . ' expired ingest cannot clear successor lease');
}
$watcher->redefine(add_to_filemap => sub { 1 });
$redis->set($key, 'current-owner');
$minion->{tasks}{ingest_archive_file}->(bless({}, 'LeaseJob'), $file, $key, 'current-owner');
ok(!$redis->exists($key), 'current successful ingest releases its own lease');
$redis->set($key, 'successor');
$minion->{tasks}{ingest_archive_file}->(bless({}, 'LeaseJob'), $file, $key);
is($redis->get($key), 'successor', 'pre-upgrade queued task without token leaves lease to expire');

my $thumb = 'LRR_THUMBNAIL_JOB:synthetic';
$redis->set($thumb, 102);
LANraragi::Utils::Minion::_clear_thumbnail_job_lock($thumb, 101);
is($redis->get($thumb), 102, 'old thumbnail completion cannot clear newer job lease');
LANraragi::Utils::Minion::_clear_thumbnail_job_lock($thumb, 102);
ok(!$redis->exists($thumb), 'current thumbnail completion releases lease');
my $arc = 'a' x 40;
$redis->hset($arc, thumbjob => 202);
my $failed = $minion->{events}{failed};
$failed->($minion, bless({task => 'page_thumbnails', args => [$arc], id => 201}, 'LeaseJob'));
is($redis->hget($arc, 'thumbjob'), 202, 'old failed page-thumbnail batch cannot clear replacement job');
$failed->($minion, bless({task => 'page_thumbnails', args => [$arc], id => 202}, 'LeaseJob'));
ok(!defined $redis->hget($arc, 'thumbjob'), 'current failed page-thumbnail batch clears its field');
# Script reload retains owner checks after a Redis script-cache reset.
$redis->script_flush;
$redis->set($thumb, 'replacement');
LANraragi::Utils::Minion::_clear_thumbnail_job_lock($thumb, 'expired');
is($redis->get($thumb), 'replacement', 'NOSCRIPT reload preserves owner comparison');

my $logging = Test::MockModule->new('LANraragi::Utils::Logging');
$logging->redefine(get_logger => sub { bless {}, 'LeaseLogger' });
my $dedup = Test::MockModule->new('LANraragi::Model::Dedup');
$redis->hmset($arc, file => $file, title => 'synthetic');
$dedup->redefine(compute_leadhashes_for_archive => sub { $redis->del($arc); return 0 });
$minion->{tasks}{compute_dedup_signals}->(bless({}, 'LeaseJob'), $arc);
ok(!$redis->exists($arc), 'post-hash metadata update cannot resurrect deleted archive');
done_testing();
