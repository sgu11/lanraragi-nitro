package LANraragi::Controller::Api::Archive;
use Mojo::Base 'Mojolicious::Controller';

use Digest::SHA qw(sha1_hex);
use Redis;
use Config;
use Encode;
use Storable;
use Scalar::Util qw(looks_like_number);

use File::Temp qw(tempdir tmpnam);
use File::Basename;

use LANraragi::Utils::Generic  qw(render_api_response is_archive get_bytelength exec_with_lock);
use LANraragi::Utils::Database qw(get_archive_json set_isnew);
use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::Redis    qw(redis_encode);
use LANraragi::Utils::Path     qw(compat_path get_archive_path move_path);

use LANraragi::Utils::Login qw(is_logged_in_api);
use LANraragi::Utils::Tachiyomi qw(is_tachiyomi_client);

use LANraragi::Model::Archive;
use LANraragi::Model::Category;
use LANraragi::Model::Config;
use LANraragi::Model::Reader;

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );
use constant TACHIYOMI_METADATA_CACHE_TTL => 30;
use constant TACHIYOMI_WARM_FILELIST_TTL  => 60;

my %TACHIYOMI_METADATA_CACHE;
my %TACHIYOMI_FILELIST_WARMED;

# Archive API.


sub serve_archivelist {
    my $self   = shift->openapi->valid_input or return;
    my @idlist = LANraragi::Model::Archive::generate_archive_list;
    $self->render( openapi => \@idlist );
}

sub serve_untagged_archivelist {
    my $self  = shift->openapi->valid_input or return;
    my $redis = $self->LRR_CONF->get_redis_search;

    my @untagged = $redis->smembers("LRR_UNTAGGED");
    $redis->quit;

    $self->render( openapi => \@untagged );
}

sub serve_metadata {
    my $self  = shift->openapi->valid_input or return;
    my $id    = $self->stash('id');
    my $redis = $self->LRR_CONF->get_redis;

    my $tachiyomi = is_tachiyomi_client($self);
    if ($tachiyomi) {
        if ( my $cached = _get_tachiyomi_metadata_cache($id) ) {
            $redis->quit;
            return $self->render( openapi => $cached );
        }
    }

    my $arcdata = get_archive_json( $redis, $id );
    $redis->quit;

    if ($arcdata) {
        if ($tachiyomi) {
            _set_tachiyomi_metadata_cache( $id, $arcdata );
            _enqueue_tachiyomi_filelist_warm( $self, $id );
        }
        $self->render( openapi => $arcdata );
    } else {
        render_api_response( $self, "metadata", "This ID doesn't exist on the server." );
    }
}

sub _get_tachiyomi_metadata_cache {
    my ($id) = @_;
    my $entry = $TACHIYOMI_METADATA_CACHE{$id};
    return unless $entry;

    if ( $entry->{expiry} <= time ) {
        delete $TACHIYOMI_METADATA_CACHE{$id};
        return;
    }

    return $entry->{value};
}

sub _set_tachiyomi_metadata_cache {
    my ( $id, $value ) = @_;
    $TACHIYOMI_METADATA_CACHE{$id} = {
        value  => $value,
        expiry => time + TACHIYOMI_METADATA_CACHE_TTL
    };
}

sub _enqueue_tachiyomi_filelist_warm {
    my ( $self, $id ) = @_;
    return unless defined $id && $id =~ /^[A-Za-z0-9_]{40}$/;

    my $now = time;
    return if ( $TACHIYOMI_FILELIST_WARMED{$id} // 0 ) > $now;

    $TACHIYOMI_FILELIST_WARMED{$id} = $now + TACHIYOMI_WARM_FILELIST_TTL;
    eval { $self->minion->enqueue( warm_filelist => [$id] => { priority => 0, attempts => 1 } ); };
}

# Find which categories this ID is saved in.
sub get_categories {

    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    my @categories = LANraragi::Model::Category::get_categories_containing_archive($id);

    $self->render(
        openapi => {
            operation  => "find_arc_categories",
            categories => \@categories,
            success    => 1
        }
    );
}

sub serve_thumbnail {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');
    LANraragi::Model::Archive::serve_thumbnail( $self, $id );
}

sub update_thumbnail {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');
    LANraragi::Model::Archive::update_thumbnail( $self, $id );
}

sub generate_page_thumbnails {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');
    LANraragi::Model::Archive::generate_page_thumbnails( $self, $id );
}

# Use RenderFile to get the file of the provided id to the client.
sub serve_file {

    my $self  = shift->openapi->valid_input or return;
    my $id    = $self->stash('id');
    my $redis = $self->LRR_CONF->get_redis;

    my $file = get_archive_path( $redis, $id );
    $redis->quit();
    $self->render_file( filepath => compat_path($file), filename => basename($file) );
}

# Create a file archive along with any metadata.
# adapted from Upload.pm
sub create_archive {
    my $self   = shift->openapi->valid_input or return;
    my $logger = get_logger( "Archive API ", "lanraragi" );

    # receive uploaded file
    my $upload            = $self->req->upload('file');
    my $expected_checksum = $self->req->param('file_checksum');    # optional

    # require file
    if ( !defined $upload || !$upload ) {
        return $self->render(
            openapi => {
                operation => "upload",
                success   => 0,
                error     => "No file attached"
            },
            status => 400
        );
    }

    # checksum verification stage.
    if ($expected_checksum) {
        my $file_content    = $upload->slurp;
        my $actual_checksum = sha1_hex($file_content);
        if ( $expected_checksum ne $actual_checksum ) {
            return $self->render(
                openapi => {
                    operation => "upload",
                    success   => 0,
                    error     => "Checksum mismatch: expected $expected_checksum, got $actual_checksum."
                },
                status => 417
            );
        }
    }

    my $filename   = $upload->filename;
    my $uploadMime = $upload->headers->content_type;

    return unless exec_with_lock(
        $self,
        "upload:$filename",
        "upload",
        $filename,
        sub {

            # metadata extraction
            my $catid   = $self->req->param('category_id');
            my $tags    = $self->req->param('tags');
            my $title   = $self->req->param('title');
            my $summary = $self->req->param('summary');

            # return error if archive is not supported.
            if ( !is_archive($filename) ) {
                return $self->render(
                    openapi => {
                        operation => "upload",
                        success   => 0,
                        error     => "Unsupported file extension ($filename)"
                    },
                    status => 415
                );
            }

            # Move file to a temp folder (not the default LRR one)
            my $tempdir = tempdir();

            my ( $fn, $path, $ext ) = fileparse( $filename, qr/\.[^.]*/ );
            my $byte_limit = LANraragi::Model::Config->enable_cryptofs ? 143 : 255;

            $filename = $fn;
            while ( get_bytelength( $filename . $ext . ".upload" ) > $byte_limit ) {
                $filename = substr( $filename, 0, -1 );
            }
            $filename = $filename . $ext;

            my $tempfile = $tempdir . '/' . $filename;

            # On Windows Mojo will hold an open handle to the upload file preventing us from using the long-path compatible
            # methods to move it.
            # Workaround it by using another temp file as a target for Mojo's move_to so that the original handle can be closed.
            my $mojo_temp = tmpnam();
            if ( !$upload->move_to($mojo_temp) ) {
                $logger->error("Could not move uploaded file $filename to $mojo_temp");
                return $self->render(
                    openapi => {
                        operation => "upload",
                        success   => 0,
                        error     => "Couldn't move uploaded file to temporary location."
                    },
                    status => 500
                );
            }

            if ( !move_path( $mojo_temp, $tempfile ) ) {    # Move the file for real this time
                $logger->error("Could not move uploaded file $mojo_temp to $tempfile");
                return $self->render(
                    openapi => {
                        operation => "upload",
                        success   => 0,
                        error     => "Couldn't move uploaded file to temporary location."
                    },
                    status => 500
                );
            }

            my ( $status_code, $id, $response_title, $message ) =
              LANraragi::Model::Upload::handle_incoming_file( $tempfile, $catid, $tags, $title, $summary );

            unless ( $status_code == 200 ) {
                return $self->render(
                    openapi => {
                        operation => "upload",
                        success   => 0,
                        error     => $message,
                        id        => $id
                    },
                    status => $status_code
                );
            }

            return $self->render(
                openapi => {
                    operation => "upload",
                    success   => 1,
                    id        => $id
                },
                status => 200
            );
        }
    );
}

# Serve an archive page from the temporary folder, using RenderFile.
sub serve_page {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');
    my $path = $self->req->param('path')                 || "404.xyz";

    LANraragi::Model::Archive::serve_page( $self, $id, $path );
}

sub get_file_list {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    my $force = $self->req->param('force') eq "true" || "0";
    my $reader_json;

    eval { $reader_json = LANraragi::Model::Reader::build_reader_JSON( $self, $id, $force ); };
    my $err = $@;

    if ($err) {
        render_api_response( $self, "get_file_list", $err );
    } else {
        $self->render( openapi => $reader_json );
    }
}

sub add_new {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "add_new",
        $id,
        sub {
            set_isnew( $id, "true" );
            render_api_response( $self, "add_new" );
        }
    );
}

sub clear_new {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "clear_new",
        $id,
        sub {
            set_isnew( $id, "false" );

            $self->render(
                openapi => {
                    operation => "clear_new",
                    id        => $id,
                    success   => 1
                }
            );
        }
    );
}

sub delete_archive {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "delete_archive",
        $id,
        sub {
            my $delStatus = LANraragi::Model::Archive::delete_archive($id);

            $self->render(
                openapi => {
                    operation => "delete_archive",
                    id        => $id,
                    filename  => decode_utf8($delStatus),
                    success   => $delStatus eq "0" ? 0 : 1
                }
            );
        }
    );
}

sub update_metadata {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    my $title   = $self->req->param('title');
    my $tags    = $self->req->param('tags');
    my $summary = $self->req->param('summary');

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "update_metadata",
        $id,
        sub {
            my $err = LANraragi::Model::Archive::update_metadata( $id, $title, $tags, $summary );

            if ( $err eq "" ) {
                my $title          = LANraragi::Model::Archive::get_title($id);
                my $successMessage = "Updated metadata for \"$title\"!";

                render_api_response( $self, "update_metadata", undef, $successMessage );
            } else {
                render_api_response( $self, "update_metadata", $err );
            }
        }
    );
}

sub add_toc {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    my $page  = $self->req->param('page');
    my $title = $self->req->param('title');

    unless ( defined $page && defined $title ) {
        return render_api_response( $self, "add_toc", "Missing page and/or title." );
    }

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "add_toc",
        $id,
        sub {
            my $res = LANraragi::Model::Archive::add_toc_entry( $id, $page, $title );

            if ( $res eq "" ) {
                render_api_response( $self, "add_toc", undef, "Added ToC entry for page $page." );
            } else {
                render_api_response( $self, "add_toc", $res );
            }
        }
    );

}

sub remove_toc {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    my $page = $self->req->param('page');

    unless ( defined $page ) {
        return render_api_response( $self, "remove_toc", "Please specify a page to remove" );
    }

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "remove_toc",
        $id,
        sub {
            my $res = LANraragi::Model::Archive::remove_toc_entry( $id, $page );

            if ( $res eq "" ) {
                render_api_response( $self, "remove_toc", undef, "Removed ToC entry for page $page." );
            } else {
                render_api_response( $self, "remove_toc", $res );
            }
        }
    );
}

sub update_progress {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    # Enforce authentication if authprogress is enabled
    if ( LANraragi::Model::Config->enable_authprogress ) {
        unless ( is_logged_in_api($self) ) {
            return $self->render(
                openapi => {
                    operation => "update_progress",
                    error     => "This operation requires authentication.",
                    success   => 0
                },
                status => 401
            );
        }
    }

    my $page = $self->stash('page') || 0;
    my $time = time();

    # Undocumented parameter to force progress update
    my $force = $self->req->param('force') || 0;

    my $redis     = $self->LRR_CONF->get_redis;
    my $redis_cfg = $self->LRR_CONF->get_redis_config;
    my $pagecount = $redis->hget( $id, "pagecount" );

    if ( LANraragi::Model::Config->enable_localprogress && !LANraragi::Model::Config->enable_authprogress ) {
        render_api_response( $self, "update_progress", "Server-side Progress Tracking is disabled on this instance." );
        $redis->quit();
        $redis_cfg->quit();
        return;
    }

    # This relies on pagecount, so you can't update progress for archives that don't have a valid pagecount recorded yet.
    unless ( $pagecount || $force ) {
        render_api_response( $self, "update_progress", "Archive doesn't have a total page count recorded yet." );
        $redis->quit();
        $redis_cfg->quit();
        return;
    }

    # Safety-check the given page value.
    unless ( $force || ( looks_like_number($page) && $page > 0 && $page <= $pagecount ) ) {
        render_api_response( $self, "update_progress", "Invalid progress value." );
        $redis->quit();
        $redis_cfg->quit();
        return;
    }

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "update_progress",
        $id,
        sub {

            # Just set the progress value.
            $redis->hset( $id, "progress",     $page );
            $redis->hset( $id, "lastreadtime", $time );
            $redis->quit();

            # Update total pages read statistic
            $redis_cfg->incr("LRR_TOTALPAGESTAT");
            $redis_cfg->quit();

            $self->render(
                openapi => {
                    operation    => "update_progress",
                    id           => $id,
                    page         => $page,
                    lastreadtime => $time,
                    success      => 1
                }
            );
        }
    );
}

sub update_spreadstart {
    my $self  = shift->openapi->valid_input or return;
    my $id    = $self->stash('id');
    my $value = $self->req->param('value') || "";

    unless ( $value eq "auto" || $value eq "none" || $value eq "always" ) {
        render_api_response( $self, "update_spreadstart", "Invalid spreadstart value." );
        return;
    }

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "update_spreadstart",
        $id,
        sub {
            my $redis = $self->LRR_CONF->get_redis;
            $redis->hset( $id, "spreadstart", $value );
            $redis->quit();

            $self->render(
                openapi => {
                    operation   => "update_spreadstart",
                    id          => $id,
                    spreadstart => $value,
                    success     => 1
                }
            );
        }
    );
}

1;
