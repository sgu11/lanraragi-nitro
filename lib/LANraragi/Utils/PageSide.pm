package LANraragi::Utils::PageSide;

use strict;
use warnings;
use utf8;
use feature qw(signatures);
no warnings 'experimental::signatures';

use List::Util qw(max min);

use LANraragi::Model::Config;
use LANraragi::Utils::Archive  qw(extract_single_file get_filelist);
use LANraragi::Utils::Database qw(all_archive_ids);
use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::Path     qw(date_modified get_archive_path);

use Exporter 'import';
our @EXPORT_OK = qw(
  FIRST_PAGE_SIDE_VERSION
  FIRST_SPREAD_START_VERSION
  choose_first_page_side
  choose_first_spread_start
  clear_first_spread_start_detection
  detect_and_store_first_page_side
  detect_and_store_first_spread_start
  detect_recent_first_page_sides
  detect_recent_first_spread_starts
  enqueue_first_page_side_detection
  enqueue_first_spread_start_detection
  recent_archive_ids
);

use constant FIRST_PAGE_SIDE_VERSION   => 1;
use constant FIRST_SPREAD_START_VERSION => 3;
use constant MIN_SAMPLE_CONFIDENCE     => 0.55;
use constant MIN_VOTE_GAP              => 0.35;
use constant MIN_CONFIDENT_SAMPLES     => 2;

sub _optional_positive_limit ($requested) {
    return unless defined $requested;
    my $limit = int($requested);
    return $limit > 0 ? $limit : undef;
}

sub _normalize_side ($side) {
    return unless defined $side;
    $side = uc($side);
    return $side if $side eq "LEFT" || $side eq "RIGHT" || $side eq "UNKNOWN";
    return;
}

sub _opposite_side ($side) {
    return $side eq "LEFT" ? "RIGHT" : "LEFT";
}

sub _project_first_page_side ($page_index, $side) {
    return $page_index % 2 == 0 ? $side : _opposite_side($side);
}

sub _project_first_spread_start ( $page_index, $side ) {
    my $page_number = $page_index + 1;
    my $is_odd_page = $page_number % 2 == 1;
    return $is_odd_page
      ? ( $side eq "LEFT" ? 2 : 4 )
      : ( $side eq "RIGHT" ? 2 : 4 );
}

sub choose_first_spread_start ($samples) {
    my @samples = grep { ref $_ eq "HASH" } @{ $samples // [] };

    my %votes = ( 2 => 0, 4 => 0 );
    my $count = 0;
    for my $sample (@samples) {
        my $page_index = $sample->{page_index} // 0;
        next if $page_index < 2;    # Ignore cover and page 2/title-page signals.

        my $side = _normalize_side( $sample->{side} );
        next unless ( $side // "" ) =~ /^(?:LEFT|RIGHT)$/;

        my $confidence = $sample->{confidence} // 0;
        next unless $confidence >= MIN_SAMPLE_CONFIDENCE;

        my $spread_start = _project_first_spread_start( $page_index, $side );
        $votes{$spread_start} += $confidence;
        $count++;
    }

    return {
        first_spread_start => "UNKNOWN",
        confidence         => 0,
        reason             => "not_enough_confident_samples"
    } if $count < MIN_CONFIDENT_SAMPLES;

    my ( $winner, $runner_up ) = $votes{2} >= $votes{4} ? ( 2, 4 ) : ( 4, 2 );

    if ( $votes{$winner} - $votes{$runner_up} < MIN_VOTE_GAP ) {
        return {
            first_spread_start => "UNKNOWN",
            confidence         => 0,
            reason             => "ambiguous_sample_vote"
        };
    }

    my $total = $votes{2} + $votes{4};
    return {
        first_spread_start => $winner,
        confidence         => $total ? $votes{$winner} / $total : 0,
        reason             => "sample_vote:$count"
    };
}

sub choose_first_page_side ($samples) {
    my @samples = grep { ref $_ eq "HASH" } @{ $samples // [] };

    if (@samples) {
        my $first = $samples[0];
        my $side  = _normalize_side( $first->{side} );
        my $conf  = $first->{confidence} // 0;
        if ( ( $first->{page_index} // 0 ) == 0
            && ( $side // "" ) =~ /^(?:LEFT|RIGHT)$/
            && $conf >= MIN_SAMPLE_CONFIDENCE ) {
            return {
                side       => $side,
                confidence => $conf + 0,
                reason     => $first->{reason} // "first_page"
            };
        }
    }

    my %votes = ( LEFT => 0, RIGHT => 0 );
    my $count = 0;
    for my $sample (@samples) {
        my $side = _normalize_side( $sample->{side} );
        next unless ( $side // "" ) =~ /^(?:LEFT|RIGHT)$/;

        my $confidence = $sample->{confidence} // 0;
        next unless $confidence >= MIN_SAMPLE_CONFIDENCE;

        my $first_side = _project_first_page_side( $sample->{page_index} // 0, $side );
        $votes{$first_side} += $confidence;
        $count++;
    }

    return {
        side       => "UNKNOWN",
        confidence => 0,
        reason     => "no_confident_samples"
    } unless $count;

    my ( $winner, $runner_up ) =
      $votes{LEFT} >= $votes{RIGHT}
      ? ( "LEFT", "RIGHT" )
      : ( "RIGHT", "LEFT" );

    if ( $votes{$winner} - $votes{$runner_up} < MIN_VOTE_GAP ) {
        return {
            side       => "UNKNOWN",
            confidence => 0,
            reason     => "ambiguous_sample_vote"
        };
    }

    my $total = $votes{LEFT} + $votes{RIGHT};
    return {
        side       => $winner,
        confidence => $total ? $votes{$winner} / $total : 0,
        reason     => "sample_vote:$count"
    };
}

sub recent_archive_ids ( $redis, $requested_limit = undef ) {
    my $limit = _optional_positive_limit($requested_limit);
    my @ids   = all_archive_ids($redis);

    my %mtime;
    for my $id (@ids) {
        my $file = eval { get_archive_path( $redis, $id ) };
        next unless defined $file && -e $file;
        $mtime{$id} = date_modified($file) // 0;
    }

    my @sorted = sort {
        $mtime{$b} <=> $mtime{$a}
          || $b cmp $a
    } keys %mtime;

    return @sorted unless defined $limit;
    return @sorted[ 0 .. min( $#sorted, $limit - 1 ) ] if @sorted;
    return;
}

sub enqueue_first_spread_start_detection ($id) {
    return unless $id;
    LANraragi::Model::Config->get_minion->enqueue(
        detect_first_spread_start => [$id] => { priority => 0 }
    );
}

sub enqueue_first_page_side_detection ($id) {
    return enqueue_first_spread_start_detection($id);
}

sub detect_recent_first_spread_starts ( $job, $requested_limit = undef ) {
    my $limit  = _optional_positive_limit($requested_limit);
    my $logger = get_logger( "Minion", "minion" );
    my $redis  = LANraragi::Model::Config->get_redis;
    my @ids    = recent_archive_ids( $redis, $limit );
    $redis->quit;

    my $processed = 0;
    my @errors;
    my $limit_label = defined $limit ? $limit : "all";
    $logger->info("detect_recent_first_spread_starts: processing " . scalar(@ids) . " archives (limit=$limit_label)");

    for my $id (@ids) {
        eval { detect_and_store_first_spread_start($id); };
        if ($@) {
            push @errors, "$id: $@";
            $logger->warn("detect_recent_first_spread_starts failed for $id: $@");
        }
        $processed++;
        $job->note( processed => $processed, total => scalar(@ids), id => $id ) if $job;
    }

    return {
        processed => $processed,
        limit     => $limit,
        errors    => \@errors
    };
}

sub detect_recent_first_page_sides ( $job, $requested_limit = undef ) {
    return detect_recent_first_spread_starts( $job, $requested_limit );
}

sub detect_and_store_first_spread_start ($id) {
    my $logger = get_logger( "PageSide", "lanraragi" );
    my $redis  = LANraragi::Model::Config->get_redis;

    my $result;
    eval {
        my $current_v     = $redis->hget( $id, "firstspreadstart_v" ) // "";
        my $current_start = $redis->hget( $id, "firstspreadstart" )   // "";
        if ( $current_v eq FIRST_SPREAD_START_VERSION && $current_start ne "" ) {
            $result = {
                first_spread_start => $current_start,
                confidence         => $redis->hget( $id, "firstspreadstart_confidence" ) // 0,
                reason             => $redis->hget( $id, "firstspreadstart_reason" )     // "cached",
                cached             => 1
            };
        } else {
            my $file = get_archive_path( $redis, $id );
            die "Archive file does not exist for $id\n" unless defined $file && -e $file;

            my @filelist = get_filelist( $file, $id );
            die "Archive has no readable image pages: $id\n" unless @filelist;

            my @samples;
            my $last = min( $#filelist, 9 );
            for my $page_index ( 2 .. $last ) {
                my $contents = extract_single_file( $file, $filelist[$page_index] );
                next unless defined $contents && length $contents;
                push @samples, detect_page_side( $contents, $page_index );
            }

            $result = choose_first_spread_start( \@samples );
        }
    };

    if ($@) {
        chomp( my $err = "$@" );
        $logger->warn("First spread-start detection failed for $id: $err");
        $result = {
            first_spread_start => "UNKNOWN",
            confidence         => 0,
            reason             => "error",
            error              => $err
        };
    }

    _store_first_spread_start( $redis, $id, $result );
    $redis->quit;
    return $result;
}

sub detect_and_store_first_page_side ($id) {
    return detect_and_store_first_spread_start($id);
}

sub _normalize_first_spread_start ($start) {
    return unless defined $start;
    return "$start" if $start eq "2" || $start eq "4" || $start eq "UNKNOWN";
    return "4" if $start eq "3";
    return;
}

sub clear_first_spread_start_detection ( $redis, $id ) {
    return unless $redis && $id;
    $redis->hdel(
        $id,
        qw(
          firstspreadstart firstspreadstart_confidence firstspreadstart_reason firstspreadstart_v firstspreadstart_err
          firstpageside firstpageside_confidence firstpageside_reason firstpageside_v firstpageside_err
        )
    );
}

sub _store_first_spread_start ( $redis, $id, $result ) {
    my $spread_start = _normalize_first_spread_start( $result->{first_spread_start} ) // "UNKNOWN";
    $redis->hset( $id, "firstspreadstart",            $spread_start );
    $redis->hset( $id, "firstspreadstart_confidence", $result->{confidence} // 0 );
    $redis->hset( $id, "firstspreadstart_reason",     $result->{reason}     // "" );
    $redis->hset( $id, "firstspreadstart_v",          FIRST_SPREAD_START_VERSION );

    if ( defined $result->{error} && $result->{error} ne "" ) {
        $redis->hset( $id, "firstspreadstart_err", $result->{error} );
    } else {
        $redis->hdel( $id, "firstspreadstart_err" );
    }
}

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
            $resized, \$grey, LANraragi::Utils::Vips::VIPS_INTERPRETATION_B_W, undef
        );
        LANraragi::Utils::Vips::unref_image($resized);
        die "Error converting to greyscale: " . LANraragi::Utils::Vips::fetch_and_clear_error() . "\n"
          if $cs_ret != 0;

        my $gray;
        my $cast_ret = LANraragi::Utils::Vips::vips_cast(
            $grey, \$gray, LANraragi::Utils::Vips::VIPS_FORMAT_UCHAR, undef
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
