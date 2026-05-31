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
    sub quit { 1 }
    sub wait_all_responses { 1 }
    sub hmget {
        my $self = shift;
        my $cb = ref($_[-1]) eq 'CODE' ? pop @_ : undef;
        my ($k, @fields) = @_;
        # For pair meta HMGET, return per_page/pcount_delta JSON.
        if ($k eq 'LRR_DUPLICATE_PAIR_META') {
            my $member = $fields[0] // '';
            my $json = $member eq 'id_c|id_d'
                ? '{"relation":"duplicate","confidence":0.82,"suggested_action":"delete_lower_quality","suggested_delete":"id_c","suggested_keep":"id_d","risk_flags":[],"lead_hamming":2,"title_score":0.95,"per_page":[1,2],"pcount_delta":3,"algo_version":2,"ts":1}'
                : '{"relation":"subset","confidence":0.9,"suggested_action":"delete_subset","suggested_delete":"id_a","suggested_keep":"id_b","risk_flags":["deleting_preferred_language_subset"],"lead_hamming":1,"title_score":1,"per_page":[1,2,3,4,5],"pcount_delta":3,"algo_version":2,"ts":1}';
            $cb->([$json], undef) if $cb;
            return [$json];
        }
        # For archive HMGET, return title/name/tags/pagecount/arcsize.
        my @vals = map {
            $_ eq 'title'     ? "Title" :
            $_ eq 'name'      ? "name"  :
            $_ eq 'tags'      ? "t"     :
            $_ eq 'pagecount' ? "100"   :
            $_ eq 'arcsize'   ? "0"     : ""
        } @fields;
        $cb->(\@vals, undef) if $cb;
        return \@vals;
    }
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
is($body->{filtered_total}, 2, "filtered_total reported");
is($body->{pairs}[0]{relation}, "subset", "relation metadata passed through");
is($body->{pairs}[0]{suggested_delete}, "id_a", "suggested delete passed through");
is_deeply($body->{pairs}[0]{risk_flags}, ["deleting_preferred_language_subset"], "risk flags passed through");

note("GET /api/duplicates/pairs supports relation filtering");
{
    my $tx = Mojo::Transaction::HTTP->new;
    my $c = Mojolicious::Controller->new(app => $t, tx => $tx);
    $c->req->url->parse('/api/duplicates/pairs?max_score=20&relation=duplicate');

    LANraragi::Controller::Api::Duplicates::pairs($c);

    my $body = decode_json($c->res->body);
    is(scalar @{$body->{pairs}}, 1, "relation filter returns one matching pair");
    is($body->{filtered_total}, 1, "filtered_total counts relation-filtered pairs");
    is($body->{pairs}[0]{relation}, "duplicate", "duplicate relation returned");
}

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

note("DELETE /api/duplicates/pairs returns 400 for malformed pair");
{
    package FakeRedis400 {
        sub new { bless {}, shift }
        sub quit { 1 }
    }
    $controller_module->redefine('_get_redis_config', sub { FakeRedis400->new });

    my $t = Mojolicious::Lite->new;
    $t->routes->any('/api/duplicates/pairs')->to('api-duplicates#delete_pair');

    my $tx = Mojo::Transaction::HTTP->new;
    my $c  = Mojolicious::Controller->new(app => $t, tx => $tx);
    $c->req->method('DELETE');
    $c->req->url->parse('/api/duplicates/pairs');
    $c->req->headers->content_type('application/json');
    $c->req->body('{"pair":"not-valid"}');

    LANraragi::Controller::Api::Duplicates::delete_pair($c);

    is($c->res->code, 400, "malformed pair returns 400");
    my $body = decode_json($c->res->body);
    ok($body->{error}, "error key present in 400 response");
}

note("GET /api/duplicates/stats reports counts and config");
{
    package FakeRedis3 {
        sub new { bless {}, shift }
        sub zcard   { 17 }
        sub hgetall {
            my ($self, $key) = @_;
            return (algo_version => 1, pages_sampled => 5, pcount_tolerance_pct => 20,
                    loose_max_score => 40, candidate_pair_cap => 1_000_000)
                if $key eq 'LRR_DEDUP_CONFIG';
            return ();
        }
        sub get  { 1234567890 }
        sub keys { ('id1','id2','id3') }
        sub hget { my ($self, $k, $f) = @_; $f eq 'pagehashes_v' ? '1' : '' }
        # Pipelined HMGET: callback fires synchronously; reply is arrayref of values.
        sub hmget {
            my $self = shift;
            my $cb = ref($_[-1]) eq 'CODE' ? pop @_ : undef;
            my ($k, @fields) = @_;
            my @vals = map { $_ eq 'pagehashes_v' ? '1' : '' } @fields;
            $cb->(\@vals, undef) if $cb;
            return \@vals;
        }
        sub wait_all_responses { 1 }
        sub quit { 1 }
    }
    $controller_module->redefine('_get_redis_config', sub { FakeRedis3->new });
    $controller_module->redefine('_get_redis',        sub { FakeRedis3->new });

    # all_archive_ids needs to be stubbed too — it walks redis->keys and calls hexists.
    my $db_mod = Test::MockModule->new('LANraragi::Utils::Database');
    $db_mod->redefine('all_archive_ids', sub { ('id1','id2','id3') });

    my $t = Mojolicious::Lite->new;
    $t->routes->any('/api/duplicates/stats')->to('api-duplicates#stats');
    my $tx = Mojo::Transaction::HTTP->new;
    my $c  = Mojolicious::Controller->new(app => $t, tx => $tx);
    $c->req->url->parse('/api/duplicates/stats');

    LANraragi::Controller::Api::Duplicates::stats($c);
    my $body = decode_json($c->res->body);
    is($body->{total_pairs}, 17, "total_pairs from zcard");
    is($body->{config}{algo_version}, 1, "algo_version reported");
    is($body->{last_scan_ts}, 1234567890, "last_scan_ts reported");
}

done_testing();
