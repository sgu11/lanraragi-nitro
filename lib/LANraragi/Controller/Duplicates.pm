package LANraragi::Controller::Duplicates;
use Mojo::Base 'Mojolicious::Controller';
use utf8;

# The upstream duplicate-group page consumes LRR_DUPLICATE_GROUPS, while the
# fork's active duplicate finder stores its review deck in pair-based keys.
# Keep old bookmarks working without exposing a producer/consumer mismatch.
sub index {
    my $self = shift;
    return $self->redirect_to( $self->url_for('/duplicates_custom') );
}

1;
