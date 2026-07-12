package LANraragi::Model::Opds;

use strict;
use warnings;
use utf8;

use Redis;
use POSIX      qw(strftime);
use Mojo::Util qw(xml_escape);

use LANraragi::Utils::Generic  qw(get_tag_with_namespace);
use LANraragi::Utils::Archive  qw(get_filelist);
use LANraragi::Utils::Database qw(get_archive_json get_archive_json_multi);
use LANraragi::Utils::Path     qw(get_archive_path);

use LANraragi::Model::Category;
use LANraragi::Model::Search;

sub generate_opds_catalog {

    my $mojo   = shift;
    my $cat_id = $mojo->req->param('category') || "";
    my $start  = $mojo->req->param('start')    || 0;

    # If the user authentified to this via an API key, we need to carry it over to the OPDS links.
    my $api_key = $mojo->req->param('key');
    my @cats    = LANraragi::Model::Category->get_category_list;

    # Use the search engine to get the list of archives to show in the catalog.
    # TODO Add tankgroup/hidecompleted support to opds?
    my ( $total, $filtered, @keys ) = LANraragi::Model::Search::do_search( "", $cat_id, $start, "title", 0, 0, 0, 0, 0 );

    my @list = ();

    # Fetch all archive JSON in one MULTI/EXEC batch instead of one Redis
    # connection + HMGET per row. For a 30-entry catalog page this collapses
    # ~30 serialized (connect + AUTH + SELECT + exists + HGET + HMGET + quit)
    # cycles into one transaction. OPDS feeds are polled frequently by reader
    # apps, so this is on a real hot path.
    #
    # build_json (called inside get_archive_json_multi) already returns undef
    # for archives whose file is missing on disk, so missing-file rows are
    # filtered for free by the grep.
    my %base_json = map { $_->{arcid} => $_ } grep { defined } get_archive_json_multi(@keys);

    foreach my $id (@keys) {
        my $arcdata = $base_json{$id};
        next unless $arcdata;
        _derive_opds_fields($arcdata);
        push @list, $arcdata;
    }

    foreach my $cat (@cats) {

        for ( values %{$cat} ) { $_ = xml_escape($_); }

        # If the category doesn't have a search string, we can add the total count of archives to the entry.
        if ( $cat->{search} eq "" ) {
            $cat->{count} = scalar @{ $cat->{archives} };
        }

        if ( $cat->{id} eq $cat_id ) {
            $cat->{active} = 1;
        }
    }

    # Sort lists to get reproducible results
    @list = sort { lc( $a->{title} ) cmp lc( $b->{title} ) } @list;
    @cats = sort { lc( $a->{name} ) cmp lc( $b->{name} ) } @cats;

    return $mojo->render_to_string(
        template      => "opds",
        arclist       => \@list,
        catlist       => \@cats,
        nocat         => $cat_id eq "",
        nextpage      => $start + scalar @list,
        title         => $mojo->LRR_CONF->get_htmltitle,
        motd          => $mojo->LRR_CONF->get_motd,
        version       => $mojo->LRR_VERSION,
        api_key_query => $api_key ? "?key=" . $api_key     : "",
        api_key_and   => $api_key ? "&amp;key=" . $api_key : ""
    );
}

sub generate_opds_item {

    my ( $mojo, $id ) = @_;

    # If the user authentified to this via an API key, we need to carry it over to the OPDS links.
    my $api_key = $mojo->req->param('key');

    # Detailed pages just return a single entry instead of all the archives.
    my $arcdata = get_opds_data($id);

    return $mojo->render_to_string(
        template      => "opds_entry",
        arc           => $arcdata,
        title         => $mojo->LRR_CONF->get_htmltitle,
        motd          => $mojo->LRR_CONF->get_motd,
        version       => $mojo->LRR_VERSION,
        api_key_query => $api_key ? "?key=" . $api_key     : "",
        api_key_and   => $api_key ? "&amp;key=" . $api_key : ""
    );
}

sub get_opds_data {

    my $id    = shift;
    my $redis = LANraragi::Model::Config->get_redis;

    my $file = get_archive_path( $redis, $id );
    unless ( -e $file ) { return; }

    my $arcdata = get_archive_json( $redis, $id );
    $redis->quit();
    return unless $arcdata;

    _derive_opds_fields($arcdata);
    return $arcdata;
}

# Derive OPDS-specific fields onto an already-fetched archive JSON hashref.
# Pure (no Redis): dateadded/author/language/circle/event are parsed from the
# tags string, lastreaddate from lastreadtime, and mimetype from the extension
# that build_json already populated. Kept separate so generate_opds_catalog
# can batch the Redis fetch and only do this per-row derivation.
sub _derive_opds_fields {
    my ($arcdata) = @_;

    my $tags = $arcdata->{tags};

    # Parse date from the date_added tag, and convert from unix time to ISO 8601.
    my $date = get_tag_with_namespace( "date_added", $tags, "0" );
    $arcdata->{dateadded} = strftime( "%Y-%m-%dT%H:%M:%SZ", gmtime($date) );

    # Infer a few OPDS-related fields from the tags
    $arcdata->{author}   = get_tag_with_namespace( "artist",   $tags, "" );
    $arcdata->{language} = get_tag_with_namespace( "language", $tags, "" );
    $arcdata->{circle}   = get_tag_with_namespace( "group",    $tags, "" );
    $arcdata->{event}    = get_tag_with_namespace( "event",    $tags, "" );

    # Application/zip is universally hated by all readers so it's better to use x-cbz and x-cbr here.
    # Derive from the extension build_json already populated (no extra Redis read).
    my $ext = $arcdata->{extension} // "";
    if ( $ext eq "pdf" ) {
        $arcdata->{mimetype} = "application/pdf";
    } elsif ( $ext eq "rar" || $ext eq "cbr" ) {
        $arcdata->{mimetype} = "application/x-cbr";
    } elsif ( $ext eq "epub" ) {
        $arcdata->{mimetype} = "application/epub+zip";
    } elsif ( $ext eq "cbw" ) {
        $arcdata->{mimetype} = "application/xml";
    } else {
        $arcdata->{mimetype} = "application/x-cbz";
    }

    if ( $arcdata->{lastreadtime} > 0 ) {
        $arcdata->{lastreaddate} = strftime( "%Y-%m-%dT%H:%M:%SZ", gmtime( $arcdata->{lastreadtime} ) );
    }

    for ( values %{$arcdata} ) { $_ = xml_escape($_); }

    return;
}

sub render_archive_page {

    my ( $mojo, $id, $page ) = @_;

    my $redis   = $mojo->LRR_CONF->get_redis;
    my $archive = get_archive_path( $redis, $id );

    # Parse archive to get its list of images
    my @images = get_filelist( $archive, $id );

    # If the page number is invalid, use the first page.
    if ( $page > scalar @images ) {
        $page = 1;
    }

    # If the page number is valid, render the page.
    my $image = $images[ $page - 1 ];

    # Use the same code as /api/page to serve the file.
    # This is clean, but might serve other types than JPEG depending on how the archive is built..
    # We could force resizing here to always have JPEG. (TODO?)
    LANraragi::Model::Archive::serve_page( $mojo, $id, $image );
}

1;
