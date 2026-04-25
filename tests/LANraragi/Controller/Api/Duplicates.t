use strict;
use warnings;
use v5.36;
use Test::More;
use Test::MockObject;
use Test::MockModule qw(strict);
use Cwd qw(getcwd);
use Mojo::JSON qw(decode_json);

my $cwd = getcwd();
require "$cwd/tests/mocks.pl";
setup_redis_mock();

use Mojolicious::Lite;
use LANraragi::Controller::Api::Duplicates;

# Fake Redis surface for the controller's test scope.
package FakeRedis {
    sub new { bless {}, shift }
    sub zrangebyscore { my ($self, $key, $min, $max, @rest) = @_; ('id_a|id_b', 4.5, 'id_c|id_d', 12.0) }
    sub zcount { 2 }
    sub hget   { my ($self, $k, $f) = @_; '{"per_page":[1,2,3,4,5],"pcount_delta":3,"algo_version":1,"ts":1}' }
    sub hgetall { my ($self, $k) = @_; (title => "Title", name => "name", tags => "t", filename => "n.zip", pagecount => 100) }
    sub quit { 1 }
}

my $controller_module = Test::MockModule->new('LANraragi::Controller::Api::Duplicates');
$controller_module->redefine('_get_redis_config', sub { FakeRedis->new });
$controller_module->redefine('_get_redis',        sub { FakeRedis->new });

my $t = Mojolicious::Lite->new;
$t->routes->any('/api/duplicates/pairs')->to('api-duplicates#pairs');

use Mojolicious::Controller;
my $tx = Mojo::Transaction::HTTP->new;
my $c = Mojolicious::Controller->new(app => $t, tx => $tx);
$c->req->url->parse('/api/duplicates/pairs?max_score=20');

LANraragi::Controller::Api::Duplicates::pairs($c);

my $body = decode_json($c->res->body);
is(scalar @{$body->{pairs}}, 2, "returns 2 pairs from mocked zrangebyscore");
is($body->{pairs}[0]{id_a}, "id_a", "first pair id_a parsed");
is($body->{pairs}[0]{id_b}, "id_b", "first pair id_b parsed");
cmp_ok($body->{pairs}[0]{score}, "==", 4.5, "score passed through");
is($body->{total}, 2, "total reported");

note("DELETE /api/duplicates/pairs adds member to dismissed set and removes from index");
{
    my @sadd_seen;
    my @zrem_seen;
    my @hdel_seen;
    package FakeRedis2 {
        sub new { bless {}, shift }
        sub sadd { my ($self, $k, $m) = @_; push @sadd_seen, [$k, $m]; 1 }
        sub zrem { my ($self, $k, $m) = @_; push @zrem_seen, [$k, $m]; 1 }
        sub hdel { my ($self, $k, $m) = @_; push @hdel_seen, [$k, $m]; 1 }
        sub quit { 1 }
    }
    $controller_module->redefine('_get_redis_config', sub { FakeRedis2->new });

    my $t = Mojolicious::Lite->new;
    $t->routes->any('/api/duplicates/pairs')->to('api-duplicates#delete_pair');

    my $tx = Mojo::Transaction::HTTP->new;
    my $c  = Mojolicious::Controller->new(app => $t, tx => $tx);
    $c->req->method('DELETE');
    $c->req->url->parse('/api/duplicates/pairs');
    $c->req->headers->content_type('application/json');
    $c->req->body('{"pair":"' . ('a' x 40) . '|' . ('b' x 40) . '"}');

    LANraragi::Controller::Api::Duplicates::delete_pair($c);

    my $expected_pair = ('a' x 40) . '|' . ('b' x 40);
    is_deeply($sadd_seen[0], ['LRR_DEDUP_DISMISSED',     $expected_pair], "added to dismissed set");
    is_deeply($zrem_seen[0], ['LRR_DUPLICATE_PAIRS',     $expected_pair], "removed from pair sorted set");
    is_deeply($hdel_seen[0], ['LRR_DUPLICATE_PAIR_META', $expected_pair], "removed from meta hash");

    my $body = decode_json($c->res->body);
    ok($body->{dismissed}, "response reports dismissed:true");
}

done_testing();
