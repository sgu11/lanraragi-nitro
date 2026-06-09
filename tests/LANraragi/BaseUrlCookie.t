use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi;

my $helper;
{
    no strict 'refs';
    $helper = *{"LANraragi::is_baseurl_cookie_exempt"}{CODE};
}

ok( $helper, "LANraragi exposes base URL cookie exemption logic" );

SKIP: {
    skip "base URL cookie exemption helper is not implemented yet", 6 unless $helper;

    ok( $helper->("/css/index.css"), "CSS assets are exempt" );
    ok( $helper->("/img/noThumb.png"), "image assets are exempt" );
    ok( $helper->("/api/archives/abcdef0123456789abcdef0123456789abcdef01/thumbnail"), "archive thumbnails are exempt" );
    ok( $helper->("/api/tankoubons/TANK_1234567890/thumbnail"), "tank thumbnails are exempt" );
    ok( $helper->("/api/archives/abcdef0123456789abcdef0123456789abcdef01/page"), "archive page images are exempt" );
    ok( !$helper->("/api/archives"), "page-level API responses still receive the base URL cookie" );
}

done_testing();
