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

use constant CROP_ALGORITHM_VERSION => 5;
use constant EDGE_LIGHT_BACKGROUND_MIN => 191;
use constant EDGE_DARK_BACKGROUND_MAX  => 64;
use constant EDGE_IGNORE_PIXELS     => 2;
use constant EDGE_BACKGROUND_BAND   => 4;
use constant EDGE_BACKGROUND_STEP   => 16;
use constant EDGE_LINE_SAMPLE_STEP  => 4;
use constant EDGE_BLANK_DELTA       => 40;
use constant EDGE_ALLOWED_BAD_RATIO => 0.005;
use constant EDGE_NONBLANK_RUN      => 3;
use constant EDGE_SCAN_MAX_RATIO    => 0.30;
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

sub _edge_background_mode (@channels) {
    my $luma = _channel_luma(@channels);
    return "light" if $luma >= EDGE_LIGHT_BACKGROUND_MIN;
    return "dark"  if $luma <= EDGE_DARK_BACKGROUND_MAX;
    return;
}

sub _median (@values) {
    return unless @values;
    @values = sort { $a <=> $b } @values;
    return $values[ int( @values / 2 ) ];
}

sub _channel_luma (@channels) {
    return 0 if !@channels;
    return $channels[0] if @channels < 3;
    return int( 0.299 * $channels[0] + 0.587 * $channels[1] + 0.114 * $channels[2] + 0.5 );
}

sub _channel_delta_from_background ( $channels, $background ) {
    my $visible_bands = min( scalar @$channels, scalar @$background, 3 );
    return 255 if $visible_bands <= 0;

    my $delta = 0;
    for my $index ( 0 .. $visible_bands - 1 ) {
        $delta = max( $delta, abs( $channels->[$index] - $background->[$index] ) );
    }
    return $delta;
}

sub _edge_background_channels ( $pixel_at, $orig_width, $orig_height, $side ) {
    my @samples;
    my $ignore = EDGE_IGNORE_PIXELS;
    return if $orig_width <= $ignore * 2 || $orig_height <= $ignore * 2;

    if ( $side eq "left" || $side eq "right" ) {
        my $start_x =
          $side eq "left"
          ? $ignore
          : max( $ignore, $orig_width - $ignore - EDGE_BACKGROUND_BAND );
        my $end_x =
          $side eq "left"
          ? min( $orig_width - $ignore - 1, $ignore + EDGE_BACKGROUND_BAND - 1 )
          : $orig_width - $ignore - 1;

        for my $x ( $start_x .. $end_x ) {
            for ( my $y = $ignore ; $y <= $orig_height - $ignore - 1 ; $y += EDGE_BACKGROUND_STEP ) {
                my @channels = $pixel_at->( $x, $y );
                push @samples, \@channels if @channels;
            }
        }
    } else {
        my $start_y =
          $side eq "top"
          ? $ignore
          : max( $ignore, $orig_height - $ignore - EDGE_BACKGROUND_BAND );
        my $end_y =
          $side eq "top"
          ? min( $orig_height - $ignore - 1, $ignore + EDGE_BACKGROUND_BAND - 1 )
          : $orig_height - $ignore - 1;

        for my $y ( $start_y .. $end_y ) {
            for ( my $x = $ignore ; $x <= $orig_width - $ignore - 1 ; $x += EDGE_BACKGROUND_STEP ) {
                my @channels = $pixel_at->( $x, $y );
                push @samples, \@channels if @channels;
            }
        }
    }

    return if !@samples;
    my $visible_bands = min( 3, scalar @{ $samples[0] } );
    return if $visible_bands <= 0;

    my @background;
    for my $index ( 0 .. $visible_bands - 1 ) {
        push @background, _median( map { $_->[$index] } @samples );
    }
    return @background;
}

sub _edge_line_bad_ratio ( $pixel_at, $orig_width, $orig_height, $side, $position, $background, $background_mode ) {
    my ( $bad, $total ) = ( 0, 0 );
    my $ignore = EDGE_IGNORE_PIXELS;

    if ( $side eq "left" || $side eq "right" ) {
        for ( my $y = $ignore ; $y <= $orig_height - $ignore - 1 ; $y += EDGE_LINE_SAMPLE_STEP ) {
            my @channels = $pixel_at->( $position, $y );
            if ( !@channels ) {
                $bad++;
                $total++;
                next;
            }

            my $delta = _channel_delta_from_background( \@channels, $background );
            my $luma  = _channel_luma(@channels);
            if ( $background_mode eq "dark" ) {
                $bad++ if $delta > EDGE_BLANK_DELTA || $luma >= EDGE_LIGHT_BACKGROUND_MIN;
            } else {
                $bad++ if $delta > EDGE_BLANK_DELTA || $luma <= EDGE_DARK_BACKGROUND_MAX;
            }
            $total++;
        }
    } else {
        for ( my $x = $ignore ; $x <= $orig_width - $ignore - 1 ; $x += EDGE_LINE_SAMPLE_STEP ) {
            my @channels = $pixel_at->( $x, $position );
            if ( !@channels ) {
                $bad++;
                $total++;
                next;
            }

            my $delta = _channel_delta_from_background( \@channels, $background );
            my $luma  = _channel_luma(@channels);
            if ( $background_mode eq "dark" ) {
                $bad++ if $delta > EDGE_BLANK_DELTA || $luma >= EDGE_LIGHT_BACKGROUND_MIN;
            } else {
                $bad++ if $delta > EDGE_BLANK_DELTA || $luma <= EDGE_DARK_BACKGROUND_MAX;
            }
            $total++;
        }
    }

    return 1 if !$total;
    return $bad / $total;
}

sub _edge_scan_positions ( $orig_width, $orig_height, $side ) {
    my $ignore = EDGE_IGNORE_PIXELS;
    if ( $side eq "left" ) {
        my $max_x = min( $orig_width - $ignore - 1, max( $ignore, int( $orig_width * EDGE_SCAN_MAX_RATIO ) ) );
        return ( $ignore .. $max_x );
    }
    if ( $side eq "right" ) {
        my $min_x = max( $ignore, min( $orig_width - $ignore - 1, int( $orig_width * ( 1 - EDGE_SCAN_MAX_RATIO ) ) ) );
        return reverse( $min_x .. $orig_width - $ignore - 1 );
    }
    if ( $side eq "top" ) {
        my $max_y = min( $orig_height - $ignore - 1, max( $ignore, int( $orig_height * EDGE_SCAN_MAX_RATIO ) ) );
        return ( $ignore .. $max_y );
    }

    my $min_y = max( $ignore, min( $orig_height - $ignore - 1, int( $orig_height * ( 1 - EDGE_SCAN_MAX_RATIO ) ) ) );
    return reverse( $min_y .. $orig_height - $ignore - 1 );
}

sub _detect_edge_boundary ( $pixel_at, $orig_width, $orig_height, $side ) {
    my @background = _edge_background_channels( $pixel_at, $orig_width, $orig_height, $side );
    return unless @background;
    my $background_mode = _edge_background_mode(@background);
    return unless defined $background_mode;

    my $run = 0;
    for my $position ( _edge_scan_positions( $orig_width, $orig_height, $side ) ) {
        my $bad_ratio =
          _edge_line_bad_ratio( $pixel_at, $orig_width, $orig_height, $side, $position, \@background, $background_mode );
        if ( $bad_ratio > EDGE_ALLOWED_BAD_RATIO ) {
            $run++;
            if ( $run >= EDGE_NONBLANK_RUN ) {
                return $side eq "left" || $side eq "top"
                  ? $position - $run + 1
                  : $position + $run - 1;
            }
        } else {
            $run = 0;
        }
    }

    return;
}

sub _detect_crop_bounds_from_pixels ( $pixel_at, $orig_width, $orig_height ) {
    return if !$orig_width || !$orig_height;
    return if $orig_width < EDGE_IGNORE_PIXELS * 2 + 3 || $orig_height < EDGE_IGNORE_PIXELS * 2 + 3;
    return if $orig_width > $orig_height;

    my ( $left, $top, $right, $bottom ) = ( 0, 0, $orig_width, $orig_height );

    my $left_boundary = _detect_edge_boundary( $pixel_at, $orig_width, $orig_height, "left" );
    $left = $left_boundary if defined $left_boundary && $left_boundary >= MIN_CROP_PIXELS;

    my $right_boundary = _detect_edge_boundary( $pixel_at, $orig_width, $orig_height, "right" );
    if ( defined $right_boundary && $orig_width - ( $right_boundary + 1 ) >= MIN_CROP_PIXELS ) {
        $right = $right_boundary + 1;
    }

    my $top_boundary = _detect_edge_boundary( $pixel_at, $orig_width, $orig_height, "top" );
    $top = $top_boundary if defined $top_boundary && $top_boundary >= MIN_CROP_PIXELS;

    my $bottom_boundary = _detect_edge_boundary( $pixel_at, $orig_width, $orig_height, "bottom" );
    if ( defined $bottom_boundary && $orig_height - ( $bottom_boundary + 1 ) >= MIN_CROP_PIXELS ) {
        $bottom = $bottom_boundary + 1;
    }

    return if $right <= $left || $bottom <= $top;

    my $bounds = {
        x      => int($left),
        y      => int($top),
        width  => int( $right - $left ),
        height => int( $bottom - $top ),
    };
    return unless _valid_crop_bounds( $bounds, $orig_width, $orig_height );

    return _with_safety_padding( $bounds, $orig_width, $orig_height );
}

sub _magick_pixel_channels ( $image, $x, $y ) {
    my @channels = $image->GetPixel( x => $x, y => $y );
    return if !@channels;

    # Image::Magick returns normalized channel values by default.
    return map { int( min( 1, max( 0, $_ ) ) * 255 + 0.5 ) } @channels;
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
    my $pixel_at = sub ( $x, $y ) {
        return _magick_pixel_channels( $image, $x, $y );
    };

    return _detect_crop_bounds_from_pixels( $pixel_at, $orig_width, $orig_height );
}

sub _vips_sample_to_uchar ( $pixels, $offset, $bytes_per_sample ) {
    return ord( substr( $pixels, $offset, 1 ) ) if $bytes_per_sample == 1;

    if ( $bytes_per_sample == 2 ) {
        my $value = unpack( "S<", substr( $pixels, $offset, 2 ) );
        return int( min( 255, max( 0, $value / 257 ) ) + 0.5 );
    }

    return ord( substr( $pixels, $offset, 1 ) );
}

sub _detect_crop_bounds_vips_result ($image) {
    my $orig_width  = LANraragi::Utils::Vips::width($image);
    my $orig_height = LANraragi::Utils::Vips::height($image);
    if ( !$orig_width || !$orig_height ) {
        return ( "nocrop", undef );
    }
    if ( $orig_width < EDGE_IGNORE_PIXELS * 2 + 3 || $orig_height < EDGE_IGNORE_PIXELS * 2 + 3 ) {
        return ( "nocrop", undef );
    }

    my $bands = LANraragi::Utils::Vips::bands($image);
    if ( !$bands ) {
        return ( "fallback", undef );
    }

    my $pixels = eval {
        my ($bytes) = LANraragi::Utils::Vips::read_pixels($image);
        $bytes;
    };
    if ( $@ || !defined $pixels || $pixels eq "" ) {
        return ( "fallback", undef );
    }

    my $pixel_count = $orig_width * $orig_height * $bands;
    return ( "fallback", undef ) if $pixel_count <= 0 || length($pixels) % $pixel_count != 0;
    my $bytes_per_sample = int( length($pixels) / $pixel_count );
    return ( "fallback", undef ) if $bytes_per_sample <= 0;

    my $pixel_at = sub ( $x, $y ) {
        return if $x < 0 || $y < 0 || $x >= $orig_width || $y >= $orig_height;
        my $offset = ( ( ( $y * $orig_width ) + $x ) * $bands ) * $bytes_per_sample;
        return if $offset < 0 || $offset + ( $bands * $bytes_per_sample ) > length($pixels);
        return map { _vips_sample_to_uchar( $pixels, $offset + ( $_ * $bytes_per_sample ), $bytes_per_sample ) } ( 0 .. $bands - 1 );
    };

    my $bounds = _detect_crop_bounds_from_pixels( $pixel_at, $orig_width, $orig_height );
    return ( "nocrop", undef ) unless $bounds;

    return ( "crop", $bounds );
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
