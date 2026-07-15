use strict;
use warnings;
use v5.36;

use Mojo::URL;
use Storable qw(nfreeze);
use Test::More;

use_ok('LANraragi::Controller::Reader');

{
    package ReaderTestRedis;
    sub new { bless { value => $_[1], error => $_[2], quit => 0 }, $_[0] }
    sub hget { die $_[0]{error} if $_[0]{error}; return $_[0]{value} }
    sub quit { $_[0]{quit}++; return 1 }

    package ReaderTestConfig;
    sub new { bless { redis => $_[1] }, $_[0] }
    sub get_redis { $_[0]{redis} }

    package ReaderTestController;
    sub new { bless { config => $_[1] }, $_[0] }
    sub LRR_CONF { $_[0]{config} }
    sub url_for { Mojo::URL->new($_[1]) }
}

sub controller_for ( $value, $error = undef ) {
    my $redis = ReaderTestRedis->new( $value, $error );
    my $config = ReaderTestConfig->new($redis);
    return ( ReaderTestController->new($config), $redis );
}

my ( $warm, $warm_redis ) = controller_for( nfreeze( [ 'folder/a b?#%.jpg' ] ) );
is(
    LANraragi::Controller::Reader::_first_page_url( $warm, 'abc123' ),
    '/api/archives/abc123/page?path=folder/a%20b%3F%23%25.jpg',
    'warm cache produces one escaped first-page URL'
);
is( $warm_redis->{quit}, 1, 'warm-cache Redis handle is closed' );

for my $case (
    [ undef,          undef,          'missing cache' ],
    [ '',             undef,          'empty cache' ],
    [ 'not-storable', undef,          'malformed cache' ],
    [ undef,          "redis down\n", 'Redis failure' ],
) {
    my ( $controller, $redis ) = controller_for( $case->[0], $case->[1] );
    is( LANraragi::Controller::Reader::_first_page_url( $controller, 'abc123' ), '', "$case->[2] leaves preload empty" );
    is( $redis->{quit}, 1, "$case->[2] closes Redis handle" );
}

done_testing();
