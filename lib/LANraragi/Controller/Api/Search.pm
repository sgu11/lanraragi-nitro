package LANraragi::Controller::Api::Search;
use Mojo::Base 'Mojolicious::Controller';

use feature qw(say signatures);
no warnings 'experimental::signatures';

use List::Util  qw(min);
use Time::HiRes qw(time);

use LANraragi::Model::Metrics;
use LANraragi::Model::Search;
use LANraragi::Utils::Generic   qw(render_api_response);
use LANraragi::Utils::Database  qw(invalidate_cache get_archive_json_multi);
use LANraragi::Utils::Tachiyomi qw(
  get_tachiyomi_response_cache is_tachiyomi_client set_tachiyomi_random_cache
  set_tachiyomi_search_cache tachiyomi_cache_key
);

# Undocumented API matching the Datatables spec.
sub handle_datatables ($self) {

    my $req = $self->req;

    my $draw   = $req->param('draw');
    my $start  = $req->param('start');
    my $length = $req->param('length');

    # Jesus christ what the fuck datatables
    my $filter    = $req->param('search[value]');
    my $sortindex = $req->param('order[0][column]');
    my $sortorder = $req->param('order[0][dir]');
    my $sortkey   = $req->param("columns[$sortindex][name]");

    # Saner params we add manually
    my $hidecompleted = $req->param('hidecompleted') // "false";
    my $grouptanks = $req->param('grouptanks') // "true";

    # See if specific column searches were made
    my $i              = 0;
    my $categoryfilter = "";
    my $newfilter      = 0;
    my $untaggedfilter = 0;

    while ( $req->param("columns[$i][name]") ) {

        # Collection (tags column)
        if ( $req->param("columns[$i][name]") eq "tags" ) {
            $categoryfilter = $req->param("columns[$i][search][value]");

            # Specific hacks for the built-in newonly/untagged selectors
            # Those have hardcoded 'category' IDs
            if ( $categoryfilter eq "NEW_ONLY" ) {
                $newfilter      = 1;
                $categoryfilter = "";
            }

            if ( $categoryfilter eq "UNTAGGED_ONLY" ) {
                $untaggedfilter = 1;
                $categoryfilter = "";
            }

        }
        $i++;
    }

    $sortorder = ( $sortorder && $sortorder eq 'desc' ) ? 1 : 0;

    my ( $total, $filtered, @ids ) =
      LANraragi::Model::Search::do_search( $filter, $categoryfilter, $start, $sortkey, $sortorder, $newfilter, $untaggedfilter, 
        $grouptanks eq "true",
        $hidecompleted eq "true" );

    $self->render( json => get_datatables_object( $draw, $total, $filtered, @ids ) );
}

# Public search API with saner parameters.
sub handle_api {

    my $self = shift->openapi->valid_input or return;
    my $req  = $self->req;

    my $tachiyomi = is_tachiyomi_client($self);

    my $filter        = $req->param('filter');
    my $category      = $req->param('category') || "";
    my $start         = $req->param('start')    || 0;
    my $sortkey       = $req->param('sortby');
    my $sortorder     = $req->param('order');
    my $newfilter     = $req->param('newonly')       // "false";
    my $untaggedf     = $req->param('untaggedonly')  // "false";
    my $grouptanks    = $req->param('groupby_tanks') // ( $tachiyomi ? "false" : "true" );
    my $hidecompleted = $req->param('hidecompleted') // "false";

    $sortorder = ( $sortorder && $sortorder eq 'desc' ) ? 1 : 0;

    my $cachekey;
    if ( $tachiyomi && ( $sortkey // "" ) ne "lastread" ) {
        $cachekey = tachiyomi_cache_key(
            $self, "search", $filter, $category, $start, $sortkey, $sortorder, $newfilter,
            $untaggedf, $grouptanks, $hidecompleted
        );
        if ( my $cached = get_tachiyomi_response_cache($cachekey) ) {
            return $self->render( openapi => $cached );
        }
    }

    my ( $total, $filtered, @ids ) = LANraragi::Model::Search::do_search(
        $filter,    $category,            $start,               $sortkey,
        $sortorder, $newfilter eq "true" ? 1 : 0, $untaggedf eq "true" ? 1 : 0, $grouptanks eq "true" ? 1 : 0,
        $hidecompleted eq "true" ? 1 : 0
    );

    if ( $total eq -1 && $filtered eq -1 ) {

        # Search engine not initialized
        $self->render(
            openapi => {
                recordsTotal    => 0,
                recordsFiltered => 0,
                data            => []
            },
            status => 204
        );
    } else {
        my $response = get_api_object( $total, $filtered, @ids );
        set_tachiyomi_search_cache( $cachekey, $response ) if $cachekey;
        $self->render( openapi => $response );
    }
}

# Search endpoint returning only archive IDs for a query.
sub handle_api_ids {

    my $self = shift->openapi->valid_input or return;
    my $req  = $self->req;

    my $filter        = $req->param('filter');
    my $category      = $req->param('category') || "";
    my $start         = $req->param('start')    || 0;
    my $sortkey       = $req->param('sortby');
    my $sortorder     = $req->param('order');
    my $newfilter     = $req->param('newonly')       // "false";
    my $untaggedf     = $req->param('untaggedonly')  // "false";
    my $grouptanks    = $req->param('groupby_tanks') // "true";
    my $hidecompleted = $req->param('hidecompleted') // "false";

    $sortorder = ( $sortorder && $sortorder eq 'desc' ) ? 1 : 0;

    my ( $total, $filtered, @ids ) = LANraragi::Model::Search::do_search(
        $filter,    $category,            $start,               $sortkey,
        $sortorder, $newfilter eq "true", $untaggedf eq "true", $grouptanks eq "true",
        $hidecompleted eq "true"
    );

    if ( $total eq -1 && $filtered eq -1 ) {

        # Search engine not initialized
        $self->render(
            openapi => {
                recordsTotal    => 0,
                recordsFiltered => 0,
                data            => []
            },
            status => 204
        );
    } else {
        $self->render(
            openapi => {
                recordsTotal    => $total,
                recordsFiltered => $filtered,
                data            => \@ids
            }
        );
    }
}

sub clear_cache {
    invalidate_cache();
    render_api_response( shift, "clear_cache" );
}

# Pull random archives out of the given search
sub get_random_archives {

    my $self = shift->openapi->valid_input or return;
    my $req  = $self->req;

    my $tachiyomi = is_tachiyomi_client($self);

    my $filter        = $req->param('filter');
    my $category      = $req->param('category')      || "";
    my $newfilter     = $req->param('newonly')       // "false";
    my $untaggedf     = $req->param('untaggedonly')  // "false";
    my $grouptanks    = $req->param('groupby_tanks') // "false";
    my $hidecompleted = $req->param('hidecompleted') // "false";
    my $random_count  = $req->param('count')         || 5;

    my $cachekey;
    if ( $tachiyomi && $random_count == 1 ) {
        $cachekey = tachiyomi_cache_key(
            $self, "random", $filter, $category, $newfilter, $untaggedf,
            $grouptanks, $hidecompleted, $random_count
        );
        if ( my $cached = get_tachiyomi_response_cache($cachekey) ) {
            return $self->render( openapi => $cached );
        }
    }

    # Use the search engine to get IDs matching the filter/category selection, with start=-1 to get all data
    my ( $total, $filtered, @ids ) = LANraragi::Model::Search::do_search(
        $filter, $category, -1, "title", 0,
        $newfilter eq "true",
        $untaggedf eq "true",
        $grouptanks eq "true",
        $hidecompleted eq "true"
    );
    my @random_ids;

    $random_count = min( $random_count, scalar(@ids) );

    # Get random IDs out of the array
    for ( 1 .. $random_count ) {
        my $random_index = int( rand( scalar(@ids) ) );
        push( @random_ids, splice( @ids, $random_index, 1 ) );
    }

    my @data = get_archive_json_multi(@random_ids);
    my $response = {
        data         => \@data,
        recordsTotal => $random_count
    };
    set_tachiyomi_random_cache( $cachekey, $response ) if $cachekey;
    $self->render( openapi => $response );
}

# Builds the JSON rows for a page of search results, timing the row-build
# phase for the search metrics.
sub _build_rows (@ids) {

    my $rowbuild_start = time();
    my @data           = get_archive_json_multi(@ids);

    LANraragi::Model::Metrics::record_search_rowbuild_metrics(
        duration_seconds => time() - $rowbuild_start,
        rows             => scalar @ids,
    );

    return @data;
}

# Creates a Datatables-compatible json from the given data.
sub get_datatables_object ( $draw, $total, $totalsearched, @ids ) {

    # Get archive data
    my @data = _build_rows(@ids);

    # Create json object matching the datatables structure
    return {
        draw            => $draw,
        recordsTotal    => $total,
        recordsFiltered => $totalsearched,
        data            => \@data
    };
}

# Creates an API json from the given data.
sub get_api_object ( $total, $totalsearched, @ids ) {

    # Get archive data
    my @data = _build_rows(@ids);

    # Create json object matching the datatables structure
    return {
        recordsTotal    => $total,
        recordsFiltered => $totalsearched,
        data            => \@data
    };
}

1;
