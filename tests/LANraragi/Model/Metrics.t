use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi::Model::Metrics;

package FakeMetricsRedis {
    sub new {
        return bless {
            hashes => {}, deleted => [], pending => [], wait_all_responses_count => 0,
            callback_write_count => 0, synchronous_write_count => 0,
        }, shift;
    }

    sub _increment {
        my ( $self, $key, $field, $amount, $callback ) = @_;
        my $apply = sub {
            $self->{hashes}{$key}{$field} += $amount;
            $callback->( $self->{hashes}{$key}{$field}, undef ) if $callback;
        };
        if ($callback) {
            $self->{callback_write_count}++;
            push @{ $self->{pending} }, $apply;
            return;
        }
        $self->{synchronous_write_count}++;
        $apply->();
        return $self->{hashes}{$key}{$field};
    }

    sub hincrby {
        my ( $self, $key, $field, $amount, $callback ) = @_;
        return $self->_increment( $key, $field, $amount, $callback );
    }

    sub hincrbyfloat {
        my ( $self, $key, $field, $amount, $callback ) = @_;
        return $self->_increment( $key, $field, $amount, $callback );
    }

    sub hgetall {
        my ( $self, $key ) = @_;
        return %{ $self->{hashes}{$key} || {} };
    }

    sub keys {
        my ( $self, $pattern ) = @_;
        my $regex = quotemeta($pattern);
        $regex =~ s/\\\*/.*/g;
        return grep { /^$regex$/ } keys %{ $self->{hashes} };
    }

    sub del {
        my ( $self, @keys ) = @_;
        push @{ $self->{deleted} }, @keys;
        delete @{ $self->{hashes} }{@keys};
        return scalar @keys;
    }

    sub wait_all_responses {
        my ($self) = @_;
        $self->{wait_all_responses_count}++;
        $_->() for splice @{ $self->{pending} };
        return 1;
    }

    sub quit { return 1 }
}

package main;

my $record = LANraragi::Model::Metrics->can("record_image_serving_metrics");
my $export = LANraragi::Model::Metrics->can("get_prometheus_image_metrics");

ok( $record, "image serving metrics can be recorded" );
ok( $export, "image serving metrics can be exported to Prometheus" );

SKIP: {
    skip "image metrics are not implemented yet", 16 unless $record && $export;

    my $redis = FakeMetricsRedis->new;

    no warnings 'redefine';
    local *LANraragi::Model::Config::enable_metrics = sub { return 1 };
    local *LANraragi::Model::Config::get_redis_metrics = sub { return $redis };

    LANraragi::Model::Metrics::record_image_serving_metrics(
        kind                  => "page",
        variant               => "resized",
        cache_status          => "miss",
        duration_seconds      => 0.25,
        extract_seconds       => 0.10,
        crop_seconds          => 0.07,
        crop_dims_seconds     => 0.03,
        resize_seconds        => 0.05,
        bytes                 => 1024,
    );

    my $key = "metrics:image:page:resized:miss";
    is( $redis->{hashes}{$key}{count}, 1, "records request count" );
    is( $redis->{hashes}{$key}{duration_sum}, 0.25, "records total duration" );
    is( $redis->{hashes}{$key}{extract_duration_sum}, 0.10, "records extract duration" );
    is( $redis->{hashes}{$key}{crop_duration_sum}, 0.07, "records crop duration" );
    is( $redis->{hashes}{$key}{crop_dims_duration_sum}, 0.03, "records crop dimension-probe duration separately from detector" );
    is( $redis->{hashes}{$key}{resize_duration_sum}, 0.05, "records resize duration" );
    is( $redis->{hashes}{$key}{bytes_sum}, 1024, "records response bytes" );
    is( $redis->{wait_all_responses_count}, 1, "image metric writes are pipelined with wait_all_responses" );
    is( $redis->{callback_write_count}, 7, "every image metric write uses a Redis callback" );
    is( $redis->{synchronous_write_count}, 0, "image metric hot path performs no synchronous Redis writes" );

    my $prometheus = join "\n", LANraragi::Model::Metrics::get_prometheus_image_metrics();
    like( $prometheus, qr/# TYPE lanraragi_image_serving_requests_total counter/, "exports request counter metadata" );
    like( $prometheus, qr/lanraragi_image_serving_requests_total\{kind="page",variant="resized",cache="miss"\} 1/, "exports request counter" );
    like( $prometheus, qr/lanraragi_image_serving_duration_seconds_total\{kind="page",variant="resized",cache="miss"\} 0\.25/, "exports total duration" );
    like( $prometheus, qr/lanraragi_image_serving_extract_seconds_total\{kind="page",variant="resized",cache="miss"\} 0\.1/, "exports extract duration" );
    like( $prometheus, qr/lanraragi_image_serving_crop_seconds_total\{kind="page",variant="resized",cache="miss"\} 0\.07/, "exports crop duration" );
    like( $prometheus, qr/lanraragi_image_serving_crop_dims_seconds_total\{kind="page",variant="resized",cache="miss"\} 0\.03/, "exports crop dimension-probe duration separately" );
    like( $prometheus, qr/lanraragi_image_serving_resize_seconds_total\{kind="page",variant="resized",cache="miss"\} 0\.05/, "exports resize duration" );
    like( $prometheus, qr/lanraragi_image_serving_bytes_total\{kind="page",variant="resized",cache="miss"\} 1024/, "exports response bytes" );
}

note('request endpoint encoding is reversible and Prometheus exposes status and latency buckets');
{
    my $redis = FakeMetricsRedis->new;
    my $endpoint = "/duplicates_custom";
    my $encoded = LANraragi::Model::Metrics::_encode_endpoint($endpoint);
    is( LANraragi::Model::Metrics::_decode_endpoint($encoded), $endpoint, 'underscores survive endpoint round-trip' );

    my $key = "metrics:worker:123:v2:${encoded}:GET";
    $redis->{hashes}{$key} = {
        count => 2,
        duration_sum => 0.3,
        request_size_sum => 0,
        response_size_sum => 512,
        status_200 => 1,
        status_500 => 1,
        duration_bucket_0_25 => 2,
    };

    no warnings 'redefine';
    local *LANraragi::Model::Config::get_redis_metrics = sub { return $redis };
    my $prometheus = join "\n", LANraragi::Model::Metrics::get_prometheus_api_metrics();
    like( $prometheus, qr/endpoint="\/duplicates_custom",method="GET"/, 'endpoint label is not corrupted at underscores' );
    like( $prometheus, qr/lanraragi_api_responses_total\{endpoint="\/duplicates_custom",method="GET",status_code="500"\} 1/, 'exports response status code' );
    like( $prometheus, qr/lanraragi_api_duration_seconds_bucket\{endpoint="\/duplicates_custom",method="GET",le="0\.25"\} 2/, 'exports cumulative latency bucket' );
    like( $prometheus, qr/lanraragi_api_duration_seconds_count\{endpoint="\/duplicates_custom",method="GET"\} 2/, 'exports histogram count' );
}

note('startup cleanup includes search metrics');
{
    my $redis = FakeMetricsRedis->new;
    $redis->{hashes}{'metrics:search:engine:hit'} = { count => 3 };

    no warnings 'redefine';
    local *LANraragi::Model::Config::get_redis_metrics = sub { return $redis };
    local *LANraragi::Model::Metrics::get_logger = sub {
        return bless {}, 'FakeMetricsCleanupLogger';
    };
    LANraragi::Model::Metrics::cleanup_metrics();
    ok( !exists $redis->{hashes}{'metrics:search:engine:hit'}, 'search counters do not leak across restarts' );
}

package FakeMetricsCleanupLogger {
    sub info { 1 }
    sub error { 1 }
}

package main;

done_testing();
