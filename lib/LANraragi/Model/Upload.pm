package LANraragi::Model::Upload;

use v5.36;

use strict;
use warnings;

use Redis;
use Config;
use Encode;
use URI::Escape;
use Mojo::URL;
use File::Basename;
use File::Temp qw(tempdir tempfile tmpnam);
use Digest::SHA qw(sha256_hex);
use File::Find qw(find);

use LANraragi::Utils::Archive  qw(extract_thumbnail validate_public_http_url verify_public_http_peer);
use LANraragi::Utils::Database qw(invalidate_cache compute_id set_title set_tags set_summary add_archive_to_redis add_timestamp_tag add_pagecount add_arcsize);
use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::Redis    qw(redis_encode);
use LANraragi::Utils::Generic  qw(is_archive get_bytelength exec_with_lock_pure);
use LANraragi::Utils::String   qw(trim trim_CRLF trim_url);
use LANraragi::Utils::Path     qw(create_path get_archive_path rename_path move_path unlink_path);
use LANraragi::Utils::PageSide qw(enqueue_first_spread_start_detection);

use LANraragi::Model::Config;
use LANraragi::Model::Plugins;
use LANraragi::Model::Category;
use LANraragi::Model::Archive;
use LANraragi::Model::Dedup::CoverIndex ();
use LANraragi::Utils::UploadCommit;

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );
use constant DOWNLOAD_MAX_ATTEMPTS       => 5;
use constant DOWNLOAD_MAX_REDIRECTS      => 5;
use constant DOWNLOAD_MAX_RESPONSE_BYTES => 2_000_000_000;

sub _close_upload_redis_handles (@handles) {
    for my $handle (@handles) {
        eval { $handle->quit() if $handle; };
    }
}

sub _download_http_hop ( $ua, $url, $ip ) {
    my $host = $url->host;
    ( my $bare_ip = $ip ) =~ s/^\[|\]$//g;
    my $pinned = $url->clone->host( $bare_ip =~ /:/ ? "[$bare_ip]" : $bare_ip );
    my $port = $url->port // ( $url->scheme eq 'https' ? 443 : 80 );
    my $host_header = $host;
    $host_header .= ":$port"
      if !( $url->scheme eq 'https' && $port == 443 ) && !( $url->scheme eq 'http' && $port == 80 );

    $ua->connect_timeout(10)->request_timeout(300)->inactivity_timeout(30)
      ->max_redirects(0)->max_connections(0)->max_response_size(DOWNLOAD_MAX_RESPONSE_BYTES);
    $ua->proxy->http(undef)->https(undef);
    if ( $url->scheme eq 'https' ) {
        $ua->tls_options->{SSL_hostname} = $host;
        $ua->tls_options->{SSL_verifycn_name} = $host;
    }

    my $tx = $ua->build_tx( GET => $pinned => { Host => $host_header } );
    my $cookies = $ua->cookie_jar->find($url);
    $tx->req->cookies(@$cookies) if @$cookies;
    $ua->start($tx);
    verify_public_http_peer( $tx->remote_address, $bare_ip );
    return $tx;
}

# Handle files uploaded by the user, or downloaded from remote endpoints.

# Process a file.
# First argument is the filepath, preferably in a temp directory,
# as we'll copy it to the content folder and delete the original at the end.
#
# The file will be added to a category, if its ID is specified.
# You can also specify tags to add to the metadata for the processed file before autoplugin is ran. (if it's enabled)
#
# Returns an HTTP status code, the ID and title of the file, and a status message.
sub handle_incoming_file ( $tempfile, $catid, $tags, $title, $summary ) {

    my ( $filename, $dirs, $suffix ) = fileparse( $tempfile, qr/\.[^.]*/ );
    $filename = $filename . $suffix;
    my $logger = get_logger( "File Upload/Download", "lanraragi" );

    # Check if file is an archive
    unless ( is_archive($filename) ) {
        $logger->debug("$filename is not an archive, halting upload process.");
        return ( 415, "deadbeef", $filename, "Unsupported File Extension ($filename)" );
    }

    # Compute an ID here
    my $id = compute_id($tempfile);
    $logger->debug("ID of uploaded file $filename is $id");

    # Future home of the file
    my $userdir     = LANraragi::Model::Config->get_userdir;
    my $output_file = create_path( $userdir . '/' . $filename );

    #Check if the ID is already in the database, and
    #that the file it references still exists on the filesystem
    my $redis        = LANraragi::Model::Config->get_redis;
    my $redis_search = LANraragi::Model::Config->get_redis_search;
    my $redis_config = LANraragi::Model::Config->get_redis_config;
    my $replace_dupe = LANraragi::Model::Config->get_replacedupe;
    my $isdupe       = $redis->exists($id) && -e get_archive_path( $redis, $id );

    # Stop here if file is a dupe and replacement is turned off.
    if ( ( -e $output_file || $isdupe ) && !$replace_dupe ) {

        # Trash temporary file
        unlink_path $tempfile;

        # The file already exists
        my $suffix = " Enable replace duplicated archive in config to replace old ones.";
        my $msg =
          $isdupe
          ? "This file already exists in the Library." . $suffix
          : "A file with the same name is present in the Library." . $suffix;

        _close_upload_redis_handles( $redis, $redis_search, $redis_config );
        return ( 409, $id, $filename, $msg );
    }

    # Each request owns its staging file. A shared "filename.upload" path can
    # be overwritten by another request before either archive lock is acquired.
    my ( $staging_handle, $staging_file ) = eval {
        tempfile( '.lrr-upload-XXXXXX', DIR => $userdir, SUFFIX => '.upload', UNLINK => 0 );
    };
    if ($@) {
        my $staging_error = $@;
        _close_upload_redis_handles( $redis, $redis_search, $redis_config );
        return ( 500, $id, $filename, "Could not stage the upload: $staging_error" );
    }
    close $staging_handle;
    unless ( move_path( $tempfile, $staging_file ) ) {
        my $move_error = "$!";
        unlink_path($staging_file);
        _close_upload_redis_handles( $redis, $redis_search, $redis_config );
        return ( 500, $id, $filename, "The file couldn't be moved to your content folder: $move_error" );
    }

    my $cleanup_warning = "";
    my $commit = sub ($old_id, $old_path) {
        my %previous = $redis->hgetall($id);
        my $committed_name = LANraragi::Utils::UploadCommit::publish($staging_file, $output_file, $old_path, sub {
            my $name;
            if (%previous) {
                # Same-ID replacement preserves user metadata and collection membership.
                $name = $previous{title} // $filename;
                $redis->hset($id, 'file', IS_UNIX ? encode_utf8($output_file) : $output_file);
                $redis->hdel($id, qw(pagefiles pagecount arcsize));
                LANraragi::Model::Archive::invalidate_archive_path_cache($id);
                LANraragi::Utils::PageCache::clear_by_id($id);
                LANraragi::Utils::PageSide::clear_first_spread_start_detection($redis, $id);
            } else {
                $name = add_archive_to_redis($id, IS_UNIX ? encode_utf8($output_file) : $output_file, $redis, $redis_search);
            }
            LANraragi::Model::Dedup::CoverIndex::invalidate_cover_dedup_signals($redis, $redis_config, $id);
            set_tags($id, $tags) if $tags;
            set_title($id, $title) if $title;
            set_summary($id, $summary) if $summary;
            add_timestamp_tag($redis, $id);
            add_pagecount($redis, $id);
            add_arcsize($redis, $id);
            if ($tags) {
                for my $tag (split /,\s?/, $tags) {
                    if (trim($tag) =~ /^source:(.*)/i) {
                        my $url = $1;
                        trim_url($url);
                        $redis_search->hset("LRR_URLMAP", $url, $id);
                    }
                }
            }
            $redis_config->hset("LRR_FILEMAP", $output_file, $id);
            $redis_config->hdel("LRR_FILEMAP", $old_path)
                if defined $old_path && "$old_path" ne "$output_file";
            $redis_config->hdel("LRR_FILEMAP_PENDING", $output_file);
            return $name;
        }, sub {
            if (%previous) {
                set_title($id, LANraragi::Utils::Redis::redis_decode($previous{title} // ''));
                set_tags($id, LANraragi::Utils::Redis::redis_decode($previous{tags} // ''));
                $redis->del($id);
                $redis->hmset($id, %previous);
                LANraragi::Model::Dedup::CoverIndex::invalidate_cover_dedup_signals($redis, $redis_config, $id);
                LANraragi::Model::Archive::invalidate_archive_path_cache($id);
                LANraragi::Utils::PageCache::clear_by_id($id);
            } else {
                LANraragi::Model::Archive::delete_archive($id, { preserve_file => 1 });
            }
            $redis_config->hdel("LRR_FILEMAP", $output_file);
            if (defined $old_id && length($old_id)) {
                $redis_config->hset("LRR_FILEMAP", $old_path, $old_id);
            } else {
                $redis_config->hdel("LRR_FILEMAP", $output_file);
            }
            invalidate_cache();
        });
        # Failure here cannot turn an installed replacement into a rollback:
        # the new archive is complete and the old ID is only stale metadata.
        if (defined $old_id && length($old_id) && $old_id ne $id && $redis->exists($old_id)) {
            eval {
                LANraragi::Model::Archive::delete_archive($old_id, { preserve_file => 1 });
                # Removing the previous ID can remove a source URL shared
                # by its replacement. Restore ownership from committed tags.
                my $current_tags = LANraragi::Utils::Redis::redis_decode($redis->hget($id, 'tags') // '');
                for my $tag (split /,\s?/, $current_tags) {
                    $redis_search->hset('LRR_URLMAP', trim_url($1), $id) if $tag =~ /^source:(.*)/i;
                }
                1;
            }
                or $cleanup_warning = "Replacement saved; previous archive metadata cleanup needs retry. ";
            $logger->warn($cleanup_warning) if $cleanup_warning;
        }
        return $committed_name;
    };

    # Serialize filename decisions as well as IDs. Different incoming contents
    # have different IDs but still compete for the same destination path.
    my $lock_path = IS_UNIX ? "$output_file" : lc("$output_file");
    my $path_lock = "archive-path:" . sha256_hex(encode_utf8($lock_path));
    my ( $acquired, $result, $error );
    eval {
        ( $acquired, $result ) = exec_with_lock_pure( [$path_lock], sub {
            my $known_dupe = $redis->exists($id) && -e get_archive_path($redis, $id);
            my $known_old_id = $known_dupe ? $id
              : (-e $output_file ? $redis_config->hget("LRR_FILEMAP", $output_file) : undef);
            my @locks = ("archive-write:$id");
            push @locks, "archive-write:$known_old_id"
              if defined $known_old_id && length($known_old_id) && $known_old_id ne $id;

            my ( $ids_acquired, $decision ) = exec_with_lock_pure( [sort @locks], sub {
                # Another path may have changed this ID while locks were being
                # acquired. Resolve the target again before making any changes.
                my $current_dupe = $redis->exists($id) && -e get_archive_path($redis, $id);
                my $old_id = $current_dupe ? $id
                  : (-e $output_file ? $redis_config->hget("LRR_FILEMAP", $output_file) : undef);
                if ( defined $old_id && length($old_id) && $old_id ne $id
                    && (!defined $known_old_id || $old_id ne $known_old_id) ) {
                    return [409, "The destination changed during upload. Retry shortly."];
                }
                if ( ( -e $output_file || $current_dupe ) && !$replace_dupe ) {
                    return [409, "This file or filename already exists in the Library. Enable replace duplicated archive to replace it."];
                }
                my $old_path = $current_dupe ? get_archive_path($redis, $id)
                  : (-e $output_file ? $output_file : undef);
                if ( $current_dupe && "$old_path" ne "$output_file" && -e $output_file ) {
                    return [409, "The duplicate ID and destination name refer to different files. Choose another filename."];
                }
                return [200, $commit->($old_id, $old_path)];
            }, undef, 300 );
            return $ids_acquired ? $decision : [409, "The archive is being updated. Retry the upload shortly."];
        }, undef, 300 );
        1;
    } or $error = $@ || 'Upload commit failed';
    _close_upload_redis_handles($redis, $redis_search, $redis_config);
    # UploadCommit keeps recovery copies if rollback failed; never discard them
    # merely because this request is returning an error.
    return (500, $id, $filename, $error) if $error;
    if ( !$acquired || $result->[0] != 200 ) {
        unlink_path($staging_file) if -e $staging_file;
        return (409, $id, $filename, $acquired ? $result->[1] : "The destination is being updated. Retry the upload shortly.");
    }
    my $name = $result->[1];

    # Generate thumbnail
    my $thumbdir = LANraragi::Model::Config->get_thumbdir;
    extract_thumbnail( $thumbdir, $id, 1, 1, 1 );

    eval { enqueue_first_spread_start_detection($id); };
    if ($@) {
        $logger->warn("Failed to enqueue first-spread-start detection for $id: $@");
    }

    $logger->debug("Running autoplugin on newly uploaded file $id...");

    my ( $succ, $fail, $addedtags, $newtitle ) = LANraragi::Model::Plugins::exec_enabled_plugins_on_file($id);
    my $successmsg = $cleanup_warning . "$succ Plugins used successfully, $fail Plugins failed, $addedtags tags added. ";

    if ( $newtitle ne "" ) {
        $name = $newtitle;
    }

    if ($catid) {
        $logger->debug("Adding uploaded file to category $catid");

        my ( $catsucc, $caterr ) = LANraragi::Model::Category::add_to_category( $catid, $id );
        if ($catsucc) {
            my %category = LANraragi::Model::Category::get_category($catid);
            my $catname  = $category{name};
            $successmsg .= "Added to Category '$catname'!";
        } else {
            $successmsg .= "Couldn't add to Category: $caterr";
        }
    }

    # Invalidate search cache ourselves, Shinobu won't do it since the file is already in the database
    invalidate_cache();

    return ( 200, $id, $name, $successmsg );
}

# Download the given URL, using the given Mojo::UserAgent object.
# This downloads the URL to a temporaryfolder and returns the full path to the downloaded file.
sub download_url ( $url, $ua ) {

    my $logger = get_logger( "File Upload/Download", "lanraragi" );

    # Download to a temp folder
    die "Not a proper URL\n" unless $url;
    $logger->info("Downloading requested URL... This will take some time.");

    # Resolve and pin every redirect hop. This prevents private-network targets,
    # DNS rebinding, unbounded responses and implicit environment-proxy routing.
    my $filename = "Not_an_archive";
    my ( $tx, $content_disp, $content_type );
    my $requested_url = Mojo::URL->new($url);
    my $last_status   = "no response";

    ATTEMPT:
    for my $attempt ( 1 .. DOWNLOAD_MAX_ATTEMPTS ) {
        my $current = $requested_url->clone;
        for my $hop ( 0 .. DOWNLOAD_MAX_REDIRECTS ) {
            my ( $validated, $ip ) = validate_public_http_url($current);
            $tx = _download_http_hop( $ua, $validated, $ip );
            my $result = $tx->result;
            $last_status = join( " ", grep { defined && length } ( $result->code, $result->message ) );

            if ( $result->is_redirect ) {
                die "Too many redirects while downloading archive.\n" if $hop == DOWNLOAD_MAX_REDIRECTS;
                my $location = $result->headers->location;
                die "Download redirect is missing a Location header.\n"
                  unless defined($location) && length($location);
                $current = Mojo::URL->new($location)->to_abs($validated);
                next;
            }

            unless ( $result->is_success ) {
                $content_disp = undef;
                $content_type = undef;
                last;
            }

            $content_disp = $result->headers->content_disposition;
            $content_type = $result->headers->content_type;
            last;
        }

        last ATTEMPT if $content_disp;
        $logger->warn(
            "No valid Content-Disposition header received, waiting and retrying... "
              . "(attempt $attempt / " . DOWNLOAD_MAX_ATTEMPTS . ", status: $last_status)"
        );
        sleep 1 if $attempt < DOWNLOAD_MAX_ATTEMPTS;
    }

    if ( !$content_disp ) {
        die "No valid Content-Disposition header received after " . DOWNLOAD_MAX_ATTEMPTS
          . " attempts, aborting. (Last status: $last_status)\n";
    }

    my $content_length = $tx->result->headers->content_length;
    my $body_size = $tx->result->body_size;
    if ( $content_length && $content_length != $body_size ) {
        die( "Failed to download full body. (Expected $content_length bytes, received $body_size)" );
    }

    $logger->debug("Content-Disposition Header: $content_disp");
    $logger->debug("Content-Type Header: $content_type");
    if ( $content_disp =~ /.*filename=\"(.*)\".*/gim ) {
        my $temp = $1;
        # This field should be Latin1 but sometimes it is not so use Content-Type
        # as a hint on what to do
        if ( $content_type =~ /.*charset=UTF-8.*/gim ) {
            $filename = Encode::decode( "utf-8", $temp );
        } else {
            $filename = Encode::decode( "iso-8859-1", $temp );
        }
    } elsif ( $content_disp =~ /.*filename\*=UTF-8''(.*)/gim ) {
        # This is an UTF8 filename as per rfc5987.
        # URL-decode to get the full filename.
        $filename = Encode::decode( "utf-8", uri_unescape( $1 ) );
    } elsif ( $url =~ /([^\/]+)\/?$/gm ) {
        # Fallback to the last element of the URL as the filename.
        $logger->debug("No filename found in header, using URL as filename.");
        # Also URL/utf8 decode just in case
        $filename = Encode::decode( "utf-8", uri_unescape( $1 ) );
    }

    if ( !IS_UNIX ) {
        $filename = encode_utf8( $filename );
    }

    $logger->debug("Filename: $filename");

    # remove invalid Windows chars
    $filename =~ s@[\\/:"*?<>|]+@@g;

    # Move file to a temp folder (not the default LRR one)
    my $tempdir = tempdir();

    my ( $fn, $path, $ext ) = fileparse( $filename, qr/\.[^.]*/ );
    my $byte_limit = LANraragi::Model::Config->enable_cryptofs ? 143 : 255;

    # don't allow the main filename to exceed the given byte limit
    # for extension and .upload prefix used by `handle_incoming_file`
    $filename = $fn;
    while ( get_bytelength( $filename . $ext . ".upload" ) > $byte_limit ) {
        $filename = substr( $filename, 0, -1 );
    }
    $filename = $filename . $ext;

    my $tempfile = $tempdir . '/' . $filename;

    # To support long paths use a temp file and then move it to the final location using long-path compatible methods
    my $mojo_temp = tmpnam();
    if ( !$tx->result->content->asset->move_to( $mojo_temp ) ) {
        die("Could not move uploaded file $filename to $mojo_temp");
    }

    # Move the file for real this time
    if ( !move_path( $mojo_temp, $tempfile ) ) {
        die("Could not move uploaded file $mojo_temp to $tempfile");
    }

    return $tempfile;
}

1;
