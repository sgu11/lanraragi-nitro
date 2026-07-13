use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Mojolicious;

use LANraragi::Controller::Duplicates;

my $app = Mojolicious->new;
$app->routes->namespaces(['LANraragi::Controller']);
$app->routes->get('/duplicates_custom')->to(
    cb => sub { shift->render( text => 'canonical duplicate review' ) }
);
$app->routes->get('/duplicates')->to('duplicates#index');

my $t = Test::Mojo->new($app);
$t->get_ok('/duplicates')->status_is(302)
  ->header_is( Location => '/duplicates_custom' );
$t->get_ok('/duplicates_custom')->status_is(200)
  ->content_is('canonical duplicate review');

done_testing();
