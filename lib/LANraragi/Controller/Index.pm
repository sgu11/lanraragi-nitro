package LANraragi::Controller::Index;
use Mojo::Base 'Mojolicious::Controller';

use utf8;
use URI::Escape;
use Redis;
use Encode;
use File::Basename;
use List::Util qw(shuffle);

use LANraragi::Utils::Generic qw(generate_themes_header);
use LANraragi::Utils::Database qw(all_archive_ids);
use LANraragi::Utils::Path    qw(get_archive_path);

# This endpoint is technically superseded by /api/search/random, but it's still useful in the Reader.
sub random_archive {
    my $self    = shift;
    my $archive = "";

    my $redis = $self->LRR_CONF->get_redis;

    # Iterate over the bounded archive index in random order. This terminates
    # immediately for an empty library and also tolerates stale/missing files.
    foreach my $candidate ( shuffle all_archive_ids($redis) ) {
        next unless length($candidate) == 40;
        next unless $redis->type($candidate) eq "hash";
        next unless $redis->hexists( $candidate, "file" );

        my $arclocation = get_archive_path( $redis, $candidate );
        next unless defined($arclocation) && -e $arclocation;
        $archive = $candidate;
        last;
    }

    $redis->quit();

    return $self->redirect_to('/') unless $archive;
    $self->redirect_to( '/reader?id=' . $archive );
}

# Render the index template with a few prefilled arguments.
# Most of the work is done in JS these days.
sub index {

    my $self = shift;

    #Checking if the user still has the default password enabled
    my $passcheck = ( $self->LRR_CONF->is_default_password && $self->LRR_CONF->enable_pass );

    my $userlogged = $self->LRR_CONF->enable_pass == 0 || $self->session('is_logged');

    # Get static category list to populate the right-click menu
    my @categories = LANraragi::Model::Category->get_static_category_list;

    $self->render(
        template     => "index",
        version      => $self->LRR_VERSION,
        title        => $self->LRR_CONF->get_htmltitle,
        descstr      => $self->LRR_DESC,
        userlogged   => $userlogged,
        categories   => \@categories,
        motd         => $self->LRR_CONF->get_motd,
        csshead      => generate_themes_header($self),
        usingdefpass => $passcheck
    );
}

1;
