use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use LANraragi::Model::Upload;

require './tests/redis_test_server.pl';
my ($db, $guard) = start_test_redis();
my $search = Redis->new(sock => "$guard->{dir}/redis.sock");
$search->select(3);
my $config = Redis->new(sock => "$guard->{dir}/redis.sock");
$config->select(2);
my $root = tempdir(CLEANUP => 1);
mkdir "$root/first";
mkdir "$root/second";
mkdir "$root/content";
my $first = "$root/first/book.zip";
my $second = "$root/second/book.zip";
my $output = "$root/content/book.zip";

{ package UploadRaceLogger; sub debug {} sub trace {} sub info {} sub warn {} sub error {} }
no warnings 'redefine';
local *Redis::quit = sub {};
local *LANraragi::Model::Config::get_userdir = sub { "$root/content" };
local *LANraragi::Model::Config::get_thumbdir = sub { "$root/thumbs" };
local *LANraragi::Model::Config::get_replacedupe = sub { 0 };
local *LANraragi::Model::Config::get_redis = sub { $db };
local *LANraragi::Model::Config::get_redis_search = sub { $search };
local *LANraragi::Model::Config::get_redis_config = sub { $config };
local *LANraragi::Model::Upload::get_logger = sub { bless {}, 'UploadRaceLogger' };
local *LANraragi::Utils::Generic::get_logger = sub { bless {}, 'UploadRaceLogger' };
local *LANraragi::Utils::Database::get_logger = sub { bless {}, 'UploadRaceLogger' };
local *LANraragi::Model::Upload::add_timestamp_tag = sub {};
local *LANraragi::Model::Upload::add_pagecount = sub { $db->hset($_[1], 'pagecount', 2) };
local *LANraragi::Model::Upload::extract_thumbnail = sub {};
local *LANraragi::Model::Upload::enqueue_first_spread_start_detection = sub {};
local *LANraragi::Model::Plugins::exec_enabled_plugins_on_file = sub { (0, 0, 0, '') };

sub fixture ($same_bytes = 0) {
    $db->flushdb;
    $search->flushdb;
    $config->flushdb;
    unlink $output if -e $output;
    path($first)->spurt('first request bytes');
    path($second)->spurt($same_bytes ? 'first request bytes' : 'second request bytes');
    return map { LANraragi::Utils::Database::compute_id($_) } ($first, $second);
}

sub upload ($file) {
    return LANraragi::Model::Upload::handle_incoming_file($file, undef, undef, undef, undef);
}

subtest 'a completed competitor cannot bypass the disabled replacement policy' => sub {
    my ($first_id, $second_id) = fixture();
    my $move = \&LANraragi::Model::Upload::move_path;
    my ($interleaved, $second_status);
    local *LANraragi::Model::Upload::move_path = sub {
        if (!$interleaved++ && $_[0] eq $first) {
            ($second_status) = upload($second);
        }
        return $move->(@_);
    };
    my ($first_status) = upload($first);
    is($second_status, 200, 'competing request commits while the first is paused before staging');
    is($first_status, 409, 'first request rechecks replacement policy after acquiring locks');
    is(path($output)->slurp, 'second request bytes', 'successful competing upload is preserved');
    ok($db->exists($second_id), 'successful metadata survives');
    ok(!$db->exists($first_id), 'rejected request has no metadata');
    is_deeply([glob("$root/content/*.upload"), glob("$root/content/.lrr-upload-*.upload")], [], 'both requests clean up only their own staging');
};

subtest 'overlapping requests for a destination cannot share or erase staging' => sub {
    my ($first_id, $second_id) = fixture();
    my $lock = \&LANraragi::Model::Upload::exec_with_lock_pure;
    my ($interleaved, $second_status);
    local *LANraragi::Model::Upload::exec_with_lock_pure = sub {
        my ($names, $body, @options) = @_;
        return $lock->($names, sub {
            if ($names->[0] =~ /^archive-path:/ && !$interleaved++) {
                ($second_status) = upload($second);
                my @staging = glob "$root/content/.lrr-upload-*.upload";
                is(scalar @staging, 1, 'rejected competitor leaves the first request staging intact');
                is(path($staging[0])->slurp, 'first request bytes', 'remaining staging belongs to the first request');
            }
            return $body->();
        }, @options);
    };
    my ($first_status) = upload($first);
    is($first_status, 200, 'lock owner commits');
    is($second_status, 409, 'same-destination competitor is rejected');
    is(path($output)->slurp, 'first request bytes', 'file contents match the winning request');
    is(LANraragi::Utils::Database::compute_id($output), $first_id, 'published ID matches actual bytes');
    ok(!$db->exists($second_id), 'loser cannot create metadata');
};

subtest 'different destination names still serialize the same archive ID' => sub {
    my ($first_id) = fixture(1);
    my $renamed = "$root/second/renamed.zip";
    path($renamed)->spurt(path($second)->slurp);
    my $lock = \&LANraragi::Model::Upload::exec_with_lock_pure;
    my ($interleaved, $second_status);
    local *LANraragi::Model::Upload::exec_with_lock_pure = sub {
        my ($names, $body, @options) = @_;
        return $lock->($names, sub {
            if ($names->[0] eq "archive-write:$first_id" && !$interleaved++) {
                ($second_status) = upload($renamed);
            }
            return $body->();
        }, @options);
    };
    my ($first_status) = upload($first);
    is($first_status, 200, 'first ID owner commits');
    is($second_status, 409, 'same ID at another path cannot publish concurrently');
    ok(!-e "$root/content/renamed.zip", 'second destination is not published');
    is($db->hget($first_id, 'file'), $output, 'metadata points to the winning path');
};

done_testing();
