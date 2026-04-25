package LANraragi::Controller::Duplicates;
use Mojo::Base 'Mojolicious::Controller';
use utf8;

use LANraragi::Utils::Generic qw(generate_themes_header);

# Renders the dedup page shell. The page fetches data from /api/duplicates/*.
sub index {
    my $self = shift;

    $self->render(
        template => "duplicates",
        title    => $self->LRR_CONF->get_htmltitle,
        csshead  => generate_themes_header($self),
    );
}

1;
