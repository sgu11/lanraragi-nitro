use strict;
use warnings;
use utf8;
use v5.36;

use Test::More;
use Image::Magick;
use LANraragi::Utils::Vips;

my $loaded = eval { require LANraragi::Utils::ImageBorderCrop; 1 };
ok( $loaded, "ImageBorderCrop module loads" );
if ( !$loaded ) {
    diag($@);
    done_testing();
    exit;
}

is( LANraragi::Utils::ImageBorderCrop::CROP_ALGORITHM_VERSION(), 3, "crop cache version bumps for light-border-only eligibility" );

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

note("dark scan borders are skipped instead of cropped");
{
    my $blob = make_image_blob( 120, 80, "#101010", [ 15, 8, 90, 64 ], "#e6e6e6" );
    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders( $blob, "png" );
    is( $cropped, undef, "dark-border page returns nocrop" );
}

note("color pages are skipped even with light borders");
{
    my $blob = make_image_blob( 120, 160, "#f8f8f8", [ 14, 12, 92, 132 ], "#bb4433" );
    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders( $blob, "png" );
    is( $cropped, undef, "color page returns nocrop" );
}

note("landscape joined spread pages are skipped");
{
    my $blob = make_image_blob( 160, 90, "#f8f8f8", [ 18, 10, 124, 70 ], "#222222" );
    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders( $blob, "png" );
    is( $cropped, undef, "landscape joined spread returns nocrop" );
}

SKIP: {
    skip "libvips is not installed", 3 unless LANraragi::Utils::Vips::is_vips_loaded();

    my $blob = make_image_blob( 100, 100, "#f8f8f8", [ 12, 10, 76, 82 ], "#222222" );
    my $cropped = LANraragi::Utils::ImageBorderCrop::crop_blank_borders_vips( $blob, "png" );
    ok( defined $cropped, "libvips crop path returns bytes" );
    my ( $w, $h ) = blob_dimensions($cropped);
    is( $w, 80, "libvips crop keeps horizontal safety padding" );
    is( $h, 86, "libvips crop keeps vertical safety padding" );
}

done_testing();
