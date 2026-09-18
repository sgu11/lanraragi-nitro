package LANraragi::Utils::PageSideDetector;

use v5.36;
use strict;
use warnings;
use List::Util qw(max min);

# Pure pixel kernel extracted from PageSide at 56c91f1409dc. Explicit () on
# deferred Vips constants removes the old implicit application import order.
# No application config, archive acquisition, DB, cache, or human labels.
# Legacy callers stay unchanged until the worker adoption gate passes.

sub detect_page_side ( $contents, $page_index ) {
    my $decoded = _decode_page_luminance_with_vips($contents) // _decode_page_luminance_with_imagemagick($contents);

    if (!$decoded) {
        return {
            page_index => $page_index,
            side       => "UNKNOWN",
            confidence => 0,
            reason     => "decode_failed"
        };
    }

    my ( $width, $height, $pixel_at ) = @{$decoded}{qw(width height pixel_at)};
    return {
        page_index => $page_index,
        side       => "UNKNOWN",
        confidence => 0,
        reason     => "invalid_dimensions"
    } unless $width && $height;

    if ( $width >= $height * 1.20 ) {
        return {
            page_index => $page_index,
            side       => "UNKNOWN",
            confidence => 0.50,
            reason     => "wide_page"
        };
    }

    my $strip = max( 4, int( $width * 0.10 ) );
    $strip = min( $strip, int( $width / 2 ) );

    my $left_score  = _edge_score( $pixel_at, 0, $strip - 1, $height );
    my $right_score = _edge_score( $pixel_at, $width - $strip, $width - 1, $height );
    my $delta       = $right_score - $left_score;
    my $magnitude   = abs($delta);

    if ( $magnitude < 0.02 ) {
        return {
            page_index => $page_index,
            side       => "UNKNOWN",
            confidence => 0.50,
            reason     => "weak_edge_delta"
        };
    }

    return {
        page_index => $page_index,
        side       => $delta > 0 ? "RIGHT" : "LEFT",
        confidence => min( 0.95, 0.55 + ( $magnitude * 2.5 ) ),
        reason     => "edge_complexity"
    };
}

sub _decode_page_luminance_with_vips ($contents) {
    my ( $width, $height, $bands, @raw );
    eval {
        require LANraragi::Utils::Vips;
        die "libvips is not loaded\n" unless LANraragi::Utils::Vips::is_vips_loaded();
        LANraragi::Utils::Vips::init("LANraragi");

        my $resized = LANraragi::Utils::Vips::fit_resize( $contents, 320, 320 );

        my $grey;
        my $cs_ret = LANraragi::Utils::Vips::vips_colourspace(
            $resized, \$grey, LANraragi::Utils::Vips::VIPS_INTERPRETATION_B_W(), undef
        );
        LANraragi::Utils::Vips::unref_image($resized);
        die "Error converting to greyscale: " . LANraragi::Utils::Vips::fetch_and_clear_error() . "\n"
          if $cs_ret != 0;

        my $gray;
        my $cast_ret = LANraragi::Utils::Vips::vips_cast(
            $grey, \$gray, LANraragi::Utils::Vips::VIPS_FORMAT_UCHAR(), undef
        );
        LANraragi::Utils::Vips::unref_image($grey);
        die "Error casting to uchar: " . LANraragi::Utils::Vips::fetch_and_clear_error() . "\n"
          if $cast_ret != 0;

        ( $width, $height, $bands ) = (
            LANraragi::Utils::Vips::width($gray),
            LANraragi::Utils::Vips::height($gray),
            LANraragi::Utils::Vips::bands($gray)
        );
        $bands = max( 1, $bands || 1 );

        my ( $bytes, $size ) = LANraragi::Utils::Vips::read_pixels($gray);
        LANraragi::Utils::Vips::unref_image($gray);
        @raw = unpack( "C*", $bytes );

        my $expected = $width * $height * $bands;
        die "Unexpected pixel buffer size: $size (expected >= $expected)\n" if @raw < $expected;
    };
    return if $@ || !$width || !$height || !@raw;

    return {
        width    => $width,
        height   => $height,
        pixel_at => sub ( $x, $y ) {
            my $offset = ( ( $y * $width ) + $x ) * $bands;
            return ( $raw[$offset] // 255 ) / 255;
        }
    };
}

sub _decode_page_luminance_with_imagemagick ($contents) {
    my $img;
    my $frame;

    eval {
        require Image::Magick;
        $img = Image::Magick->new;
        $img->Set( option => "jpeg:size=320x320" );
        my $err = $img->BlobToImage($contents);
        die "$err\n" if $err;
        $frame = $img->[0] // $img;
        $frame->Sample( geometry => "320x320>" );
    };
    return if $@ || !$frame;

    my ( $width, $height ) = $frame->Get( "width", "height" );
    return unless $width && $height;

    return {
        width    => $width,
        height   => $height,
        pixel_at => sub ( $x, $y ) { _pixel_luminance( $frame, $x, $y ) }
    };
}

sub _edge_score ( $pixel_at, $x_start, $x_end, $height ) {
    my $x_step = max( 1, int( ( $x_end - $x_start + 1 ) / 5 ) );
    my $y_step = max( 1, int( $height / 64 ) );
    my ( $luminance_sum, $gradient_sum, $count ) = ( 0, 0, 0 );

    for ( my $x = $x_start; $x <= $x_end; $x += $x_step ) {
        my $previous;
        for ( my $y = 0; $y < $height; $y += $y_step ) {
            my $lum = $pixel_at->( $x, $y );
            $luminance_sum += $lum;
            $gradient_sum += abs( $lum - $previous ) if defined $previous;
            $previous = $lum;
            $count++;
        }
    }

    return 0 unless $count;
    my $avg_luminance = $luminance_sum / $count;
    my $darkness      = 1 - $avg_luminance;
    my $complexity    = $gradient_sum / $count;
    return $complexity + ( $darkness * 0.35 );
}

sub _pixel_luminance ( $frame, $x, $y ) {
    my @pixel = $frame->GetPixel( x => $x, y => $y );
    return 1 unless @pixel;

    my ( $r, $g, $b ) = @pixel;
    $g //= $r;
    $b //= $r;

    my $lum = ( 0.299 * $r ) + ( 0.587 * $g ) + ( 0.114 * $b );
    if ( $lum > 255 ) {
        $lum /= 65535;
    } elsif ( $lum > 1 ) {
        $lum /= 255;
    }

    return max( 0, min( 1, $lum ) );
}

1;
