use v5.36;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojolicious;
use Mojo::Promise;
use Mojo::File qw(path);
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep);
use Config;
use LANraragi::Model::Archive;

plan skip_all => 'native fork required' if $Config{d_pseudofork};
my $dir = tempdir(CLEANUP => 1);
my $resize = 0;
my $crop_log = "$dir/crops";
my $ticks = 0;

{
    no warnings 'redefine';
    *LANraragi::Utils::ImagePipeline::get_temp = sub { $dir };
    *LANraragi::Utils::PageCache::get_temp = sub { $dir };
    *LANraragi::Model::Archive::_resolve_archive_path = sub { 'fixture.cbz' };
    *LANraragi::Model::Config::enable_resize = sub { $resize };
    *LANraragi::Model::Config::get_threshold = sub { 100 };
    *LANraragi::Model::Config::get_readquality = sub { 80 };
    *LANraragi::Model::Archive::get_page_data = sub { 'original' };
    *LANraragi::Model::Archive::_apply_border_crop = sub {
        open my $fh, '>>', $crop_log or die $!;
        say {$fh} 'crop'; close $fh;
        sleep 0.15;
        return ("cropped\0\xff", 1);
    };
    *LANraragi::Model::Reader::resize_image = sub { "resized\0\xff" };
    *LANraragi::Model::Archive::fetch = sub {
        my $file = path("$dir/" . sha256_hex($_[0]));
        return -e $file ? $file->slurp : undef;
    };
    *LANraragi::Model::Archive::put = sub {
        path("$dir/" . sha256_hex($_[0]))->spurt($_[1]);
    };
    *LANraragi::Model::Archive::get_logger = sub { bless {}, 'PipelineLogger' };
    *LANraragi::Model::Metrics::record_image_serving_metrics = sub {};
}

my $app = Mojolicious->new;
$app->plugin('RenderFile');
$app->routes->get('/page')->to(cb => sub {
    LANraragi::Model::Archive::serve_page($_[0], 'a' x 40, 'page.png');
});
$app->routes->get('/pulse')->to(cb => sub { $_[0]->render(text => 'ready') });
my $t = Test::Mojo->new($app);
my $timer = Mojo::IOLoop->recurring(0.01 => sub { $ticks++ });
for my $mode (0, 1) {
    $resize = $mode;
    my @responses;
    Mojo::Promise->all(
        $t->ua->get_p('/page?crop=border'),
        $t->ua->get_p('/page?crop=border'),
        $t->ua->get_p('/pulse'),
    )->then(sub { @responses = map { $_->[0]->res } @_; })->catch(sub { fail("HTTP request failed: $_[0]"); })->wait;
    is(scalar @responses, 3, "mode $mode requests finish");
    my $expected = $mode ? "resized\0\xff" : "cropped\0\xff";
    is($_->code, 200, 'successful image response') for @responses[0,1];
    is($_->body, $expected, 'binary image bytes cross the subprocess intact') for @responses[0,1];
    is($responses[2]->body, 'ready', 'unrelated route remains available');
    my @calls = split /\n/, path($crop_log)->slurp;
    is(scalar @calls, $mode + 1, 'one crop computation per final variant, including resize');
}
Mojo::IOLoop->remove($timer);
cmp_ok($ticks, '>=', 5, 'web event loop keeps ticking during slow crop computations');
done_testing();

package PipelineLogger;
sub debug { 1 }
sub warn { 1 }
