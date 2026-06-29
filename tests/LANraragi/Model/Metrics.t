use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi::Model::Metrics;

package FakeMetricsRedis {
    sub new { return bless { hashes => {}, deleted => [] }, shift }

    sub hincrby {
        my ( $self, $key, $field, $amount ) = @_;
        $self->{hashes}{$key}{$field} += $amount;
        return $self->{hashes}{$key}{$field};
    }

    sub hincrbyfloat {
        my ( $self, $key, $field, $amount ) = @_;
        $self->{hashes}{$key}{$field} += $amount;
        return $self->{hashes}{$key}{$field};
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

    sub quit { return 1 }
}

package main;

my $record = LANraragi::Model::Metrics->can("record_image_serving_metrics");
my $export = LANraragi::Model::Metrics->can("get_prometheus_image_metrics");

ok( $record, "image serving metrics can be recorded" );
ok( $export, "image serving metrics can be exported to Prometheus" );

SKIP: {
    skip "image metrics are not implemented yet", 13 unless $record && $export;

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

done_testing();
