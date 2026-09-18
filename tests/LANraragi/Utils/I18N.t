use strict;
use warnings;
use utf8;

use Test::More;
use Mojolicious;

use LANraragi::Utils::I18N;
use LANraragi::Utils::I18NInitializer;

my $handle = LANraragi::Utils::I18N->get_handle('en');
my @reader_keys = (
    'F or Middle-click: toggle fullscreen mode',
    'Adaptive Offset',
    'Sliding page transitions',
    'Slide duration',
    'Click duration; touch uses this value as spring response time, not a fixed completion time. Single and double pages only.',

    'Cover and wide pages stay single. Press J to toggle.',
    'On',
    'Off',
    'Use AVIF for thumbnails',
    'Generate AVIF thumbnails instead of JPEG. About 30% smaller than JPEG with modern browser support.',
    'Requires libvips with HEIF support. Takes priority over JPEG XL.',
    'Generate JPEG XL thumbnails instead of JPEG.',
    'When AVIF is also enabled, AVIF takes priority.',
);

for my $key (@reader_keys) {
    my $translated;
    my $error;
    eval { $translated = $handle->maketext($key); };
    $error = $@;

    is( $error, '', "reader key '$key' is present in English locale" );
    is( $translated, $key, "reader key '$key' falls back to English text" );
}

subtest 'batch empty-selection message resolves in every configured language' => sub {
    my $key = 'Select at least one archive.';
    my @errors;
    my $app = Mojolicious->new;
    $app->helper( LRR_CONF => sub { bless {}, 'BatchI18NConfig' } );
    $app->helper( LRR_LOGGER => sub { bless \@errors, 'BatchI18NLogger' } );
    LANraragi::Utils::I18NInitializer::initialize($app);
    for my $language (qw(as de en es zh zh-cn fr id it ja ko no nb pt zh-tw vi)) {
        my $controller = $app->build_controller;
        $controller->stash( forced_language => $language );
        my $translated = eval { $controller->lh($key) };
        is( $@, '', "$language resolves the batch initialization message" );
        my $expected = $language eq 'ko' ? '아카이브를 하나 이상 선택하세요.' : $key;
        is( $translated, $expected, "$language translates or falls back to English" );
    }
    is_deeply( \@errors, [], 'no missing English fallback produces a Maketext error' );
};

subtest 'slide settings resolve through the real helper and language fallback' => sub {
    my @errors;
    my $app = Mojolicious->new;
    $app->helper( LRR_CONF => sub { bless {}, 'BatchI18NConfig' } );
    $app->helper( LRR_LOGGER => sub { bless \@errors, 'BatchI18NLogger' } );
    LANraragi::Utils::I18NInitializer::initialize($app);
    for my $language (qw(en ko ja de)) {
        my $controller = $app->build_controller;
        $controller->stash( forced_language => $language );
        for my $key ('Sliding page transitions', 'Slide duration',
            'Click duration; touch uses this value as spring response time, not a fixed completion time. Single and double pages only.') {
            my $translated = eval { $controller->lh($key) };
            is( $@, '', "$language resolves slide setting" );
            ok( defined($translated) && length($translated), "$language supplies slide setting text" );
        }
    }
    is_deeply( \@errors, [], 'no slide setting Maketext errors' );
};

done_testing();

package BatchI18NConfig;
sub get_language { 'auto' }

package BatchI18NLogger;
sub debug { }
sub trace { }
sub error { my ( $self, $message ) = @_; push @$self, $message; }
