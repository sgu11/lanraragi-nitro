package LANraragi::Utils::ImageBorderCrop;

use v5.36;

use strict;
use warnings;
use utf8;

use List::Util qw(max min);
use LANraragi::Utils::Logging qw(get_logger);

use Exporter 'import';
our @EXPORT_OK = qw(CROP_ALGORITHM_VERSION crop_blank_borders detect_crop_bounds);

use constant CROP_ALGORITHM_VERSION => 1;
use constant TRIM_FUZZ_PERCENT      => 8;
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

    my $cropped_left   = $bounds->{x};
    my $cropped_top    = $bounds->{y};
    my $cropped_right  = $orig_width - ( $bounds->{x} + $bounds->{width} );
    my $cropped_bottom = $orig_height - ( $bounds->{y} + $bounds->{height} );
    return
      if $cropped_left < MIN_CROP_PIXELS
      && $cropped_top < MIN_CROP_PIXELS
      && $cropped_right < MIN_CROP_PIXELS
      && $cropped_bottom < MIN_CROP_PIXELS;

    return if $bounds->{width} / $orig_width < MIN_RETAIN_RATIO;
    return if $bounds->{height} / $orig_height < MIN_RETAIN_RATIO;

    return _with_safety_padding( $bounds, $orig_width, $orig_height );
}

sub crop_blank_borders ( $content, $format = "jpg" ) {
    no warnings 'experimental::try';

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
