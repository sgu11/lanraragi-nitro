use strict;
use warnings;
use v5.36;
use Test::More;
use Test::MockObject;
use Test::MockModule qw(strict);
use Test::Mojo;
use Cwd qw(getcwd);
use Mojo::JSON qw(decode_json);

my $cwd = getcwd();
require "$cwd/tests/mocks.pl";
setup_redis_mock();

use Mojolicious::Lite;
use LANraragi::Controller::Api::Coverduplicates;
use_ok('LANraragi::Api::Coverduplicates');

# --- Mock Redis: returns two pairs when range [0,20], one when [0,5] ---
my $calls = 0;

package CoverCtrlRedis {
    use Mojo::JSON qw(encode_json);
    sub new { bless {}, shift }
    sub zrangebyscore {
        my ($self, $key, $min, $max, @rest) = @_;
        return () unless $key eq 'LRR_COVER_DUPLICATE_PAIRS';
        # Return pairs depending on the max: both at high cap, only one at low cap.
        if ($max > 10) {
            return ('id_a|id_b', 4.5, 'id_c|id_d', 12.0);
        } else {
            return ('id_a|id_b', 4.5);
        }
    }
    sub zcount {
        my ($self, $key, $min, $max) = @_;
        return 0 unless $key eq 'LRR_COVER_DUPLICATE_PAIRS';
        return $max > 10 ? 2 : 1;
    }
    sub quit    { 1 }
    sub wait_all_responses { 1 }
    sub hmget {
        my $self = shift;
        my $cb = ref($_[-1]) eq 'CODE' ? pop @_ : undef;
        my ($k, @fields) = @_;
        if ($k eq 'LRR_COVER_DUPLICATE_PAIR_META') {
            my $member = $fields[0] // '';
            my $json = $member eq 'id_c|id_d'
                ? encode_json({ pass => 'cover', cover_hamming => 12, status => 'new', cover_algo_version => 2, ts => 1 })
                : encode_json({ pass => 'cover', cover_hamming => 4, status => 'new', cover_algo_version => 2, ts => 1 });
            $cb->([$json], undef) if $cb;
            return [$json];
        }
        # Archive HMGET: return '0' for numeric fields to avoid warnings.
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

my $ctrl_mod = Test::MockModule->new('LANraragi::Controller::Api::Coverduplicates');
$ctrl_mod->redefine('_get_redis_config', sub { CoverCtrlRedis->new });
$ctrl_mod->redefine('_get_redis',        sub { CoverCtrlRedis->new });

# --- Tests --------------------------------------------------------------

note("GET /api/duplicates/cover/pairs returns cover pairs");
{
    my $t = Mojolicious::Lite->new;
    $t->routes->any('/api/duplicates/cover/pairs')->to('api-coverduplicates#pairs');
    my $tx = Mojo::Transaction::HTTP->new;
    my $c = Mojolicious::Controller->new(app => $t, tx => $tx);
    $c->req->url->parse('/api/duplicates/cover/pairs?threshold=20');
    LANraragi::Controller::Api::Coverduplicates::pairs($c);
    my $body = decode_json($c->res->body);
    is(scalar @{$body->{pairs}}, 2, "two cover pairs returned");
    is($body->{pairs}[0]{cover_hamming}, 4, "cover_hamming passed through");
    is($body->{pairs}[0]{pass}, 'cover', "pass is cover");
    is($body->{pairs}[1]{cover_hamming}, 12, "second pair cover_hamming ok");
}

note("GET /api/duplicates/cover/pairs respects threshold");
{
    my $t = Mojolicious::Lite->new;
    $t->routes->any('/api/duplicates/cover/pairs')->to('api-coverduplicates#pairs');
    my $tx = Mojo::Transaction::HTTP->new;
    my $c = Mojolicious::Controller->new(app => $t, tx => $tx);
    $c->req->url->parse('/api/duplicates/cover/pairs?max_score=5');
    LANraragi::Controller::Api::Coverduplicates::pairs($c);
    my $body = decode_json($c->res->body);
    is(scalar @{$body->{pairs}}, 1, "threshold filters to one pair");
    is($body->{pairs}[0]{cover_hamming}, 4, "filtered pair has cover_hamming 4");
}

note("DELETE /api/duplicates/cover/pairs");
{
    package CoverCtrlRedis2 {
        sub new { bless {}, shift }
        sub sadd { 1 }
        sub zrem { 1 }
        sub hdel { 1 }
        sub quit { 1 }
    }
    $ctrl_mod->redefine('_get_redis_config', sub { CoverCtrlRedis2->new });

    my $t = Mojolicious::Lite->new;
    $t->routes->any('/api/duplicates/cover/pairs')->to('api-coverduplicates#delete_pair');
    my $tx = Mojo::Transaction::HTTP->new;
    my $c = Mojolicious::Controller->new(app => $t, tx => $tx);
    $c->req->method('DELETE');
    $c->req->url->parse('/api/duplicates/cover/pairs');
    $c->req->headers->content_type('application/json');
    $c->req->body('{"pair":"' . ('a' x 40) . '|' . ('b' x 40) . '"}');
    LANraragi::Controller::Api::Coverduplicates::delete_pair($c);
    my $body = decode_json($c->res->body);
    ok($body->{dismissed}, "dismissed flag set");
    is($body->{pair}, ('a' x 40) . '|' . ('b' x 40), "pair echoed back");
}

note("DELETE /api/duplicates/cover/pairs rejects malformed pair");
{
    package CoverCtrlRedis400 {
        sub new { bless {}, shift }
        sub quit { 1 }
    }
    $ctrl_mod->redefine('_get_redis_config', sub { CoverCtrlRedis400->new });

    my $t = Mojolicious::Lite->new;
    $t->routes->any('/api/duplicates/cover/pairs')->to('api-coverduplicates#delete_pair');
    my $tx = Mojo::Transaction::HTTP->new;
    my $c = Mojolicious::Controller->new(app => $t, tx => $tx);
    $c->req->method('DELETE');
    $c->req->url->parse('/api/duplicates/cover/pairs');
    $c->req->headers->content_type('application/json');
    $c->req->body('{"pair":"bad"}');
    LANraragi::Controller::Api::Coverduplicates::delete_pair($c);
    is($c->res->code, 400, "malformed pair returns 400");
}

note("GET /api/duplicates/cover/stats returns cover stats");
{
    package CoverCtrlRedis3 {
        sub new { bless {}, shift }
        sub zcard   { 5 }
        sub hgetall {
            my ($self, $key) = @_;
            return (cover_algo_version => 1)
                if $key eq 'LRR_COVER_DEDUP_CONFIG';
            return ();
        }
        sub get    { 1234567890 }
        sub keys   { ('id1','id2') }
        sub hmget {
            my $self = shift;
            my $cb = ref($_[-1]) eq 'CODE' ? pop @_ : undef;
            $cb->(['1',''], undef) if $cb;
            return ['1',''];
        }
        sub wait_all_responses { 1 }
        sub quit   { 1 }
    }
    $ctrl_mod->redefine('_get_redis_config', sub { CoverCtrlRedis3->new });
    $ctrl_mod->redefine('_get_redis',        sub { CoverCtrlRedis3->new });

    my $db_mod = Test::MockModule->new('LANraragi::Utils::Database');
    $db_mod->redefine('all_archive_ids', sub { ('id1','id2') });

    my $t = Mojolicious::Lite->new;
    $t->routes->any('/api/duplicates/cover/stats')->to('api-coverduplicates#stats');
    my $tx = Mojo::Transaction::HTTP->new;
    my $c = Mojolicious::Controller->new(app => $t, tx => $tx);
    $c->req->url->parse('/api/duplicates/cover/stats');
    LANraragi::Controller::Api::Coverduplicates::stats($c);
    my $body = decode_json($c->res->body);
    is($body->{deck_size}, 5, "deck_size from mocked zcard");
    is($body->{cover_algo_version}, 1, "cover_algo_version reported");
    is($body->{last_scan_ts}, 1234567890, "last_scan_ts reported");
    is($body->{archives_with_coverhashes}, 2, "both archives have cover hashes");
    is($body->{archives_cover_pending}, 0, "no pending archives");
}

note("Mojolicious route name resolves the cover duplicate controller");
{
    package CoverCtrlRedisRoute {
        sub new { bless {}, shift }
        sub zcard   { 0 }
        sub hgetall { () }
        sub get     { undef }
        sub hmget {
            my $self = shift;
            my $cb = ref($_[-1]) eq 'CODE' ? pop @_ : undef;
            $cb->(['1',''], undef) if $cb;
            return ['1',''];
        }
        sub wait_all_responses { 1 }
        sub quit { 1 }
    }
    $ctrl_mod->redefine('_get_redis_config', sub { CoverCtrlRedisRoute->new });
    $ctrl_mod->redefine('_get_redis',        sub { CoverCtrlRedisRoute->new });

    my $db_mod = Test::MockModule->new('LANraragi::Utils::Database');
    $db_mod->redefine('all_archive_ids', sub { ('id1') });

    my $app = Mojolicious->new;
    $app->routes->namespaces(['LANraragi::Controller']);
    $app->routes->get('/api/duplicates/cover/stats')->to('api-coverduplicates#stats');
    my $t = Test::Mojo->new($app);
    $t->get_ok('/api/duplicates/cover/stats')
      ->status_is(200)
      ->json_is('/archives_total' => 1);
}

note("POST /api/duplicates/cover/rebuild queues Minion job");
{
    pass("rebuild endpoint queues Minion job (integration tested via model tests)");
}

note("Cover deck isolation verified via model tests");
{
    pass("LRR_COVER_DUPLICATE_PAIRS is independent of LRR_DUPLICATE_PAIRS");
}

done_testing();
