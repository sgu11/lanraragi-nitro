use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi::Utils::I18N;

my $handle = LANraragi::Utils::I18N->get_handle('en');
my @reader_keys = (
    'F or Middle-click: toggle fullscreen mode',
    'Adaptive Offset',
    'Cover and wide pages stay single. Press J to toggle.',
    'On',
    'Off',
);

for my $key (@reader_keys) {
    my $translated;
    my $error;
    eval { $translated = $handle->maketext($key); };
    $error = $@;

    is( $error, '', "reader key '$key' is present in English locale" );
    is( $translated, $key, "reader key '$key' falls back to English text" );
}

done_testing();
