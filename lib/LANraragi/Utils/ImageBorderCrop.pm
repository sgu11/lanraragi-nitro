package LANraragi::Utils::ImageBorderCrop;

use v5.36;

use strict;
use warnings;
use utf8;

use List::Util qw(max min);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Vips ();

use Exporter 'import';
our @EXPORT_OK = qw(CROP_ALGORITHM_VERSION crop_blank_borders crop_blank_borders_vips detect_crop_bounds);

use constant CROP_ALGORITHM_VERSION => 2;
use constant TRIM_FUZZ_PERCENT      => 8;
use constant VIPS_TRIM_THRESHOLD    => int( 255 * TRIM_FUZZ_PERCENT / 100 );
use constant VIPS_LIGHT_BACKGROUND  => 224;
use constant MIN_CROP_PIXELS        => 5;
use constant MIN_RETAIN_RATIO       => 0.20;
use constant SAFETY_PADDING_PIXELS  => 2;

sub _debug ($message) {
    eval { get_logger( "ImageBorderCrop", "lanraragi" )->debug($message); 1 };
    return;
}

sub _normalize_format ($format) {
    $format //= "jpg";
    $format =~ s/^\.//;
    $format = "jpg" if $format eq "jpeg";
    return lc $format;
}

sub _decode_first_frame ($content) {
    my $img = Image::Magick->new;
    my $err = $img->BlobToImage($content);
    if ($err) {
        _debug("Image decode failed while detecting crop bounds: $err");
        return;
    }
    return $img->[0] // $img;
}

sub _trimmed_bounds ( $image, $orig_width, $orig_height ) {
    my $trimmed = $image->Clone;
    my $err = $trimmed->Trim( fuzz => TRIM_FUZZ_PERCENT . "%" );
    if ($err) {
        _debug("Image trim failed while detecting crop bounds: $err");
        return;
    }

    my ( $trim_width, $trim_height ) = $trimmed->Get( "width", "height" );
    my $page = $trimmed->Get("page") // "";
    return unless $page =~ /^\d+x\d+([+-]\d+)([+-]\d+)$/;

    my ( $x, $y ) = ( int($1), int($2) );
    return if $x < 0 || $y < 0;
    return if $trim_width <= 0 || $trim_height <= 0;
    return if $x + $trim_width > $orig_width || $y + $trim_height > $orig_height;

    return {
        x      => $x,
        y      => $y,
        width  => int($trim_width),
        height => int($trim_height),
    };
}

sub _with_safety_padding ( $bounds, $orig_width, $orig_height ) {
    my $left   = max( 0, $bounds->{x} - SAFETY_PADDING_PIXELS );
    my $top    = max( 0, $bounds->{y} - SAFETY_PADDING_PIXELS );
    my $right  = min( $orig_width,  $bounds->{x} + $bounds->{width} + SAFETY_PADDING_PIXELS );
    my $bottom = min( $orig_height, $bounds->{y} + $bounds->{height} + SAFETY_PADDING_PIXELS );

    return {
        x      => $left,
        y      => $top,
        width  => $right - $left,
        height => $bottom - $top,
    };
}

sub _valid_crop_bounds ( $bounds, $orig_width, $orig_height ) {
    return 0 unless $bounds;

    my $cropped_left   = $bounds->{x};
    my $cropped_top    = $bounds->{y};
    my $cropped_right  = $orig_width - ( $bounds->{x} + $bounds->{width} );
    my $cropped_bottom = $orig_height - ( $bounds->{y} + $bounds->{height} );
    return 0
      if $cropped_left < MIN_CROP_PIXELS
      && $cropped_top < MIN_CROP_PIXELS
      && $cropped_right < MIN_CROP_PIXELS
      && $cropped_bottom < MIN_CROP_PIXELS;

    return 0 if $bounds->{width} / $orig_width < MIN_RETAIN_RATIO;
    return 0 if $bounds->{height} / $orig_height < MIN_RETAIN_RATIO;

    return 1;
}

sub detect_crop_bounds ($content) {
    no warnings 'experimental::try';

    my $image = eval {
        require Image::Magick;
        _decode_first_frame($content);
    };
    return if !$image || $@;

    my ( $orig_width, $orig_height ) = $image->Get( "width", "height" );
    return if !$orig_width || !$orig_height;

    my $bounds = _trimmed_bounds( $image, $orig_width, $orig_height );
    return unless $bounds;

    return unless _valid_crop_bounds( $bounds, $orig_width, $orig_height );

    return _with_safety_padding( $bounds, $orig_width, $orig_height );
}

sub _vips_background_looks_light ($image) {
    my $sample;
    my $pixel = eval {
        $sample = LANraragi::Utils::Vips::extract_area( $image, 0, 0, 1, 1 );
        my ($bytes) = LANraragi::Utils::Vips::read_pixels($sample);
        $bytes;
    };
    my $error = $@;
    eval { LANraragi::Utils::Vips::unref_image($sample) if $sample; 1 };
    return 1 if $error || !defined $pixel || $pixel eq "";

    my @channels = unpack( "C*", $pixel );
    my $bands = max( 1, LANraragi::Utils::Vips::bands($image) );
    my $visible_bands = min( 3, $bands, scalar @channels );
    return 1 if $visible_bands <= 0;

    for my $index ( 0 .. $visible_bands - 1 ) {
        return 0 if $channels[$index] < VIPS_LIGHT_BACKGROUND;
    }

    return 1;
}

sub _detect_crop_bounds_vips_result ($image) {
    my $orig_width  = LANraragi::Utils::Vips::width($image);
    my $orig_height = LANraragi::Utils::Vips::height($image);
    return ( "nocrop", undef ) if !$orig_width || !$orig_height;
    return ( "nocrop", undef ) if $orig_width < 3 || $orig_height < 3;
    return ( "fallback", undef ) unless _vips_background_looks_light($image);

    my ( $x, $y, $width, $height ) = LANraragi::Utils::Vips::find_trim( $image, VIPS_TRIM_THRESHOLD );
    return ( "nocrop", undef ) if $width <= 0 || $height <= 0;
    return ( "fallback", undef ) if $x < 0 || $y < 0;
    return ( "fallback", undef ) if $x + $width > $orig_width || $y + $height > $orig_height;

    my $bounds = {
        x      => int($x),
        y      => int($y),
        width  => int($width),
        height => int($height),
    };
    return ( "nocrop", undef ) unless _valid_crop_bounds( $bounds, $orig_width, $orig_height );

    return ( "crop", _with_safety_padding( $bounds, $orig_width, $orig_height ) );
}

sub _crop_blank_borders_vips_result ( $content, $format = "jpg" ) {
    no warnings 'experimental::try';

    return ( "fallback", undef ) unless LANraragi::Utils::Vips::is_vips_loaded();

    my $status = "fallback";
    my $cropped;
    my $image;
    my $cropped_image;
    my $ok = eval {
        LANraragi::Utils::Vips::init("LANraragi");
        $image = LANraragi::Utils::Vips::new_from_buffer($content);
        my $bounds;
        ( $status, $bounds ) = _detect_crop_bounds_vips_result($image);
        if ( $status eq "crop" ) {
            $cropped_image = LANraragi::Utils::Vips::crop(
                $image,
                $bounds->{x},
                $bounds->{y},
                $bounds->{width},
                $bounds->{height}
            );
            $cropped = LANraragi::Utils::Vips::write_to_buffer( $cropped_image, "." . _normalize_format($format), 95 );
        }
        1;
    };
    my $error = $@;

    eval { LANraragi::Utils::Vips::unref_image($cropped_image) if $cropped_image; 1 };
    eval { LANraragi::Utils::Vips::unref_image($image) if $image; 1 };

    if ( !$ok || $error ) {
        _debug("libvips border crop failed: $error");
        return ( "fallback", undef );
    }

    return ( $status, $cropped );
}

sub crop_blank_borders_vips ( $content, $format = "jpg" ) {
    my ( $status, $cropped ) = _crop_blank_borders_vips_result( $content, $format );
    return $cropped if $status eq "crop";
    return;
}

sub crop_blank_borders ( $content, $format = "jpg" ) {
    no warnings 'experimental::try';

    my ( $vips_status, $vips_cropped ) = _crop_blank_borders_vips_result( $content, $format );
    return $vips_cropped if $vips_status eq "crop";
    return if $vips_status eq "nocrop";

    my $bounds = detect_crop_bounds($content);
    return unless $bounds;

    my $cropped = eval {
        require Image::Magick;
        my $image = _decode_first_frame($content);
        return unless $image;

        my $geometry = sprintf(
            "%dx%d+%d+%d",
            $bounds->{width},
            $bounds->{height},
            $bounds->{x},
            $bounds->{y}
        );
        my $err = $image->Crop( geometry => $geometry );
        die "$err\n" if $err;
        $image->Set( page => sprintf( "%dx%d+0+0", $bounds->{width}, $bounds->{height} ) );
        $image->ImageToBlob( magick => _normalize_format($format), quality => 95 );
    };

    if ($@) {
        _debug("Image crop failed: $@");
        return;
    }

    return $cropped;
}

1;
