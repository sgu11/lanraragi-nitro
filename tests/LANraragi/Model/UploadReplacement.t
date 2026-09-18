use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use LANraragi::Model::Upload;
require './tests/redis_test_server.pl';
my ($redis, $guard) = start_test_redis();
my $root = tempdir(CLEANUP => 1);
mkdir "$root/incoming";
mkdir "$root/content";
my $incoming = "$root/incoming/book.zip";
my $output = "$root/content/book.zip";
my $id = 'a' x 40;
sub write_bytes ($path, $bytes) { open my $fh, '>', $path or die $!; print {$fh} $bytes; close $fh; }
sub read_bytes ($path) { open my $fh, '<', $path or die $!; local $/; return <$fh>; }
{ package ReplacementLogger; sub debug {} sub info {} sub warn {} }
no warnings 'redefine';
local *LANraragi::Model::Upload::get_logger = sub { bless {}, 'ReplacementLogger' };
local *LANraragi::Model::Config::get_userdir = sub { "$root/content" };
local *LANraragi::Model::Config::get_thumbdir = sub { "$root/thumbs" };
local *LANraragi::Model::Config::get_replacedupe = sub { 1 };
local *LANraragi::Model::Config::get_redis = sub { $redis };
local *LANraragi::Model::Config::get_redis_search = sub { $redis };
local *LANraragi::Model::Config::get_redis_config = sub { $redis };
local *LANraragi::Model::Upload::_close_upload_redis_handles = sub {};
local *LANraragi::Model::Upload::compute_id = sub { $id };
local *LANraragi::Model::Upload::get_archive_path = sub { $redis->hget($id, 'file') };
local *LANraragi::Model::Upload::exec_with_lock_pure = sub { (1, $_[1]->()) };
my $page_generation = 0;
local *LANraragi::Utils::PageCache::clear_by_id = sub { $page_generation++ };
local *LANraragi::Utils::PageSide::clear_first_spread_start_detection = sub {};
local *LANraragi::Model::Upload::add_timestamp_tag = sub {};
local *LANraragi::Model::Upload::add_pagecount = sub { $redis->hset($id, 'pagecount', 2) };
local *LANraragi::Model::Upload::add_arcsize = sub {};
local *LANraragi::Model::Upload::extract_thumbnail = sub {};
local *LANraragi::Model::Upload::enqueue_first_spread_start_detection = sub {};
local *LANraragi::Model::Upload::invalidate_cache = sub {};
local *LANraragi::Model::Upload::set_title = sub { $redis->hset($_[0], 'title', $_[1]) };
local *LANraragi::Model::Upload::set_tags = sub { $redis->hset($_[0], 'tags', $_[1]) };
local *LANraragi::Model::Plugins::exec_enabled_plugins_on_file = sub { (0, 0, 0, '') };
my %original = (file => $output, title => 'My title', tags => 'artist:fixture', progress => 1, pagecount => 1);
for my $failure (qw(rename metadata success)) {
    write_bytes($output, 'old bytes');
    write_bytes($incoming, 'new bytes');
    $redis->del($id);
    $redis->hmset($id, %original);
    $redis->hset($id, 'dedup_generation', 'previous-generation');
    $redis->hset('LRR_FILEMAP', $output, $id);
    my $rename = \&LANraragi::Utils::UploadCommit::rename_path;
    local *LANraragi::Utils::UploadCommit::rename_path = sub {
        if ($failure eq 'rename' && $_[0] =~ /\.upload$/ && $_[1] eq $output) { $! = 13; return 0; }
        return $rename->(@_);
    };
    my ($writing_generation, $writing_page_generation);
    local *LANraragi::Model::Upload::add_arcsize = sub {
        $writing_generation = $redis->hget($id, 'dedup_generation');
        $writing_page_generation = $page_generation;
        die "metadata failed\n" if $failure eq 'metadata';
    };
    my ($status) = LANraragi::Model::Upload::handle_incoming_file($incoming, undef, undef, undef, undef);
    is($status, $failure eq 'success' ? 200 : 500, "$failure: request status");
    is(read_bytes($output), $failure eq 'success' ? 'new bytes' : 'old bytes', "$failure: correct file survives");
    my %actual = $redis->hgetall($id);
    my $generation = delete $actual{dedup_generation};
    my %expected = (%original, ($failure eq 'success' ? (pagecount => 2) : ()));
    is_deeply(\%actual, \%expected, "$failure: metadata and progress preserved");
    is($redis->hget('LRR_FILEMAP', $output), $id, "$failure: file mapping preserved");
    if ($failure eq 'rename') {
        is($generation, 'previous-generation', 'failed publication does not change the source generation');
    } else {
        like($generation, qr/^[a-f0-9]{64}$/, "$failure: source has a fresh dedup generation");
        isnt($generation, 'previous-generation', "$failure: old dedup work is fenced out");
        isnt($generation, $writing_generation, 'rollback also fences work started for the failed replacement')
          if $failure eq 'metadata';
        cmp_ok($page_generation, '>', $writing_page_generation, 'rollback also invalidates pages read from the failed replacement')
          if $failure eq 'metadata';
    }
}
done_testing();
