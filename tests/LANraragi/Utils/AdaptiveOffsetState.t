use v5.36;
use strict;
use warnings;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;
use Test::MockModule qw(strict);
use LANraragi::Utils::AdaptiveOffsetState;
use LANraragi::Utils::PageSide qw(clear_first_spread_start_detection store_user_first_spread_start);
require './tests/redis_test_server.pl';
my ($redis, $guard) = start_test_redis();
my $tmp = tempdir(CLEANUP => 1);
my $file = "$tmp/archive.zip";
path($file)->spew('fixture');
my $id = 'a' x 40;
$redis->hset($id, file => 'fixture', firstspreadstart => '2', firstspreadstart_reason => 'legacy');
local $ENV{ADAPTIVE_OFFSET_WORKER_URL} = 'http://worker.invalid';
my $state = Test::MockModule->new('LANraragi::Utils::AdaptiveOffsetState');
my $config = Test::MockModule->new('LANraragi::Model::Config');
my $client_module = Test::MockModule->new('LANraragi::Utils::AdaptiveOffsetClient');
$state->redefine(get_archive_path => sub { $file });
$state->redefine(get_filelist => sub { 0..11 });
my (@read, $decode_calls, $vote_calls, $queued);
$decode_calls = $vote_calls = $queued = 0;
my $mode = '';
my @batches;
$state->redefine(extract_single_file => sub {
    push @read, $_[1];
    die "missing\n" if $mode eq 'read_fail' && $_[1] == 11;
    return 'x' x (8 * 1024 * 1024) if $mode =~ /^large/;
    return 'image';
});
{
    package AdaptiveStateClient;
    sub detect_pages ($self, $pages, $revision) {
        $decode_calls++;
        push @batches, [map { $_->{index} } @$pages];
        die "503\n" if $mode eq 'worker_fail';
        die "503\n" if $mode eq 'large_fail' && @$pages && $pages->[0]{index} == 5;
        return [map { +{page_index => $_->{index}, sha256 => 'b' x 64, side => 'LEFT', confidence => 0.8,
            reason => 'edge_complexity', source_width => 100, source_height => 200} } @$pages];
    }
    sub vote_groups ($self, $groups, $revision) {
        $vote_calls++;
        LANraragi::Utils::PageSide::store_user_first_spread_start($redis, $id, 4) if $mode eq 'manual_race';
        LANraragi::Utils::PageSide::clear_first_spread_start_detection($redis, $id) if $mode eq 'content_race';
        Mojo::File::path($file)->spew('changed fixture bytes') if $mode eq 'file_race';
        return [map { +{id => $_->{id}, %{LANraragi::Utils::AdaptiveOffsetVote::aggregate($_->{observations})}} } @$groups];
    }
    package AdaptiveStateQueue;
    sub enqueue { $queued++; return $queued; }
}
$client_module->redefine(new => sub { bless {}, 'AdaptiveStateClient' });
$config->redefine(get_redis => sub { Redis->new(sock => "$guard->{dir}/redis.sock") });
$config->redefine(get_minion => sub { bless {}, 'AdaptiveStateQueue' });

my $pending = LANraragi::Utils::AdaptiveOffsetState::read_state($redis, $id, 1);
is($pending->{status}, 'pending', 'first request schedules background work');
is($pending->{first_spread_start}, 'UNKNOWN', 'old automatic value is not a worker fallback');
LANraragi::Utils::AdaptiveOffsetState::read_state($redis, $id, 1);
is($queued, 1, 'concurrent polling deduplicates queue requests');
my $result = LANraragi::Utils::AdaptiveOffsetState::detect_and_store($id);
is($result->{status}, 'ready', 'complete prefix produces ready evidence');
is_deeply(\@read, [0..11], 'prefix includes cover geometry and all selected evidence');
is($result->{first_spread_start}, 'UNKNOWN', 'valid ambiguous vote is cached');
is(LANraragi::Utils::AdaptiveOffsetState::read_state($redis, $id)->{status}, 'ready', 'unknown cache is reusable');
LANraragi::Utils::AdaptiveOffsetState::detect_and_store($id);
is($decode_calls, 1, 'warm inference does not decode again');
is($redis->hget($id, 'firstspreadstart'), '2', 'worker leaves legacy archive fields untouched');

for my $failure (qw(read_fail worker_fail content_race manual_race file_race)) {
    clear_first_spread_start_detection($redis, $id);
    $mode = $failure;
    my $before = $vote_calls;
    my $failed = LANraragi::Utils::AdaptiveOffsetState::detect_and_store($id);
    is($failed->{status}, 'error', "$failure never returns a valid UNKNOWN");
    is($vote_calls, $before, "$failure never votes partial evidence") if $failure =~ /^(?:read|worker)_fail$/;
    is($failed->{stale}, 1, "$failure rejects late evidence") if $failure =~ /race$/;
    my $view = LANraragi::Utils::AdaptiveOffsetState::read_state($redis, $id);
    isnt($view->{status}, 'ready', "$failure is not cached as successful evidence");
    is($view->{first_spread_start}, '4', 'manual feedback wins during worker completion') if $failure eq 'manual_race';
}
$mode = '';
clear_first_spread_start_detection($redis, $id);
$redis->hset($id, pagecount => 13);
my $before_count_vote = $vote_calls;
is(LANraragi::Utils::AdaptiveOffsetState::detect_and_store($id)->{status}, 'error', 'changed page count does not reuse inferred evidence');
is($vote_calls, $before_count_vote, 'page count mismatch does not vote');
$redis->hset($id, pagecount => 12);
store_user_first_spread_start($redis, $id, 4);
my $manual = LANraragi::Utils::AdaptiveOffsetState::detect_and_store($id);
is($manual->{status}, 'ready', 'manual global feedback does not suppress independent segment inference');
is($manual->{first_spread_start}, '4', 'manual global value remains preferred');
is($redis->hget($id, 'firstspreadstart_reason'), 'user_slide', 'manual provenance preserved');
for my $large_mode (qw(large large_fail)) {
    clear_first_spread_start_detection($redis, $id);
    $mode = $large_mode;
    @read = @batches = ();
    my $before = $vote_calls;
    my $large = LANraragi::Utils::AdaptiveOffsetState::detect_and_store($id);
    if ($large_mode eq 'large') {
        is($large->{status}, 'ready', '96 MiB prefix is acquired in bounded requests');
        is_deeply(\@batches, [[0..4], [5..9], [10..11]], 'payload batches reserve header and metadata space');
        is_deeply(\@read, [0..11], 'large prefix acquires every page exactly once');
    } else {
        is($large->{status}, 'error', 'later batch failure rejects the complete inference');
        is_deeply(\@batches, [[0..4], [5..9]], 'batch failure stops remaining requests');
        is($vote_calls, $before, 'successful first batch never becomes a partial vote');
        isnt(LANraragi::Utils::AdaptiveOffsetState::read_state($redis, $id)->{status}, 'ready', 'partial evidence is not cached');
    }
}
local $ENV{ADAPTIVE_OFFSET_WORKER_URL} = '';
is(LANraragi::Utils::AdaptiveOffsetState::read_state($redis, $id)->{status}, 'disabled', 'no implicit worker target');
done_testing();
