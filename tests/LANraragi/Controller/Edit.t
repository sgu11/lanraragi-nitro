use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Mojolicious;

use LANraragi::Controller::Edit;

package FakeEditRedis {
    sub new { bless { exists_calls => [] }, shift }

    sub exists {
        my ( $self, $key ) = @_;
        die "Redis exists called with missing key\n" unless defined $key && length $key;
        push @{ $self->{exists_calls} }, $key;
        return 0;
    }
}

package FakeEditConfig {
    our $redis;
    sub get_redis { $redis }
}

package main;

sub build_tester {
    my $app = Mojolicious->new;
    $app->routes->namespaces(['LANraragi::Controller']);
    $app->helper( LRR_CONF => sub { FakeEditConfig:: } );
    $app->routes->get('/')->to(cb => sub { shift->render(text => 'index') })->name('index');
    $app->routes->get('/edit')->to('edit#index');

    return Test::Mojo->new($app);
}

note("GET /edit without id redirects before checking Redis");
{
    local $FakeEditConfig::redis = FakeEditRedis->new;

    my $t = build_tester();
    $t->get_ok('/edit')->status_is(302);
    is( scalar @{ $FakeEditConfig::redis->{exists_calls} }, 0, "missing id does not query Redis" );
}

note("GET /edit with unknown archive id still redirects after lookup");
{
    local $FakeEditConfig::redis = FakeEditRedis->new;

    my $t = build_tester();
    $t->get_ok('/edit?id=missing-archive')->status_is(302);
    is_deeply( $FakeEditConfig::redis->{exists_calls}, ["missing-archive"], "archive id is checked in Redis" );
}

done_testing();
