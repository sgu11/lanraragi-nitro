package LANraragi::Utils::PageSide;

use strict;
use warnings;
use utf8;
use feature qw(signatures);
no warnings 'experimental::signatures';

use List::Util qw(max min sum);

use LANraragi::Model::Config;
use LANraragi::Utils::Archive  qw(extract_single_file get_filelist);
use LANraragi::Utils::Database qw(all_archive_ids);
use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::Path     qw(date_modified get_archive_path);

use Exporter 'import';
our @EXPORT_OK = qw(
  FIRST_PAGE_SIDE_VERSION
  RECENT_DETECTION_LIMIT
  choose_first_page_side
  detect_and_store_first_page_side
  detect_recent_first_page_sides
  enqueue_first_page_side_detection
  recent_archive_ids
);

use constant FIRST_PAGE_SIDE_VERSION => 1;
use constant RECENT_DETECTION_LIMIT  => 50;
use constant MIN_SAMPLE_CONFIDENCE   => 0.55;
use constant MIN_VOTE_GAP            => 0.20;

sub _clamped_recent_limit ($requested) {
    my $limit = defined $requested ? int($requested) : RECENT_DETECTION_LIMIT;
    $limit = RECENT_DETECTION_LIMIT if $limit <= 0;
    return min( $limit, RECENT_DETECTION_LIMIT );
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

sub recent_archive_ids ( $redis, $requested_limit = RECENT_DETECTION_LIMIT ) {
    my $limit = _clamped_recent_limit($requested_limit);
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

    return @sorted[ 0 .. min( $#sorted, $limit - 1 ) ] if @sorted;
    return;
}

sub enqueue_first_page_side_detection ($id) {
    return unless $id;
    LANraragi::Model::Config->get_minion->enqueue(
        detect_first_page_side => [$id] => { priority => 0 }
    );
}

sub detect_recent_first_page_sides ( $job, $requested_limit = RECENT_DETECTION_LIMIT ) {
    my $limit  = _clamped_recent_limit($requested_limit);
    my $logger = get_logger( "Minion", "minion" );
    my $redis  = LANraragi::Model::Config->get_redis;
    my @ids    = recent_archive_ids( $redis, $limit );
    $redis->quit;

    my $processed = 0;
    my @errors;
    $logger->info("detect_recent_first_page_sides: processing " . scalar(@ids) . " recent archives (limit=$limit)");

    for my $id (@ids) {
        eval { detect_and_store_first_page_side($id); };
        if ($@) {
            push @errors, "$id: $@";
            $logger->warn("detect_recent_first_page_sides failed for $id: $@");
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

sub detect_and_store_first_page_side ($id) {
    my $logger = get_logger( "PageSide", "lanraragi" );
    my $redis  = LANraragi::Model::Config->get_redis;

    my $result;
    eval {
        my $current_v    = $redis->hget( $id, "firstpageside_v" ) // "";
        my $current_side = $redis->hget( $id, "firstpageside" )   // "";
        if ( $current_v eq FIRST_PAGE_SIDE_VERSION && $current_side ne "" ) {
            $result = {
                side       => $current_side,
                confidence => $redis->hget( $id, "firstpageside_confidence" ) // 0,
                reason     => $redis->hget( $id, "firstpageside_reason" )     // "cached",
                cached     => 1
            };
        } else {
            my $file = get_archive_path( $redis, $id );
            die "Archive file does not exist for $id\n" unless defined $file && -e $file;

            my @filelist = get_filelist( $file, $id );
            die "Archive has no readable image pages: $id\n" unless @filelist;

            my @samples;
            my $last = min( $#filelist, 3 );
            for my $page_index ( 0 .. $last ) {
                my $contents = extract_single_file( $file, $filelist[$page_index] );
                next unless defined $contents && length $contents;
                push @samples, detect_page_side( $contents, $page_index );
            }

            $result = choose_first_page_side( \@samples );
        }
    };

    if ($@) {
        chomp( my $err = "$@" );
        $logger->warn("First page side detection failed for $id: $err");
        $result = {
            side       => "UNKNOWN",
            confidence => 0,
            reason     => "error",
            error      => $err
        };
    }

    _store_first_page_side( $redis, $id, $result );
    $redis->quit;
    return $result;
}

sub _store_first_page_side ( $redis, $id, $result ) {
    my $side = _normalize_side( $result->{side} ) // "UNKNOWN";
    $redis->hset( $id, "firstpageside",            $side );
    $redis->hset( $id, "firstpageside_confidence", $result->{confidence} // 0 );
    $redis->hset( $id, "firstpageside_reason",     $result->{reason}     // "" );
    $redis->hset( $id, "firstpageside_v",          FIRST_PAGE_SIDE_VERSION );

    if ( defined $result->{error} && $result->{error} ne "" ) {
        $redis->hset( $id, "firstpageside_err", $result->{error} );
    } else {
        $redis->hdel( $id, "firstpageside_err" );
    }
}

sub detect_page_side ( $contents, $page_index ) {
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

    if ($@ || !$frame) {
        return {
            page_index => $page_index,
            side       => "UNKNOWN",
            confidence => 0,
            reason     => "decode_failed"
        };
    }

    my ( $width, $height ) = $frame->Get( "width", "height" );
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

    my $left_score  = _edge_score( $frame, 0, $strip - 1, $height );
    my $right_score = _edge_score( $frame, $width - $strip, $width - 1, $height );
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
        side       => $delta > 0 ? "LEFT" : "RIGHT",
        confidence => min( 0.95, 0.55 + ( $magnitude * 2.5 ) ),
        reason     => "edge_complexity"
    };
}

sub _edge_score ( $frame, $x_start, $x_end, $height ) {
    my $x_step = max( 1, int( ( $x_end - $x_start + 1 ) / 5 ) );
    my $y_step = max( 1, int( $height / 64 ) );
    my ( $luminance_sum, $gradient_sum, $count ) = ( 0, 0, 0 );

    for ( my $x = $x_start; $x <= $x_end; $x += $x_step ) {
        my $previous;
        for ( my $y = 0; $y < $height; $y += $y_step ) {
            my $lum = _pixel_luminance( $frame, $x, $y );
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
