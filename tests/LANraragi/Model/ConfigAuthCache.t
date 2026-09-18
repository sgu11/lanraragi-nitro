use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi::Model::Config;

my $apikey = "first-key";
{
    no warnings qw(once redefine);
    local *LANraragi::Model::Config::get_apikey = sub { return $apikey };

    LANraragi::Model::Config::invalidate_auth_cache();
    my ( $first_key, $first_bearer ) = LANraragi::Model::Config::get_apikey_and_bearer();
    is( $first_key, "first-key", "API key cache starts with the current value" );
    like( $first_bearer, qr/^Bearer /, "API key cache builds a bearer value" );

    $apikey = "second-key";
    my ( $cached_key, $cached_bearer ) = LANraragi::Model::Config::get_apikey_and_bearer();
    is( $cached_key, "first-key", "API key remains cached before invalidation" );
    is( $cached_bearer, $first_bearer, "bearer remains cached before invalidation" );

    LANraragi::Model::Config::invalidate_config_cache();
    my ( $fresh_key, $fresh_bearer ) = LANraragi::Model::Config::get_apikey_and_bearer();
    is( $fresh_key, "second-key", "config invalidation refreshes the API key cache" );
    isnt( $fresh_bearer, $first_bearer, "config invalidation refreshes the bearer cache" );
}

done_testing();
