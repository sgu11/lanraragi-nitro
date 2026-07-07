use strict;
use warnings;
use v5.36;

use Test::More;
use Test::MockModule qw(strict);
use Cwd qw(getcwd);

my $cwd = getcwd();
require "$cwd/tests/mocks.pl";

my $module = Test::MockModule->new('LANraragi::Utils::Logging');
$module->redefine('get_logger', get_logger_mock());

use LANraragi::Utils::Vips;

if (!LANraragi::Utils::Vips::is_vips_loaded) {
    plan skip_all => "libvips is not installed";
};

use_ok('LANraragi::Utils::Vips');

note("test loading an image");
{
    my $image_path = "$cwd/tests/samples/reader.jpg";
    my $img = LANraragi::Utils::Vips::new_from_file($image_path);
    isnt($img, undef, "Should get an image");
    is(LANraragi::Utils::Vips::width($img), 2233, "Should be correct width");
    is(LANraragi::Utils::Vips::height($img), 1828, "Should be correct height");
}


note("test creating a blank image");
{
    my $img = LANraragi::Utils::Vips::black(320, 200);
    isnt($img, undef, "Should get an image");
    is(LANraragi::Utils::Vips::width($img), 320, "Should be correct width");
    is(LANraragi::Utils::Vips::height($img), 200, "Should be correct height");
}

note("test extract_grayscale_32x32 returns 1024 bytes");
{
    my $image_path = "$cwd/tests/samples/reader.jpg";
    my $pixels = LANraragi::Utils::Vips::extract_grayscale_32x32($image_path);
    is(ref($pixels), 'ARRAY', "Should return an arrayref");
    is(scalar(@$pixels), 1024, "Should have exactly 1024 pixel values");
    my @out_of_range = grep { $_ < 0 || $_ > 255 } @$pixels;
    is(scalar(@out_of_range), 0, "All pixel values should be uchar 0..255");
}

note("test GREY16 interpretation constant converts to a single band");
{
    my $image_path = "$cwd/tests/samples/reader.jpg";
    open(my $fh, '<:raw', $image_path) or die "Can't open $image_path: $!";
    my $buffer = do { local $/; <$fh> };
    close $fh;

    my $resized = LANraragi::Utils::Vips::stretch_resize($buffer, 16, 16);
    my $grey;
    my $ret = LANraragi::Utils::Vips::vips_colourspace(
        $resized,
        \$grey,
        LANraragi::Utils::Vips::VIPS_INTERPRETATION_GREY16,
        undef
    );
    LANraragi::Utils::Vips::unref_image($resized);
    is($ret, 0, "VIPS colourspace conversion succeeds");
    is(LANraragi::Utils::Vips::bands($grey), 1, "GREY16 conversion produces one band");
    LANraragi::Utils::Vips::unref_image($grey);
}

note("test reading a pdf");
{
    my $doc_path = "$cwd/tests/samples/doc.pdf";
    my $pdf = LANraragi::Utils::Vips::new_from_file($doc_path);
    is(LANraragi::Utils::Vips::get_n_pages($pdf), 4, "Should get 4 pages");
    LANraragi::Utils::Vips::unref_image($pdf);

    # 0 = first page, 3 = last (fourth) page
    my $p4 = LANraragi::Utils::Vips::pdfload_page_dpi($doc_path, 3, 72);
    is(LANraragi::Utils::Vips::width($p4), 231, "Should be 231 pixels wide in 72 DPI");
    LANraragi::Utils::Vips::unref_image($p4);

    # This test breaks on Homebrew for some reason, whether vips uses magick/gs or poppler as the PDF backend.
    # It's quite peculiar, but I'm willing to chalk this to a vips issue rather than us at this point.
    if ( $^O ne 'darwin' ) {
        $p4 = LANraragi::Utils::Vips::pdfload_page_dpi($doc_path, 3, 90);
        is(LANraragi::Utils::Vips::width($p4), 288, "Should be 288 pixels wide in 90 DPI");
        LANraragi::Utils::Vips::unref_image($p4);
    }
}

done_testing();

1;
