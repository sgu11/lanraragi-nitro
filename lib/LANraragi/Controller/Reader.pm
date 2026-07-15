package LANraragi::Controller::Reader;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::URL;

use Encode;
use URI::Escape;
use Storable qw(thaw);

use LANraragi::Utils::Generic qw(generate_themes_header);
use LANraragi::Utils::Redis   qw(redis_decode);

# This action will render a template
sub index {
    my $self = shift;

    if ( $self->req->param('id') ) {

        my $id = $self->req->param('id');
        my $char = chop $id;
        if ( $char ne "/" ) {
            $id .= $char;
        }

        # Allow adding to static categories
        my @categories     = LANraragi::Model::Category->get_static_category_list;
        my @arc_categories = LANraragi::Model::Category::get_categories_containing_archive( $self->req->param('id') );

        # Get query string from referrer URL, if there's one
        my $referrer = $self->req->headers->referrer;
        my $query    = "";

        if ($referrer) {
            $query = Mojo::URL->new($referrer)->query->to_string;
        }

        # Precompute the first page URL only if the filelist cache is already warm.
        # Setting src= on the <img> in the template lets the browser start the page
        # fetch during HTML parse instead of waiting for the /files API call. On a
        # cold cache we intentionally skip this — scanning the archive synchronously
        # here would add the very latency we're trying to avoid. JS populates src
        # after /files responds in that case.
        my $first_page_url = _first_page_url( $self, $id );

        $self->render(
            template       => "reader",
            title          => $self->LRR_CONF->get_htmltitle,
            use_local      => $self->LRR_CONF->enable_localprogress,
            auth_progress  => $self->LRR_CONF->enable_authprogress,
            id             => $id,
            first_page_url => $first_page_url,
            is_tank        => ( $id =~ /^TANK_/ ? 1 : 0 ),
            arc_categories => \@arc_categories,
            categories     => \@categories,
            csshead        => generate_themes_header($self),
            version        => $self->LRR_VERSION,
            ref_query      => $query,
            userlogged     => $self->LRR_CONF->enable_pass == 0 || $self->session('is_logged')
        );
    } else {

        # No parameters back the fuck off
        $self->redirect_to('index');
    }
}

sub _first_page_url {
    my ( $self, $id ) = @_;
    my $redis;
    my $url = "";
    eval {
        $redis = $self->LRR_CONF->get_redis;
        my $cached = $redis->hget( $id, "pagefiles" );
        if ( defined $cached && length $cached ) {
            my $list = thaw($cached);
            if ( ref $list eq 'ARRAY' && @$list ) {
                my $imgpath = redis_decode( $list->[0] );
                $imgpath = uri_escape_utf8($imgpath);
                $imgpath =~ s!%2F!/!g;
                $url = $self->url_for("/api/archives/$id/page?path=$imgpath")->path_query;
            }
        }
    };
    eval { $redis->quit } if $redis;
    return $url;
}

1;
