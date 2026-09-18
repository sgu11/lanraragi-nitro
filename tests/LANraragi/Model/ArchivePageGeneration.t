use v5.36;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojolicious;
use Mojo::File qw(path);
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep);
use Config;
use LANraragi::Model::Archive;
use LANraragi::Utils::PageCache qw(fetch clear_by_id get_generation);

plan skip_all => 'native fork required' if $Config{d_pseudofork};
my $dir = tempdir(CLEANUP => 1);
my $id = 'a' x 40;
my $source = path("$dir/source");
$source->spurt('old');
my $calls = path("$dir/transforms");
my $started = path("$dir/started");
my $released = path("$dir/released");
my $resize = 1;
my $invalidate_during_extraction = 0;
{
    no warnings 'redefine';
    *LANraragi::Utils::ImagePipeline::get_temp = sub { $dir };
    *LANraragi::Utils::PageCache::get_temp = sub { $dir };
    *LANraragi::Utils::PageCache::get_logger = sub { bless {}, 'GenerationLogger' };
    *LANraragi::Utils::PageCache::calc_max_size = sub { 2 };
    *LANraragi::Model::Archive::get_logger = sub { bless {}, 'GenerationLogger' };
    *LANraragi::Model::Archive::_resolve_archive_path = sub { 'synthetic.cbz' };
    *LANraragi::Model::Archive::extract_single_file = sub {
        my $bytes = $source->slurp;
        if ($invalidate_during_extraction) {
            $invalidate_during_extraction = 0;
            clear_by_id($id);
        }
        return $bytes;
    };
    *LANraragi::Model::Config::enable_resize = sub { $resize };
    *LANraragi::Model::Config::get_threshold = sub { 100 };
    *LANraragi::Model::Config::get_readquality = sub { 80 };
    *LANraragi::Model::Metrics::record_image_serving_metrics = sub {};
    *LANraragi::Model::Reader::resize_image = sub {
        my ($bytes) = @_;
        open my $fh, '>>', $calls or die $!;
        say {$fh} $bytes; close $fh;
        if ($bytes eq 'old') {
            $started->spurt('1');
            for (1 .. 500) { last if -e $released; sleep 0.01; }
            die "barrier timeout\n" unless -e $released;
        }
        return "$bytes resized";
    };
}
local $ENV{LRR_PAGECACHE_PAGE_SIZE_MB} = 1;
LANraragi::Utils::PageCache::initialize();
my $app = Mojolicious->new;
$app->plugin('RenderFile');
$app->routes->get('/page')->to(cb => sub { LANraragi::Model::Archive::serve_page($_[0], $id, '001.jpg') });
my $t = Test::Mojo->new($app);
my ($fresh, $old_response, $fresh_response);
my $previous = get_generation($id);
my $timer;
$timer = Mojo::IOLoop->recurring(0.01 => sub {
    return unless -e $started;
    Mojo::IOLoop->remove($timer);
    $source->spurt('new');
    clear_by_id($id);
    $fresh = $t->ua->get_p('/page');
    $released->spurt('1');
});
$t->ua->get_p('/page')->then(sub { $old_response = $_[0]->res })->wait;
ok(defined $fresh, 'replacement request starts while the previous transform is in flight');
$fresh->then(sub { $fresh_response = $_[0]->res })->wait if $fresh;
is($old_response->code, 503, 'superseded transform is retryable rather than served as current content');
is($fresh_response->code, 200, 'new generation request succeeds independently');
is($fresh_response->body, 'new resized', 'replacement receives newly extracted bytes');
is(fetch("page/$id/001.jpg"), 'new', 'late old extraction cannot reappear in the original cache');
is(fetch("resize_page/$id/001.jpg/100/80"), 'new resized', 'late old transform cannot overwrite replacement cache');
is(fetch("resize_page/$id/001.jpg/100/80", $previous), undef, 'older request cannot read the replacement cache');
$t->get_ok('/page')->status_is(200)->content_is('new resized');
is_deeply([split /\n/, $calls->slurp], ['old', 'new'], 'subsequent cache hit does not launch another transform');

$resize = 0;
clear_by_id($id);
$invalidate_during_extraction = 1;
$t->get_ok('/page')->status_is(503);
is(fetch("page/$id/001.jpg"), undef, 'superseded original extraction cannot publish without a transform');
$t->get_ok('/page')->status_is(200)->content_is('new');
done_testing();

package GenerationLogger;
sub debug { 1 }
sub warn { 1 }
