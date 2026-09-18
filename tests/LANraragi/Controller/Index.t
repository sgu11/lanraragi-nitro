use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi::Controller::Index;

package FakeIndexRedis {
    sub new { bless { quit => 0 }, shift }
    sub quit { $_[0]->{quit}++; return 1 }
}

package FakeIndexConfig {
    sub new { bless { redis => $_[1] }, $_[0] }
    sub get_redis { return $_[0]->{redis} }
}

package FakeIndexController {
    sub new { bless { config => $_[1] }, $_[0] }
    sub LRR_CONF { return $_[0]->{config} }
    sub redirect_to { $_[0]->{redirect} = $_[1]; return $_[1] }
}

package main;

my $redis = FakeIndexRedis->new;
my $controller = FakeIndexController->new( FakeIndexConfig->new($redis) );

no warnings 'redefine';
local *LANraragi::Controller::Index::all_archive_ids = sub { return () };

LANraragi::Controller::Index::random_archive($controller);
is( $controller->{redirect}, '/', 'empty library returns to the index instead of looping forever' );
is( $redis->{quit}, 1, 'empty-library random lookup closes Redis' );

done_testing();
