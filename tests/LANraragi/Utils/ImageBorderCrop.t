use strict;
use warnings;
use utf8;
use v5.36;

use Test::More;
our $IM_LOAD_OK;
END { $? = 0 if !$IM_LOAD_OK }
BEGIN {
    eval { require Image::Magick; 1 }
        or plan skip_all => "Image::Magick is not available: $@";
    $IM_LOAD_OK = 1;
}
use LANraragi::Utils::Vips;

my $loaded = eval { require LANraragi::Utils::ImageBorderCrop; 1 };
ok( $loaded, "ImageBorderCrop module loads" );
if ( !$loaded ) {
    diag($@);
    done_testing();
    exit;
}

is( LANraragi::Utils::ImageBorderCrop::CROP_ALGORITHM_VERSION(), 6, "crop cache version bumps after area-only crop policy change" );

sub make_image_blob ( $width, $height, $background, $rect = undef, $content = "black" ) {
    my $img = Image::Magick->new( size => "${width}x${height}" );
    $img->Read("xc:$background");
    if ($rect) {
        my ( $x, $y, $w, $h ) = @$rect;
        $img->Draw(
            primitive => "rectangle",
            points    => "$x,$y " . ( $x + $w - 1 ) . "," . ( $y + $h - 1 ),
            fill      => $content,
        );
    }
    return $img->ImageToBlob( magick => "png" );
}

sub make_one_sided_noisy_left_strip_blob {
    my $img = Image::Magick->new( size => "220x320" );
    $img->Read("xc:#f8f8f8");
    $img->Draw(
        primitive => "rectangle",
        points    => "44,0 219,319",
        fill      => "#222222",
    );
    for my $y ( 0 .. 319 ) {
        next if $y % 23;
        $img->SetPixel( x => 0, y => $y, color => [ 0.78, 0.78, 0.78 ] );
        $img->SetPixel( x => 1, y => $y, color => [ 0.83, 0.83, 0.83 ] );
    }
    return $img->ImageToBlob( magick => "png" );
}

sub blob_dimensions ($blob) {
    my $img = Image::Magick->new;
    $img->BlobToImage($blob);
    return ( $img->Get("width"), $img->Get("height") );
}

note("off-white blank borders are cropped with a small safety padding");
{
    my $blob = make_image_blob( 100, 100, "#f8f8f8", [ 12, 10, 76, 82 ], "#222222" );
    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders( $blob, "png" );
    ok( defined $cropped, "cropped bytes are returned" );
    my ( $w, $h ) = blob_dimensions($cropped);
    is( $w, 80, "crop keeps horizontal safety padding" );
    is( $h, 86, "crop keeps vertical safety padding" );
}

note("one-sided noisy light strips are cropped without requiring all corners to be light");
{
    my $blob = make_one_sided_noisy_left_strip_blob();
    my $bounds = LANraragi::Utils::ImageBorderCrop::detect_crop_bounds($blob);
    is_deeply(
        $bounds,
        {
            x      => 42,
            y      => 0,
            width  => 178,
            height => 320,
        },
        "ImageMagick fallback detects the left-only strip after ignoring edge noise"
    );

    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders( $blob, "png" );
    ok( defined $cropped, "cropped bytes are returned for the left-only strip" );
    my ( $w, $h ) = blob_dimensions($cropped);
    is( $w, 178, "crop removes only the left light strip with safety padding" );
    is( $h, 320, "crop keeps full height when top and bottom are not blank strips" );
}

note("small borders are ignored to avoid wasteful re-encoding");
{
    my $blob = make_image_blob( 100, 100, "white", [ 3, 3, 94, 94 ], "black" );
    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders( $blob, "png" );
    is( $cropped, undef, "crop returns undef when margins are below the threshold" );
}

note("all-blank images are not cropped");
{
    my $blob = make_image_blob( 100, 100, "white" );
    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders( $blob, "png" );
    is( $cropped, undef, "crop returns undef when no content is found" );
}

note("dark scan borders are cropped like Komikku-style black edge detection");
{
    my $blob = make_image_blob( 120, 160, "#101010", [ 15, 12, 90, 132 ], "#e6e6e6" );
    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders( $blob, "png" );
    ok( defined $cropped, "dark-border page returns cropped bytes" );
    my ( $w, $h ) = blob_dimensions($cropped);
    is( $w, 94, "dark-border crop keeps horizontal safety padding" );
    is( $h, 136, "dark-border crop keeps vertical safety padding" );
}

note("color interiors with uniform light borders are cropped");
{
    my $blob = make_image_blob( 120, 160, "#f8f8f8", [ 14, 12, 92, 132 ], "#bb4433" );
    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders( $blob, "png" );
    ok( defined $cropped, "color interior page returns cropped bytes" );
    my ( $w, $h ) = blob_dimensions($cropped);
    is( $w, 96, "color page crop keeps horizontal safety padding" );
    is( $h, 136, "color page crop keeps vertical safety padding" );
}

note("landscape joined spread pages are skipped");
{
    my $blob = make_image_blob( 160, 90, "#f8f8f8", [ 18, 10, 124, 70 ], "#222222" );
    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders( $blob, "png" );
    is( $cropped, undef, "landscape joined spread returns nocrop" );
}

SKIP: {
    skip "libvips is not installed", 7 unless LANraragi::Utils::Vips::is_vips_loaded();

    my $blob = make_image_blob( 100, 100, "#f8f8f8", [ 12, 10, 76, 82 ], "#222222" );
    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders_vips( $blob, "png" );
    ok( defined $cropped, "libvips crop path returns bytes" );
    my ( $w, $h ) = blob_dimensions($cropped);
    is( $w, 80, "libvips crop keeps horizontal safety padding" );
    is( $h, 86, "libvips crop keeps vertical safety padding" );

    my $left_strip = make_one_sided_noisy_left_strip_blob();
    my $left_cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders_vips( $left_strip, "png" );
    ok( defined $left_cropped, "libvips crop path handles one-sided noisy light strips" );
    ( $w, $h ) = blob_dimensions($left_cropped);
    is( $w, 178, "libvips crop removes only the left light strip with safety padding" );
    is( $h, 320, "libvips crop keeps full height for one-sided left strip" );
}

done_testing();
