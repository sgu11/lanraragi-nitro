package LANraragi::Controller::DuplicatesCustom;
use Mojo::Base 'Mojolicious::Controller';
use utf8;

use LANraragi::Utils::Generic qw(generate_themes_header);

# Fork-only relation-aware duplicate review shell.
sub index {
    my $self = shift;

    $self->render(
        template => "duplicates_custom",
        title    => $self->LRR_CONF->get_htmltitle,
        csshead  => generate_themes_header($self),
        version  => $self->LRR_VERSION,
    );
}

1;
