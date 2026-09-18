package LANraragi::Utils::ImageTransform;

use v5.36;
use strict;
use warnings;
use Time::HiRes qw(gettimeofday tv_interval);
use LANraragi::Utils::ImageBorderCrop qw(CROP_ALGORITHM_VERSION crop_blank_borders);
use LANraragi::Utils::PageCache qw(fetch put);
use LANraragi::Utils::Vips ();
use Exporter qw(import);
our @EXPORT_OK = qw(_crop_cache_key _crop_resize_cache_key _crop_nocrop_cache_key _apply_border_crop);
use constant CROP_MIN_AREA_SAVINGS_RATIO => 0.05;

sub _crop_cache_key ( $id, $path, $format ) {
    return "crop_page/v" . CROP_ALGORITHM_VERSION . "/$id/$path/$format";
}

sub _crop_resize_cache_key ( $id, $path, $threshold, $quality ) {
    return "crop_resize_page/v" . CROP_ALGORITHM_VERSION . "/$id/$path/$threshold/$quality";
}

sub _crop_nocrop_cache_key ( $id, $path ) {
    return "crop_page_nocrop/v" . CROP_ALGORITHM_VERSION . "/$id/$path";
}

sub _image_dimensions_from_blob ($content) {
    return unless defined $content && length($content);

    my ( $vips_width, $vips_height ) = _image_dimensions_from_blob_vips($content);
    return ( $vips_width, $vips_height ) if $vips_width && $vips_height;

    # Wrap the entire PerlMagick probe: a broken Image::Magick install can
    # die at ->new, BlobToImage, or Get (e.g. missing dylib), not only at
    # require. Any of those failures must fall through to "no dimensions".
    my ( $width, $height ) = eval {
        require Image::Magick;
        my $image = Image::Magick->new;
        return unless $image;
        return if $image->BlobToImage($content);
        $image->Get( "width", "height" );
    };
    return unless $width && $height;
    return ( $width, $height );
}

sub _image_dimensions_from_blob_vips ($content) {
    return unless LANraragi::Utils::Vips::is_vips_loaded();

    my ( $width, $height );
    my $image;
    my $ok = eval {
        LANraragi::Utils::Vips::init("LANraragi");
        $image  = LANraragi::Utils::Vips::new_from_buffer($content);
        $width  = LANraragi::Utils::Vips::width($image);
        $height = LANraragi::Utils::Vips::height($image);
        1;
    };

    eval { LANraragi::Utils::Vips::unref_image($image) if $image; 1 };
    return if !$ok || $@ || !$width || !$height;
    return ( $width, $height );
}

sub _crop_area_savings_ratio ( $content, $cropped ) {
    my ( $original_width, $original_height ) = _image_dimensions_from_blob($content);
    my ( $cropped_width,  $cropped_height )  = _image_dimensions_from_blob($cropped);
    return 0 unless $original_width && $original_height && $cropped_width && $cropped_height;

    my $original_area = $original_width * $original_height;
    my $cropped_area  = $cropped_width * $cropped_height;
    return 0 if $original_area <= 0 || $cropped_area >= $original_area;

    return 1 - ( $cropped_area / $original_area );
}

sub _apply_border_crop ( $id, $path, $format, $content, $metrics = undef, $generation = undef ) {
    my $nocrop_key = _crop_nocrop_cache_key( $id, $path );
    if ( defined fetch($nocrop_key, $generation) ) {
        $metrics->{cache_status} = "nocrop" if defined $metrics;
        return ( $content, 0 );
    }

    my $crop_start = [gettimeofday];
    my $cropped = crop_blank_borders( $content, $format );
    $metrics->{crop_seconds} = tv_interval($crop_start) if defined $metrics;

    if ( defined $cropped && length($cropped) ) {
        # Time the dimension-probe separately from the detector so the Phase 0
        # metrics can tell detector cost (crop_blank_borders) from the
        # _crop_area_savings_ratio double-decode cost (CROP-3). Today this is
        # two full-resolution libvips decodes just to read width/height.
        my $dims_start = [gettimeofday];
        my $area_savings = _crop_area_savings_ratio( $content, $cropped );
        $metrics->{crop_dims_seconds} = tv_interval($dims_start) if defined $metrics;
        if ( $area_savings < CROP_MIN_AREA_SAVINGS_RATIO ) {
            put( $nocrop_key, "1", $generation );
            $metrics->{cache_status} = "nocrop_area" if defined $metrics;
            return ( $content, 0 );
        }
        return ( $cropped, 1 );
    }

    put( $nocrop_key, "1", $generation );
    $metrics->{cache_status} = "nocrop" if defined $metrics;
    return ( $content, 0 );
}

1;
