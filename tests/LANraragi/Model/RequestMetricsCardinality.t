use v5.36;
use strict;
use warnings;
use Test::More;
use Test::MockModule qw(strict);
use Time::HiRes qw(gettimeofday tv_interval);
use Mojolicious;
use LANraragi::Model::Metrics;
require './tests/redis_test_server.pl';
my ($redis, $guard) = start_test_redis();
my $config = Test::MockModule->new('LANraragi::Model::Config');
$config->redefine(get_redis_metrics => sub { Redis->new(sock => "$guard->{dir}/redis.sock") });
my $app = Mojolicious->new;
my $wildcard = $app->routes->any('/js/:version/*filepath');
my $nested = $app->routes->under('/api')->get('/archives/:id/pages/:page');
is(LANraragi::Utils::Metrics::extract_route_endpoint($wildcard), '/js/:version/*filepath', 'wildcard label preserves template only');
is(LANraragi::Utils::Metrics::extract_route_endpoint($nested), '/api/archives/:id/pages/:page', 'nested API route retains complete stable template');
for my $i (1 .. 1001) {
    my $c = $app->build_controller;
    $c->req->url->path("/js/arbitrary-version-$i/missing-$i.js");
    $c->req->method('GET');
    $c->res->code(404);
    $c->match->endpoint($wildcard);
    $c->stash('metrics.start_time' => [gettimeofday]);
    LANraragi::Model::Metrics::collect_request_metrics($c);
}
{
    no warnings 'redefine';
    my $later = Time::HiRes::time() + 60;
    local *Time::HiRes::time = sub { $later };
    LANraragi::Model::Metrics::flush_request_metrics_to_redis();
}
my @keys = $redis->keys('metrics:worker:*');
is(scalar @keys, 1, '1001 matched arbitrary asset paths create one metric hash');
is($redis->hget($keys[0], 'count'), 1001, 'bounded label retains every request count');
my $start = [gettimeofday];
my @output = LANraragi::Model::Metrics::get_prometheus_api_metrics();
my $elapsed = tv_interval($start);
like(join("\n", @output), qr/endpoint="\/js\/:version\/\*filepath",method="GET"\} 1001/, 'export aggregates wildcard requests');
note(sprintf '1001 missing asset paths: %d Redis hash, %d exposition lines, %.3f ms export', scalar @keys, scalar @output, $elapsed * 1000);
for my $i (1 .. 25) {
    my $c = $app->build_controller;
    $c->req->method('CUSTOM' . ('X' x $i));
    $c->res->code(405);
    $c->match->endpoint($wildcard);
    $c->stash('metrics.start_time' => [gettimeofday]);
    LANraragi::Model::Metrics::collect_request_metrics($c);
}
{
    no warnings 'redefine';
    my $later = Time::HiRes::time() + 120;
    local *Time::HiRes::time = sub { $later };
    LANraragi::Model::Metrics::flush_request_metrics_to_redis();
}
@keys = $redis->keys('metrics:worker:*');
is(scalar @keys, 2, 'custom methods share one OTHER label');

SKIP: {
    skip 'Linux procfs required', 3 unless -r '/proc/self/stat';
    local $0 = 'LRR) test worker';
    my $sample = LANraragi::Utils::Metrics::read_proc_stat();
    my ($user, $system) = times;
    cmp_ok(abs($sample->{utime} - $user), '<=', 0.02, 'spaced and parenthesized comm preserves user CPU time');
    cmp_ok(abs($sample->{stime} - $system), '<=', 0.02, 'spaced comm preserves system CPU time');
    cmp_ok(abs($sample->{starttime} - $^T), '<=', 2, 'spaced comm preserves process start timestamp');
}
done_testing();
