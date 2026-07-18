package LANraragi::Model::Archive;

use v5.36;
use experimental 'try';

use strict;
use warnings;
use utf8;

use Cwd 'abs_path';
use Redis;
use Mojo::JSON  qw(decode_json encode_json);
use Time::HiRes qw(gettimeofday tv_interval usleep);
use File::Path  qw(remove_tree);
use File::Basename;
use File::Copy "cp";
use File::Path qw(make_path);

use LANraragi::Utils::Generic    qw(render_api_response);
use LANraragi::Utils::String     qw(trim trim_CRLF);
use LANraragi::Utils::TempFolder qw(get_temp);
use LANraragi::Utils::Logging    qw(get_logger);
use LANraragi::Utils::Archive    qw(extract_single_file extract_thumbnail is_cbw cbw_content_digest detect_cbw_image);
use LANraragi::Utils::Database   qw(invalidate_cache set_title set_tags set_summary get_archive_json get_archive_json_multi);
use LANraragi::Utils::ImageBorderCrop qw(CROP_ALGORITHM_VERSION crop_blank_borders);
use LANraragi::Utils::ImageResponse qw(render_thumbnail_placeholder);
use LANraragi::Utils::PageCache  qw(fetch put clear_by_id);
use LANraragi::Utils::Redis      qw(redis_decode redis_encode);
use LANraragi::Utils::Vips       ();
use LANraragi::Model::Dedup::CoverIndex;
use LANraragi::Utils::Path       qw(unlink_path get_archive_path);
use LANraragi::Model::Metrics;

use constant CROP_MIN_AREA_SAVINGS_RATIO => 0.05;
use constant CROP_SINGLEFLIGHT_LOCK_TTL_SECONDS => 30;
use constant CROP_SINGLEFLIGHT_WAIT_ATTEMPTS    => 10;
use constant CROP_SINGLEFLIGHT_WAIT_USEC        => 50_000;

# get_title(id)
#   Returns the title for the archive matching the given id.
#   Returns undef if the id doesn't exist.
sub get_title ($id) {

    my $logger = get_logger( "Archives", "lanraragi" );
    my $redis  = LANraragi::Model::Config->get_redis;

    if ( $id eq "" ) {
        $logger->debug("No archive ID provided.");
        return ();
    }

    return redis_decode( $redis->hget( $id, "title" ) );
}

# Functions used when dealing with archives.

# Generates an array of all the archive JSONs in the database that have existing files.
# This doesn't include Tanks. 
sub generate_archive_list {

    my $redis = LANraragi::Model::Config->get_redis;
    my @keys  = LANraragi::Utils::Database::all_archive_ids($redis);
    $redis->quit;

    return get_archive_json_multi(@keys);
}

sub update_thumbnail {

    my ( $self, $id ) = @_;

    my $page = $self->req->param('page');
    $page = 1 unless $page;

    my $thumbdir = LANraragi::Model::Config->get_thumbdir;
    my $use_avif = LANraragi::Model::Config->enable_avif_thumbnails;
    my $use_jxl  = LANraragi::Model::Config->get_jxlthumbpages;
    my $format   = $use_avif ? 'avif' : $use_jxl ? 'jxl' : 'jpg';

    # Thumbnails are stored in the content directory, thumb subfolder.
    # Another subfolder with the first two characters of the id is used for FS optimization.
    my $subfolder = substr( $id, 0, 2 );
    my $thumbname = "$thumbdir/$subfolder/$id.$format";    # Path to main thumbnail

    my $newthumb = "";

    # Get the required thumbnail we want to make the main one
    no warnings 'experimental::try';
    try {
        $newthumb = extract_thumbnail( $thumbdir, $id, $page, 1, 1 )
    } catch ($e) {
        render_api_response( $self, "update_thumbnail", $e );
        return;
    }

    if ( !$newthumb ) {
        render_api_response( $self, "update_thumbnail", "Thumbnail not generated." );
    } else {
        $self->render(
            openapi => {
                operation     => "update_thumbnail",
                new_thumbnail => $newthumb,
                success       => 1
            }
        );
    }

}

sub generate_page_thumbnails {

    my ( $self, $id ) = @_;

    my $force = $self->req->param('force');
    $force = ( $force && $force eq "true" ) || "0";    # Prevent undef warnings by checking the variable first

    my $logger   = get_logger( "Archives", "lanraragi" );
    my $thumbdir = LANraragi::Model::Config->get_thumbdir;
    my $use_avif = LANraragi::Model::Config->enable_avif_thumbnails;
    my $use_jxl  = LANraragi::Model::Config->get_jxlthumbpages;
    my $format   = $use_avif ? 'avif' : $use_jxl ? 'jxl' : 'jpg';
    my $use_hq   = LANraragi::Model::Config->get_hqthumbpages;

    # Get the number of pages in the archive
    my $redis = LANraragi::Model::Config->get_redis;
    my $pages = $redis->hget( $id, "pagecount" ) // 0;

    my $subfolder = substr( $id, 0, 2 );
    my $thumbname = "$thumbdir/$subfolder/$id.$format";

    my $should_queue_job = 0;

    for ( my $page = 1; $page <= $pages; $page++ ) {
        my $thumbname = "$thumbdir/$subfolder/$id/$page.$format";

        unless ( $force == 0 && -e $thumbname ) {
            $logger->debug("Thumbnail for page $page doesn't exist (path: $thumbname or force=$force), queueing job.");
            $should_queue_job = 1;
            last;
        }
    }

    if ($should_queue_job) {

        # Check if a job is already queued for this archive
        if ( $redis->hexists( $id, "thumbjob" ) ) {

            my $existing_id = $redis->hget( $id, "thumbjob" );
            my $existing_job = $self->minion->job($existing_id);
            my $job_state    = $existing_job ? $existing_job->info->{state} : undef;

            # If the job is pending or running, don't queue a new job and just return this one
            if ( defined $job_state && ( $job_state eq "active" || $job_state eq "inactive" ) ) {
                $self->render(
                    openapi => {
                        operation => "generate_page_thumbnails",
                        success   => 1,
                        job       => $existing_id
                    },
                    status => 202    # 202 Accepted
                );
                $redis->quit;
                return;
            }

            # Stale thumbjob field (job purged, finished, or failed without the on_failed hook firing).
            # Clear it so HSETNX below can claim. Only clear if it still matches what we just read.
            $redis->watch( $id );
            my $current = $redis->hget( $id, "thumbjob" );
            if ( defined $current && $current eq $existing_id ) {
                $redis->multi;
                $redis->hdel( $id, "thumbjob" );
                $redis->exec;
            } else {
                $redis->unwatch;
            }
        }

        # Queue a minion job to generate the thumbnails. Clients can check on its progress through the job ID.
        my $job_id = $self->minion->enqueue( page_thumbnails => [ $id, $force ] => { priority => 0, attempts => 3 } );

        # Atomic claim: HSETNX returns 1 if we set it, 0 if a concurrent worker won the race.
        my $claimed = $redis->hsetnx( $id, "thumbjob", $job_id );
        if ( !$claimed ) {

            # Lost the race. Remove our redundant job and return the winner's id.
            my $winner = $redis->hget( $id, "thumbjob" );
            eval { $self->minion->job($job_id)->remove; };
            $job_id = $winner if defined $winner;
        }
        $self->render(
            openapi => {
                operation => "generate_page_thumbnails",
                success   => 1,
                job       => $job_id
            },
            status => 202    # 202 Accepted
        );
    } else {
        $self->render(
            openapi => {
                operation => "generate_page_thumbnails",
                success   => 1,
                message   => "No job queued, all thumbnails already exist."
            },
            status => 200    # 200 OK
        );
    }

    $redis->quit;
}

sub _thumbnail_format {
    my $use_avif = LANraragi::Model::Config->enable_avif_thumbnails;
    my $use_jxl  = LANraragi::Model::Config->get_jxlthumbpages;
    return $use_avif ? 'avif' : $use_jxl ? 'jxl' : 'jpg';
}

sub _thumbnail_mime ($format) {
    return {
        avif => "image/avif",
        jpg  => "image/jpeg",
        jxl  => "image/jxl",
        png  => "image/png",
    }->{$format} // "application/octet-stream";
}

sub _page_mime ($format) {
    return {
        avif => "image/avif",
        bmp  => "image/bmp",
        gif  => "image/gif",
        heic => "image/heic",
        heif => "image/heif",
        jpeg => "image/jpeg",
        jpg  => "image/jpeg",
        jxl  => "image/jxl",
        png  => "image/png",
        webp => "image/webp",
    }->{ lc( $format // "" ) } // "application/octet-stream";
}

sub _render_thumbnail_file ( $self, $thumbname, $format ) {
    $self->res->headers->cache_control('public, max-age=2592000, immutable');
    $self->res->headers->header('Vary', 'Accept');
    $self->render_file(
        filepath            => $thumbname,
        content_disposition => "inline",
        content_type        => _thumbnail_mime($format)
    );
}

sub _single_thumbnail_lock_key ( $id, $page, $format ) {
    return "LRR_THUMBJOB:$id:$page:$format";
}

sub _is_active_minion_job ( $self, $job_id ) {
    return 0 unless defined $job_id;

    my $existing_job = $self->minion->job($job_id);
    my $job_state    = $existing_job ? $existing_job->info->{state} : undef;
    return defined $job_state && ( $job_state eq "active" || $job_state eq "inactive" );
}

sub _queue_single_thumbnail_job ( $self, $lock_key, $task, $args ) {
    my $redis = LANraragi::Model::Config->get_redis_config;

    my $existing_id = $redis->get($lock_key);
    if ( _is_active_minion_job( $self, $existing_id ) ) {
        $redis->quit;
        return $existing_id;
    }
    $redis->del($lock_key) if defined $existing_id;

    my $job_id = $self->minion->enqueue( $task => [ @$args, $lock_key ] => { priority => 0, attempts => 3 } );
    my $claimed = $redis->set( $lock_key, $job_id, "NX", "EX", 600 );
    if ( !$claimed ) {
        my $winner = $redis->get($lock_key);
        eval { $self->minion->job($job_id)->remove; };
        $job_id = $winner if defined $winner;
    }

    $redis->quit;
    return $job_id;
}

sub serve_thumbnail {

    my ( $self, $id ) = @_;

    my $page = $self->req->param('page');
    $page = 0 unless $page;
    my $is_first_page = $page == 0;

    my $no_fallback = $self->req->param('no_fallback');
    $no_fallback = ( $no_fallback && $no_fallback eq "true" ) || "0";    # Prevent undef warnings by checking the variable first

    my $thumbdir = LANraragi::Model::Config->get_thumbdir;

    my $subfolder = substr( $id, 0, 2 );
    my $thumbbase = ($is_first_page) ? "$thumbdir/$subfolder/$id" : "$thumbdir/$subfolder/$id/$page";

    # Search for an existing thumbnail file matching the best format the client
    # supports: client-advertised formats first (avif > jxl), then all remaining,
    # with jpg always last as universal fallback.
    my $accept = $self->req->headers->accept // '';
    my @accept_formats;
    my @remaining;
    for my $fmt (qw(avif jxl jpg)) {
        if ($fmt eq 'jpg' || $accept =~ /image\/\Q$fmt\E/) {
            push @accept_formats, $fmt;
        } else {
            push @remaining, $fmt;
        }
    }
    push @accept_formats, @remaining;

    my $thumbname;
    for my $fmt (@accept_formats) {
        my $candidate = "$thumbbase.$fmt";
        if ( -e $candidate ) {
            $thumbname = $candidate;
            last;
        }
    }

    unless ($thumbname) {

        if ($no_fallback) {

            # Queue a Minion job to generate the thumbnail. The config-DB lock coalesces
            # duplicate misses for the same page/format while the job is active.
            my $format   = _thumbnail_format();
            my $lock_key = _single_thumbnail_lock_key( $id, $page, $format );
            my $job_id   = _queue_single_thumbnail_job( $self, $lock_key, thumbnail_task => [ $thumbdir, $id, $page ] );
            $self->render(
                openapi => {
                    operation => "serve_thumbnail",
                    success   => 1,
                    job       => $job_id
                },
                status => 202
            );
        } else {
            render_thumbnail_placeholder($self);
        }
        return;
    }

    my ( $n, $p, $file_ext ) = fileparse( $thumbname, qr/\.[^.]*/ );
    _render_thumbnail_file( $self, $thumbname, substr( $file_ext, 1 ) );
}

sub get_page_data ( $id, $path, $metrics = undef ) {
    my $archive = _resolve_archive_path($id);
    my $cache_path = _content_cache_path( $archive, $path );
    my $cachekey = "page/$id/$cache_path";
    my $content  = fetch($cachekey);
    if ( !defined($content) ) {
        $metrics->{cache_status} = "miss" if defined $metrics;

        # Extract the file from the parent archive if it doesn't exist
        my $extract_start = [gettimeofday];
        $content = extract_single_file( $archive, $path );
        $metrics->{extract_seconds} = tv_interval($extract_start) if defined $metrics;
        put( $cachekey, $content );
    } else {
        $metrics->{cache_status} = "hit" if defined $metrics;
    }
    return $content;
}

sub _content_cache_path ( $archive, $path ) {
    return $path unless is_cbw($archive);
    return cbw_content_digest($archive) . "/$path";
}

# Per-worker memo of id -> on-disk archive path.
#
# The archive path for a given id is content-hash-stable: it only changes when
# the archive is replaced, re-id'd, or cleaned up. Resolving it on every
# PageCache miss used to open a fresh Redis connection (`get_redis` + AUTH +
# SELECT + HGET `file` + `quit`) per page. With reader preload firing several
# page requests in parallel, cold-reading a new archive paid this round-trip
# multiple times for a value that is invariant across the whole session.
#
# The memo is invalidated by invalidate_archive_path_cache(), which the
# archive-content mutation paths call (change_archive_id, delete_archive,
# clean_database, Shinobu filename-discrepancy rewrite). Per-worker is safe:
# a stale entry here only risks pointing at an old path, and the extraction
# call sites already handle missing files.
my %ARCHIVE_PATH_CACHE;
my $ARCHIVE_PATH_CACHE_GENERATION;

sub _archive_path_cache_generation_path {
    my $temp = eval { get_temp() };
    return unless $temp;
    return "$temp/archive-path-cache.generation";
}

sub _read_archive_path_cache_generation {
    my $path = _archive_path_cache_generation_path();
    return "" unless $path && -e $path;

    open( my $fh, '<', $path ) or return "";
    local $/ = undef;
    my $generation = <$fh> // "";
    close $fh;
    return $generation;
}

sub _bump_archive_path_cache_generation {
    my $path = _archive_path_cache_generation_path();
    return unless $path;

    my ( $sec, $usec ) = gettimeofday;
    open( my $fh, '>', $path ) or return;
    print {$fh} "$sec.$usec.$$";
    close $fh;
}

sub _sync_archive_path_cache_generation {
    my $generation = _read_archive_path_cache_generation();
    if ( !defined $ARCHIVE_PATH_CACHE_GENERATION ) {
        $ARCHIVE_PATH_CACHE_GENERATION = $generation;
        return;
    }

    return if $ARCHIVE_PATH_CACHE_GENERATION eq $generation;

    %ARCHIVE_PATH_CACHE = ();
    $ARCHIVE_PATH_CACHE_GENERATION = $generation;
}

sub _resolve_archive_path ($id) {
    _sync_archive_path_cache_generation();
    return $ARCHIVE_PATH_CACHE{$id} if exists $ARCHIVE_PATH_CACHE{$id};

    my $redis   = LANraragi::Model::Config->get_redis;
    my $archive = get_archive_path( $redis, $id );
    $redis->quit();

    $ARCHIVE_PATH_CACHE{$id} = $archive;
    return $archive;
}

# Clear the per-worker archive-path memo. Call after any mutation that can
# change an archive's on-disk path or id mapping: change_archive_id,
# delete_archive, clean_database, and Shinobu's filename-discrepancy rewrite.
sub invalidate_archive_path_cache {
    my ($id) = @_;
    if ( defined $id ) {
        delete $ARCHIVE_PATH_CACHE{$id};
    } else {
        %ARCHIVE_PATH_CACHE = ();
    }
    _bump_archive_path_cache_generation();
}

sub _crop_cache_key ( $id, $path, $format ) {
    return "crop_page/v" . CROP_ALGORITHM_VERSION . "/$id/$path/$format";
}

sub _crop_resize_cache_key ( $id, $path, $threshold, $quality ) {
    return "crop_resize_page/v" . CROP_ALGORITHM_VERSION . "/$id/$path/$threshold/$quality";
}

sub _crop_nocrop_cache_key ( $id, $path ) {
    return "crop_page_nocrop/v" . CROP_ALGORITHM_VERSION . "/$id/$path";
}

sub _crop_singleflight_lock_key ( $id, $path, $format ) {
    return "LRR_PAGECROPJOB:v" . CROP_ALGORITHM_VERSION . ":$id:$path:$format";
}

sub _claim_crop_singleflight_lock ($lock_key) {
    my $redis = eval { LANraragi::Model::Config->get_redis_config };
    return if $@ || !$redis;

    my ( $sec, $usec ) = gettimeofday;
    my $token = "$$:$sec:$usec";
    my $claimed = eval { $redis->set( $lock_key, $token, "NX", "EX", CROP_SINGLEFLIGHT_LOCK_TTL_SECONDS ) };
    return ( $redis, $token ) if $claimed;
    return ( $redis, undef );
}

sub _release_crop_singleflight_lock ( $redis, $lock_key, $token ) {
    return if !$redis;
    eval {
        if ( defined $token ) {
            my $stored = $redis->get($lock_key);
            $redis->del($lock_key) if defined $stored && $stored eq $token;
        }
        1;
    };
    $redis->quit();
}

sub _cached_border_crop_result ( $crop_key, $nocrop_key, $content, $metrics = undef ) {
    my $cached = fetch($crop_key);
    if ( defined $cached ) {
        $metrics->{cache_status} = "hit" if defined $metrics;
        return ( $cached, 1, 1 );
    }

    if ( defined fetch($nocrop_key) ) {
        $metrics->{cache_status} = "nocrop" if defined $metrics;
        return ( $content, 0, 1 );
    }

    return;
}

sub _wait_for_border_crop_result ( $crop_key, $nocrop_key, $content, $metrics = undef ) {
    for ( 1 .. CROP_SINGLEFLIGHT_WAIT_ATTEMPTS ) {
        usleep(CROP_SINGLEFLIGHT_WAIT_USEC);
        my @result = _cached_border_crop_result( $crop_key, $nocrop_key, $content, $metrics );
        return @result if @result;
    }
    return;
}

sub _compute_and_cache_border_crop ( $id, $path, $format, $content, $metrics, $crop_key ) {
    my ( $result, $was_cropped ) = _apply_border_crop( $id, $path, $format, $content, $metrics );
    put( $crop_key, $result ) if $was_cropped;
    return ( $result, $was_cropped );
}

sub _apply_border_crop_singleflight ( $id, $path, $format, $content, $metrics, $crop_key ) {
    my $nocrop_key = _crop_nocrop_cache_key( $id, $path );
    my @cached = _cached_border_crop_result( $crop_key, $nocrop_key, $content, $metrics );
    return @cached[ 0, 1 ] if @cached;

    my $lock_key = _crop_singleflight_lock_key( $id, $path, $format );
    my ( $redis, $token ) = _claim_crop_singleflight_lock($lock_key);

    if ( $redis && !defined $token ) {
        my @waited = _wait_for_border_crop_result( $crop_key, $nocrop_key, $content, $metrics );
        _release_crop_singleflight_lock( $redis, $lock_key, undef );
        return @waited[ 0, 1 ] if @waited;
        return _compute_and_cache_border_crop( $id, $path, $format, $content, $metrics, $crop_key );
    }

    return _compute_and_cache_border_crop( $id, $path, $format, $content, $metrics, $crop_key ) if !$redis;

    my ( $result, $was_cropped );
    my $error;
    eval {
        my @winner_cached = _cached_border_crop_result( $crop_key, $nocrop_key, $content, $metrics );
        if (@winner_cached) {
            ( $result, $was_cropped ) = @winner_cached[ 0, 1 ];
        } else {
            ( $result, $was_cropped ) =
              _compute_and_cache_border_crop( $id, $path, $format, $content, $metrics, $crop_key );
        }
        1;
    } or $error = $@;

    _release_crop_singleflight_lock( $redis, $lock_key, $token );
    die $error if $error;
    return ( $result, $was_cropped );
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

sub _apply_border_crop ( $id, $path, $format, $content, $metrics = undef ) {
    my $nocrop_key = _crop_nocrop_cache_key( $id, $path );
    if ( defined fetch($nocrop_key) ) {
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
            put( $nocrop_key, "1" );
            $metrics->{cache_status} = "nocrop_area" if defined $metrics;
            return ( $content, 0 );
        }
        return ( $cropped, 1 );
    }

    put( $nocrop_key, "1" );
    $metrics->{cache_status} = "nocrop" if defined $metrics;
    return ( $content, 0 );
}

sub serve_page {
    my ( $self, $id, $path ) = @_;

    my $logger = get_logger( "File Serving", "lanraragi" );

    $logger->debug("Page /$id/$path was requested");

    my $serving_start = [gettimeofday];
    my %image_metrics = (
        kind             => "page",
        variant          => "original",
        cache_status     => "miss",
        extract_seconds  => 0,
        resize_seconds   => 0,
        crop_seconds     => 0,
        crop_dims_seconds => 0,
    );
    my $crop_borders = ( $self->req->param('crop') // "" ) eq "border";

    my ( $n, $p, $file_ext ) = fileparse( $path, qr/\.[^.]*/ );
    my $format = substr( $file_ext, 1 ) || "jpg";
    my $archive = eval { _resolve_archive_path($id) };
    my $is_cbw_page = defined($archive) && is_cbw($archive);
    my $cache_path = $is_cbw_page ? _content_cache_path( $archive, $path ) : $path;

    # Apply resizing transformation if set in Settings
    if ( LANraragi::Model::Config->enable_resize ) {
        $image_metrics{variant} = $crop_borders ? "cropped_resized" : "resized";

        # Store resized files in a subfolder of the ID's temp folder, keyed by quality
        my $threshold = LANraragi::Model::Config->get_threshold;
        my $quality   = LANraragi::Model::Config->get_readquality;

        my $cachekey = $crop_borders
          ? _crop_resize_cache_key( $id, $cache_path, $threshold, $quality )
          : "resize_page/$id/$cache_path/$threshold/$quality";
        my $content  = fetch($cachekey);
        if ( !defined($content) ) {
            $image_metrics{cache_status} = "miss";
            my %page_metrics;
            my $page_content = get_page_data( $id, $path, \%page_metrics );
            $format = detect_cbw_image($page_content)->{format} if $is_cbw_page;
            if ($crop_borders) {
                ( $page_content ) = _apply_border_crop( $id, $cache_path, $format, $page_content, \%image_metrics );
            }
            my $resize_start = [gettimeofday];
            $content = LANraragi::Model::Reader::resize_image( $page_content, $quality, $threshold );
            $image_metrics{extract_seconds} = $page_metrics{extract_seconds} // 0;
            $image_metrics{resize_seconds}  = tv_interval($resize_start);
            put( $cachekey, $content );
        } else {
            $image_metrics{cache_status} = "hit";
        }

        # Archive IDs are content-hashed, so (id, path) is stable; private because No-Fun Mode can gate access.
        $self->res->headers->cache_control('private, max-age=3600, immutable');

        LANraragi::Model::Metrics::record_image_serving_metrics(
            %image_metrics,
            duration_seconds => tv_interval($serving_start),
            bytes            => length($content)
        );

        my $response_info = $is_cbw_page ? detect_cbw_image($content) : undef;
        my %render_args = (
            data                => $content,
            content_disposition => "inline"
        );
        if ($response_info) {
            $render_args{content_type} = $response_info->{mime};
        } else {
            $render_args{format} = "jpg";
        }
        $self->render_file(%render_args);
    } else {

        # CBW response bytes, not URL suffixes, are authoritative for format.
        my $content = $is_cbw_page ? get_page_data( $id, $path, \%image_metrics ) : undef;
        my $response_info = $is_cbw_page ? detect_cbw_image($content) : undef;
        $format = $response_info->{format} if $response_info;
        my $cachekey = _crop_cache_key( $id, $cache_path, $format );
        $content = $crop_borders ? fetch($cachekey) : $content;
        if ($crop_borders && defined($content)) {
            $image_metrics{variant}      = "cropped";
            $image_metrics{cache_status} = "hit";
        } else {
            $content = get_page_data( $id, $path, \%image_metrics ) unless defined $content;
            if ($crop_borders) {
                $image_metrics{variant}      = "cropped";
                $image_metrics{cache_status} = "miss";
                my $was_cropped;
                ( $content, $was_cropped ) =
                  _apply_border_crop_singleflight( $id, $cache_path, $format, $content, \%image_metrics, $cachekey );
            }
        }
        $logger->debug( "Data size:" . length($content) );

        $self->res->headers->cache_control('private, max-age=3600, immutable');

        LANraragi::Model::Metrics::record_image_serving_metrics(
            %image_metrics,
            duration_seconds => tv_interval($serving_start),
            bytes            => length($content)
        );

        # Serve extracted file directly
        my %render_args = (
            data                => $content,
            content_disposition => "inline"
        );
        if ($response_info) {
            $render_args{content_type} = $response_info->{mime};
        } else {
            $render_args{content_type} = _page_mime( substr( $file_ext, 1 ) );
        }
        $self->render_file(%render_args);
    }
}

sub update_metadata {
    my ( $id, $title, $tags, $summary ) = @_;

    unless ( defined $title || defined $tags ) {
        return "No metadata parameters (Please supply title, tags or summary)";
    }

    # Clean up the user's inputs and encode them.
    ( $_ = trim($_) )      for ( $title, $tags );
    ( $_ = trim_CRLF($_) ) for ( $title, $tags );

    if ( defined $title ) {
        set_title( $id, $title );
    }

    if ( defined $tags ) {
        set_tags( $id, $tags );
    }

    if ( defined $summary ) {
        set_summary( $id, $summary );
    }

    # Bust cache
    invalidate_cache();

    # No errors.
    return "";
}

sub add_toc_entry {
    my ( $id, $page, $title ) = @_;

    my $redis  = LANraragi::Model::Config->get_redis;
    my $logger = get_logger( "Archives", "lanraragi" );
    my $toc    = $redis->hget( $id, "toc" );

    no warnings 'experimental::try';
    try {
        $toc          = decode_json($toc);
        $toc->{$page} = $title;
        $toc          = encode_json($toc);
    } catch ($e) {
        $logger->warn(
            "Error while updating ToC: $e -- Will overwrite with a ToC containing the new data. (This is normal if this ID had no ToC yet.)"
        );
        $toc          = {};
        $toc->{$page} = $title;
        $toc          = encode_json($toc);
    }
    $redis->hset( $id, "toc", $toc );

    $redis->quit();
    return "";
}

sub remove_toc_entry {
    my ( $id, $page ) = @_;

    my $redis  = LANraragi::Model::Config->get_redis;
    my $logger = get_logger( "Archives", "lanraragi" );
    my $toc    = $redis->hget( $id, "toc" );

    no warnings 'experimental::try';
    try {
        $toc = decode_json($toc);
        delete $toc->{$page};
        $toc = encode_json($toc);
    } catch ($e) {
        $logger->warn("Error while updating ToC: $e -- Will overwrite with a blank ToC.");
        $toc = "{}";
    }
    $redis->hset( $id, "toc", $toc );

    $redis->quit();
    return "";
}

# Deletes the archive with the given id from redis, and the matching archive file/thumbnail.
sub delete_archive ($id) {

    my $redis    = LANraragi::Model::Config->get_redis;
    my $filename = get_archive_path( $redis, $id );
    my $oldtags  = $redis->hget( $id, "tags" );
    $oldtags = redis_decode($oldtags);

    my $oldtitle = lc( redis_decode( $redis->hget( $id, "title" ) ) );
    $oldtitle = trim($oldtitle);
    $oldtitle = trim_CRLF($oldtitle);
    $oldtitle = redis_encode($oldtitle);

    # Remove from tanks/collections
    foreach my $tank_id ( LANraragi::Model::Tankoubon::get_tankoubons_containing_archive($id) ) {
        LANraragi::Model::Tankoubon::remove_from_tankoubon( $tank_id, $id );
    }

    foreach my $cat ( LANraragi::Model::Category::get_categories_containing_archive($id) ) {
        my $catid = %{$cat}{"id"};
        LANraragi::Model::Category::remove_from_category( $catid, $id );
    }

    $redis->srem( "LRR_ALL_ARCHIVES", $id );

    # Remove Stamps
    my $stamps    = $redis->hget( $id, "stamps" );
    my @stamps;

    if ( $redis->hexists( $id, "stamps" )) {
        eval { @stamps = @{ decode_json($stamps) } };
        if ($@) {
            die;
        }
        foreach my $stamp ( @stamps ) {
            $redis->del($stamp);
        }
    } else {
        # Stamps attribute was not set, do nothing.
    }
    $redis->del($id);
    $redis->quit();

    # Drop the per-worker id->path memo so a future re-added archive at the
    # same id resolves fresh, and clear all page-byte variants for that id.
    invalidate_archive_path_cache($id);
    clear_by_id($id);

    # Clean up cover duplicate pairs for the deleted archive.
    eval {
        my $redis_cfg = LANraragi::Model::Config->get_redis_config;
        LANraragi::Model::Dedup::CoverIndex::remove_pairs_for_archive($redis_cfg, $id);
        $redis_cfg->quit;
    };

    # Remove matching data from the search indexes
    my $redis_search = LANraragi::Model::Config->get_redis_search;
    $redis_search->zrem( "LRR_TITLES", "$oldtitle\0$id" );
    $redis_search->srem( "LRR_NEW",         $id );
    $redis_search->srem( "LRR_UNTAGGED",    $id );
    $redis_search->srem( "LRR_TANKGROUPED", $id );
    $redis_search->quit();

    LANraragi::Utils::Database::update_indexes( $id, $oldtags, "" );
    invalidate_cache();

    if ( -e $filename ) {
        my $status = unlink_path($filename);

        my $thumbdir  = LANraragi::Model::Config->get_thumbdir;
        my $subfolder = substr( $id, 0, 2 );

        my $jpg_thumbname = "$thumbdir/$subfolder/$id.jpg";
        unlink $jpg_thumbname;

        my $jxl_thumbname = "$thumbdir/$subfolder/$id.jxl";
        unlink $jxl_thumbname;

        my $avif_thumbname = "$thumbdir/$subfolder/$id.avif";
        unlink $avif_thumbname;

        # Delete the thumbpages folder
        remove_tree("$thumbdir/$subfolder/$id/");

        return $status ? $filename : "0";
    }

    return "0";
}

1;
