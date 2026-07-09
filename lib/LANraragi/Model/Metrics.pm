package LANraragi::Model::Metrics;

use strict;
use warnings;
use utf8;
use Time::HiRes                 qw(gettimeofday tv_interval);
use Mojo::JSON                  qw(encode_json decode_json);
use Encode                      qw(encode_utf8 decode_utf8);

use LANraragi::Model::Config;
use LANraragi::Model::Stats;
use LANraragi::Utils::Logging   qw(get_logger);
use LANraragi::Utils::Metrics;

use constant IS_LINUX => ( $^O eq 'linux' );
use constant IS_MACOS => ( $^O eq 'darwin' );
use constant IS_WIN32 => ( $^O eq 'MSWin32' );

use constant REQUEST_METRICS_FLUSH_INTERVAL     => 1.0;   # min seconds between flushes
use constant REQUEST_METRICS_FLUSH_MAX_UPDATES  => 1000;  # max buffered updates before forced flush
use constant REQUEST_DURATION_BUCKETS => ( 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 );

my %REQUEST_METRICS_CACHE            = ();
my $REQUEST_METRICS_LAST_FLUSH       = 0;
my $REQUEST_METRICS_UPDATE_COUNT     = 0;

sub _encode_endpoint {
    my ($endpoint) = @_;
    return unpack( 'H*', encode_utf8( $endpoint // '' ) );
}

sub _decode_endpoint {
    my ($encoded) = @_;
    return decode_utf8( pack( 'H*', $encoded // '' ) );
}

sub _bucket_field {
    my ($upper_bound) = @_;
    my $field = "$upper_bound";
    $field =~ s/\./_/g;
    return "duration_bucket_$field";
}

# Get all metrics in Prometheus exposition format.
sub get_prometheus_metrics {
    my $controller          = shift;
    my @api_metrics         = get_prometheus_api_metrics();
    my @image_metrics       = get_prometheus_image_metrics();
    my @search_metrics      = get_prometheus_search_metrics();
    my @process_metrics     = get_prometheus_process_metrics();
    my @stats_metrics       = get_prometheus_stats_metrics($controller);
    my @output              = (@api_metrics, @image_metrics, @search_metrics, @process_metrics, @stats_metrics);
    push @output, "# EOF";
    return join("\n", @output) . "\n";
}

# Get API request metrics
sub get_prometheus_api_metrics {
    my $metrics_redis = LANraragi::Model::Config->get_redis_metrics;
    return () unless $metrics_redis;

    my @output;
    my @metric_keys = $metrics_redis->keys("metrics:worker:*");
    my %aggregated_api_metrics;
    my %active_workers;

    foreach my $key ( @metric_keys ) {

        # v2 keys use a reversible UTF-8 hex endpoint. Legacy underscore keys
        # remain readable until the next startup cleanup.
        my ( $worker_pid, $endpoint, $method );
        if ( $key =~ /^metrics:worker:(\d+):v2:([0-9a-f]+):([A-Z]+)$/ ) {
            ( $worker_pid, $endpoint, $method ) = ( $1, _decode_endpoint($2), $3 );
        } elsif ( $key =~ /^metrics:worker:(\d+):(.+)_([A-Z]+)$/ ) {
            ( $worker_pid, $endpoint, $method ) = ( $1, $2, $3 );
            $endpoint =~ s/_/\//g;
        }
        if ( defined $worker_pid ) {
            $active_workers{$worker_pid} = 1;

            next unless $endpoint && $method;

            my %metric_data = $metrics_redis->hgetall($key);
            next unless %metric_data;

            my $escaped_endpoint = LANraragi::Utils::Metrics::escape_label_value($endpoint);
            my $escaped_method = LANraragi::Utils::Metrics::escape_label_value($method);
            my $labels = qq{endpoint="$escaped_endpoint",method="$escaped_method"};

            # Aggregate metrics
            $aggregated_api_metrics{"lanraragi_api_requests_total"}{$labels} += $metric_data{count} || 0;
            $aggregated_api_metrics{"lanraragi_api_duration_seconds_total"}{$labels} += $metric_data{duration_sum} || 0;
            $aggregated_api_metrics{"lanraragi_http_request_size_bytes_total"}{$labels} += $metric_data{request_size_sum} || 0;
            $aggregated_api_metrics{"lanraragi_http_response_size_bytes_total"}{$labels} += $metric_data{response_size_sum} || 0;

            foreach my $field ( keys %metric_data ) {
                if ( $field =~ /^status_(\d{3})$/ ) {
                    my $status_labels = qq{$labels,status_code="$1"};
                    $aggregated_api_metrics{"lanraragi_api_responses_total"}{$status_labels} += $metric_data{$field} || 0;
                }
            }

            foreach my $upper_bound ( REQUEST_DURATION_BUCKETS ) {
                my $field = _bucket_field($upper_bound);
                my $bucket_labels = qq{$labels,le="$upper_bound"};
                $aggregated_api_metrics{"lanraragi_api_duration_seconds_bucket"}{$bucket_labels} += $metric_data{$field} || 0;
            }
        }
    }

    push @output, "# TYPE lanraragi_api_requests_total counter";
    push @output, "# HELP lanraragi_api_requests_total Total number of API requests";
    foreach my $labels ( sort keys %{ $aggregated_api_metrics{"lanraragi_api_requests_total"} || {} } ) {
        my $value = $aggregated_api_metrics{"lanraragi_api_requests_total"}{$labels};
        push @output, "lanraragi_api_requests_total{$labels} $value";
    }

    push @output, "# TYPE lanraragi_api_responses_total counter";
    push @output, "# HELP lanraragi_api_responses_total Total API responses by HTTP status code";
    foreach my $labels ( sort keys %{ $aggregated_api_metrics{"lanraragi_api_responses_total"} || {} } ) {
        push @output, "lanraragi_api_responses_total{$labels} "
          . $aggregated_api_metrics{"lanraragi_api_responses_total"}{$labels};
    }

    push @output, "# TYPE lanraragi_api_duration_seconds histogram";
    push @output, "# UNIT lanraragi_api_duration_seconds seconds";
    push @output, "# HELP lanraragi_api_duration_seconds API request duration histogram";
    foreach my $labels ( sort keys %{ $aggregated_api_metrics{"lanraragi_api_duration_seconds_bucket"} || {} } ) {
        push @output, "lanraragi_api_duration_seconds_bucket{$labels} "
          . $aggregated_api_metrics{"lanraragi_api_duration_seconds_bucket"}{$labels};
    }
    foreach my $labels ( sort keys %{ $aggregated_api_metrics{"lanraragi_api_requests_total"} || {} } ) {
        my $count = $aggregated_api_metrics{"lanraragi_api_requests_total"}{$labels};
        my $sum = $aggregated_api_metrics{"lanraragi_api_duration_seconds_total"}{$labels} || 0;
        push @output, "lanraragi_api_duration_seconds_bucket{$labels,le=\"+Inf\"} $count";
        push @output, "lanraragi_api_duration_seconds_count{$labels} $count";
        push @output, "lanraragi_api_duration_seconds_sum{$labels} $sum";
    }

    push @output, "# TYPE lanraragi_api_duration_seconds_total counter";
    push @output, "# UNIT lanraragi_api_duration_seconds_total seconds";
    push @output, "# HELP lanraragi_api_duration_seconds_total Total time spent processing API requests";
    foreach my $labels ( sort keys %{ $aggregated_api_metrics{"lanraragi_api_duration_seconds_total"} || {} } ) {
        my $value = $aggregated_api_metrics{"lanraragi_api_duration_seconds_total"}{$labels};
        push @output, "lanraragi_api_duration_seconds_total{$labels} $value";
    }

    push @output, "# TYPE lanraragi_http_request_size_bytes_total counter";
    push @output, "# UNIT lanraragi_http_request_size_bytes_total bytes";
    push @output, "# HELP lanraragi_http_request_size_bytes_total Total bytes received in HTTP requests";
    foreach my $labels ( sort keys %{ $aggregated_api_metrics{"lanraragi_http_request_size_bytes_total"} || {} } ) {
        my $value = $aggregated_api_metrics{"lanraragi_http_request_size_bytes_total"}{$labels};
        push @output, "lanraragi_http_request_size_bytes_total{$labels} $value";
    }

    push @output, "# TYPE lanraragi_http_response_size_bytes_total counter";
    push @output, "# UNIT lanraragi_http_response_size_bytes_total bytes";
    push @output, "# HELP lanraragi_http_response_size_bytes_total Total bytes sent in HTTP responses";
    foreach my $labels ( sort keys %{ $aggregated_api_metrics{"lanraragi_http_response_size_bytes_total"} || {} } ) {
        my $value = $aggregated_api_metrics{"lanraragi_http_response_size_bytes_total"}{$labels};
        push @output, "lanraragi_http_response_size_bytes_total{$labels} $value";
    }

    # API worker count metric
    my $worker_count = scalar keys %active_workers;
    push @output, "# TYPE lanraragi_active_workers gauge";
    push @output, "# HELP lanraragi_active_workers Number of active LANraragi workers";
    push @output, "lanraragi_active_workers $worker_count";

    $metrics_redis->quit();
    return @output;
}

sub _safe_image_metric_label {
    my $value = shift;
    $value //= "unknown";
    $value = lc $value;
    $value =~ s/[^a-z0-9_-]/_/g;
    return $value;
}

sub record_image_serving_metrics {
    my (%args) = @_;

    return unless LANraragi::Model::Config->enable_metrics;

    my $kind         = _safe_image_metric_label( $args{kind} );
    my $variant      = _safe_image_metric_label( $args{variant} );
    my $cache_status = _safe_image_metric_label( $args{cache_status} );
    my $key          = "metrics:image:$kind:$variant:$cache_status";

    my $redis = LANraragi::Model::Config->get_redis_metrics;
    return unless $redis;

    my $error;
    eval {
        $redis->hincrby( $key, "count", 1, sub { } );
        $redis->hincrbyfloat( $key, "duration_sum",         $args{duration_seconds} // 0, sub { } );
        $redis->hincrbyfloat( $key, "extract_duration_sum", $args{extract_seconds}  // 0, sub { } );
        $redis->hincrbyfloat( $key, "crop_duration_sum",    $args{crop_seconds}     // 0, sub { } );
        $redis->hincrbyfloat( $key, "crop_dims_duration_sum", $args{crop_dims_seconds} // 0, sub { } );
        $redis->hincrbyfloat( $key, "resize_duration_sum",  $args{resize_seconds}   // 0, sub { } );
        $redis->hincrby( $key, "bytes_sum", $args{bytes} // 0, sub { } );
        # Pipeline the seven increments into one round-trip (REDIS-3) instead of
        # seven serialized hincrby/hincrbyfloat calls per page-flip.
        $redis->wait_all_responses;
    };
    $error = $@;
    $redis->quit();

    if ($error) {
        my $logger = get_logger( "Metrics", "lanraragi" );
        $logger->error("Failed to update image serving metrics: $error");
    }
}

# Search-engine phase timings, keyed by searchcache status (hit/miss/bypass).
# Phase sums let the Prometheus side compute where do_search wall time goes:
# preamble (counts + connections), cacheget (check_cache GET + thaw), filter
# (token intersection), sort (order build/fetch + apply).
sub record_search_metrics {
    my (%args) = @_;

    return unless LANraragi::Model::Config->enable_metrics;

    my $cache_status = _safe_image_metric_label( $args{cache_status} );
    my $key          = "metrics:search:engine:$cache_status";

    my $redis = LANraragi::Model::Config->get_redis_metrics;
    return unless $redis;

    my $error;
    eval {
        $redis->hincrby( $key, "count", 1, sub { } );
        $redis->hincrbyfloat( $key, "duration_sum", $args{duration_seconds} // 0, sub { } );
        $redis->hincrbyfloat( $key, "preamble_sum", $args{preamble_seconds} // 0, sub { } );
        $redis->hincrbyfloat( $key, "cacheget_sum", $args{cacheget_seconds} // 0, sub { } );
        $redis->hincrbyfloat( $key, "filter_sum",   $args{filter_seconds}   // 0, sub { } );
        $redis->hincrbyfloat( $key, "sort_sum",     $args{sort_seconds}     // 0, sub { } );
        $redis->wait_all_responses;
    };
    $error = $@;
    $redis->quit();

    if ($error) {
        my $logger = get_logger( "Metrics", "lanraragi" );
        $logger->error("Failed to update search metrics: $error");
    }
}

# Row-build (per-page JSON assembly) timing for search responses.
sub record_search_rowbuild_metrics {
    my (%args) = @_;

    return unless LANraragi::Model::Config->enable_metrics;

    my $key = "metrics:search:rowbuild:all";

    my $redis = LANraragi::Model::Config->get_redis_metrics;
    return unless $redis;

    my $error;
    eval {
        $redis->hincrby( $key, "count", 1, sub { } );
        $redis->hincrbyfloat( $key, "duration_sum", $args{duration_seconds} // 0, sub { } );
        $redis->hincrby( $key, "rows_sum", $args{rows} // 0, sub { } );
        $redis->wait_all_responses;
    };
    $error = $@;
    $redis->quit();

    if ($error) {
        my $logger = get_logger( "Metrics", "lanraragi" );
        $logger->error("Failed to update search rowbuild metrics: $error");
    }
}

sub get_prometheus_search_metrics {
    my $metrics_redis = LANraragi::Model::Config->get_redis_metrics;
    return () unless $metrics_redis;

    my @output;
    my @metric_keys = $metrics_redis->keys("metrics:search:*");
    my %aggregated;
    my %rowbuild;

    foreach my $key (@metric_keys) {
        next unless $key =~ /^metrics:search:([^:]+):([^:]+)$/;
        my ( $kind, $label ) = ( $1, $2 );
        my %metric_data = $metrics_redis->hgetall($key);
        next unless %metric_data;

        if ( $kind eq "rowbuild" ) {
            $rowbuild{count}        += $metric_data{count}        || 0;
            $rowbuild{duration_sum} += $metric_data{duration_sum} || 0;
            $rowbuild{rows_sum}     += $metric_data{rows_sum}     || 0;
            next;
        }

        my $labels = sprintf( 'cache="%s"', LANraragi::Utils::Metrics::escape_label_value($label) );
        $aggregated{"lanraragi_search_requests_total"}{$labels}         += $metric_data{count}        || 0;
        $aggregated{"lanraragi_search_duration_seconds_total"}{$labels} += $metric_data{duration_sum} || 0;
        $aggregated{"lanraragi_search_preamble_seconds_total"}{$labels} += $metric_data{preamble_sum} || 0;
        $aggregated{"lanraragi_search_cacheget_seconds_total"}{$labels} += $metric_data{cacheget_sum} || 0;
        $aggregated{"lanraragi_search_filter_seconds_total"}{$labels}   += $metric_data{filter_sum}   || 0;
        $aggregated{"lanraragi_search_sort_seconds_total"}{$labels}     += $metric_data{sort_sum}     || 0;
    }

    my %help = (
        lanraragi_search_requests_total         => "Total number of do_search calls",
        lanraragi_search_duration_seconds_total => "Total do_search wall time",
        lanraragi_search_preamble_seconds_total => "Total time in do_search preamble (counts + connections)",
        lanraragi_search_cacheget_seconds_total => "Total time fetching/thawing the search result cache",
        lanraragi_search_filter_seconds_total   => "Total time filtering archives (token intersection)",
        lanraragi_search_sort_seconds_total     => "Total time sorting results (order build/fetch + apply)",
    );

    foreach my $metric ( sort keys %help ) {
        push @output, "# TYPE $metric counter";
        push @output, "# HELP $metric $help{$metric}";
        foreach my $labels ( sort keys %{ $aggregated{$metric} || {} } ) {
            push @output, "$metric\{$labels} " . $aggregated{$metric}{$labels};
        }
    }

    if ( $rowbuild{count} ) {
        push @output, "# TYPE lanraragi_search_rowbuild_seconds_total counter";
        push @output, "# HELP lanraragi_search_rowbuild_seconds_total Total time building search result rows";
        push @output, "lanraragi_search_rowbuild_seconds_total $rowbuild{duration_sum}";
        push @output, "# TYPE lanraragi_search_rowbuild_rows_total counter";
        push @output, "# HELP lanraragi_search_rowbuild_rows_total Total search result rows built";
        push @output, "lanraragi_search_rowbuild_rows_total $rowbuild{rows_sum}";
        push @output, "# TYPE lanraragi_search_rowbuild_requests_total counter";
        push @output, "# HELP lanraragi_search_rowbuild_requests_total Total row-build batches";
        push @output, "lanraragi_search_rowbuild_requests_total $rowbuild{count}";
    }

    $metrics_redis->quit();
    return @output;
}

sub get_prometheus_image_metrics {
    my $metrics_redis = LANraragi::Model::Config->get_redis_metrics;
    return () unless $metrics_redis;

    my @output;
    my @metric_keys = $metrics_redis->keys("metrics:image:*");
    my %aggregated_image_metrics;

    foreach my $key (@metric_keys) {
        next unless $key =~ /^metrics:image:([^:]+):([^:]+):([^:]+)$/;
        my ( $kind, $variant, $cache_status ) = ( $1, $2, $3 );
        my %metric_data = $metrics_redis->hgetall($key);
        next unless %metric_data;

        my $labels = sprintf(
            'kind="%s",variant="%s",cache="%s"',
            LANraragi::Utils::Metrics::escape_label_value($kind),
            LANraragi::Utils::Metrics::escape_label_value($variant),
            LANraragi::Utils::Metrics::escape_label_value($cache_status)
        );

        $aggregated_image_metrics{"lanraragi_image_serving_requests_total"}{$labels}       += $metric_data{count}                 || 0;
        $aggregated_image_metrics{"lanraragi_image_serving_duration_seconds_total"}{$labels} += $metric_data{duration_sum}          || 0;
        $aggregated_image_metrics{"lanraragi_image_serving_extract_seconds_total"}{$labels}  += $metric_data{extract_duration_sum}  || 0;
        $aggregated_image_metrics{"lanraragi_image_serving_crop_seconds_total"}{$labels}     += $metric_data{crop_duration_sum}     || 0;
        $aggregated_image_metrics{"lanraragi_image_serving_crop_dims_seconds_total"}{$labels} += $metric_data{crop_dims_duration_sum} || 0;
        $aggregated_image_metrics{"lanraragi_image_serving_resize_seconds_total"}{$labels}   += $metric_data{resize_duration_sum}   || 0;
        $aggregated_image_metrics{"lanraragi_image_serving_bytes_total"}{$labels}            += $metric_data{bytes_sum}             || 0;
    }

    push @output, "# TYPE lanraragi_image_serving_requests_total counter";
    push @output, "# HELP lanraragi_image_serving_requests_total Total number of image serving requests";
    foreach my $labels ( sort keys %{ $aggregated_image_metrics{"lanraragi_image_serving_requests_total"} || {} } ) {
        my $value = $aggregated_image_metrics{"lanraragi_image_serving_requests_total"}{$labels};
        push @output, "lanraragi_image_serving_requests_total{$labels} $value";
    }

    push @output, "# TYPE lanraragi_image_serving_duration_seconds_total counter";
    push @output, "# UNIT lanraragi_image_serving_duration_seconds_total seconds";
    push @output, "# HELP lanraragi_image_serving_duration_seconds_total Total time spent serving images";
    foreach my $labels ( sort keys %{ $aggregated_image_metrics{"lanraragi_image_serving_duration_seconds_total"} || {} } ) {
        my $value = $aggregated_image_metrics{"lanraragi_image_serving_duration_seconds_total"}{$labels};
        push @output, "lanraragi_image_serving_duration_seconds_total{$labels} $value";
    }

    push @output, "# TYPE lanraragi_image_serving_extract_seconds_total counter";
    push @output, "# UNIT lanraragi_image_serving_extract_seconds_total seconds";
    push @output, "# HELP lanraragi_image_serving_extract_seconds_total Total archive extraction time while serving images";
    foreach my $labels ( sort keys %{ $aggregated_image_metrics{"lanraragi_image_serving_extract_seconds_total"} || {} } ) {
        my $value = $aggregated_image_metrics{"lanraragi_image_serving_extract_seconds_total"}{$labels};
        push @output, "lanraragi_image_serving_extract_seconds_total{$labels} $value";
    }

    push @output, "# TYPE lanraragi_image_serving_crop_seconds_total counter";
    push @output, "# UNIT lanraragi_image_serving_crop_seconds_total seconds";
    push @output, "# HELP lanraragi_image_serving_crop_seconds_total Total border crop time while serving images";
    foreach my $labels ( sort keys %{ $aggregated_image_metrics{"lanraragi_image_serving_crop_seconds_total"} || {} } ) {
        my $value = $aggregated_image_metrics{"lanraragi_image_serving_crop_seconds_total"}{$labels};
        push @output, "lanraragi_image_serving_crop_seconds_total{$labels} $value";
    }

    push @output, "# TYPE lanraragi_image_serving_crop_dims_seconds_total counter";
    push @output, "# UNIT lanraragi_image_serving_crop_dims_seconds_total seconds";
    push @output, "# HELP lanraragi_image_serving_crop_dims_seconds_total Time in _crop_area_savings_ratio (two full-resolution decodes for width/height), separate from crop_seconds detector time";
    foreach my $labels ( sort keys %{ $aggregated_image_metrics{"lanraragi_image_serving_crop_dims_seconds_total"} || {} } ) {
        my $value = $aggregated_image_metrics{"lanraragi_image_serving_crop_dims_seconds_total"}{$labels};
        push @output, "lanraragi_image_serving_crop_dims_seconds_total{$labels} $value";
    }

    push @output, "# TYPE lanraragi_image_serving_resize_seconds_total counter";
    push @output, "# UNIT lanraragi_image_serving_resize_seconds_total seconds";
    push @output, "# HELP lanraragi_image_serving_resize_seconds_total Total resize time while serving images";
    foreach my $labels ( sort keys %{ $aggregated_image_metrics{"lanraragi_image_serving_resize_seconds_total"} || {} } ) {
        my $value = $aggregated_image_metrics{"lanraragi_image_serving_resize_seconds_total"}{$labels};
        push @output, "lanraragi_image_serving_resize_seconds_total{$labels} $value";
    }

    push @output, "# TYPE lanraragi_image_serving_bytes_total counter";
    push @output, "# UNIT lanraragi_image_serving_bytes_total bytes";
    push @output, "# HELP lanraragi_image_serving_bytes_total Total bytes served by image endpoints";
    foreach my $labels ( sort keys %{ $aggregated_image_metrics{"lanraragi_image_serving_bytes_total"} || {} } ) {
        my $value = $aggregated_image_metrics{"lanraragi_image_serving_bytes_total"}{$labels};
        push @output, "lanraragi_image_serving_bytes_total{$labels} $value";
    }

    $metrics_redis->quit();
    return @output;
}

# Get process metrics
sub get_prometheus_process_metrics {
    my $metrics_redis = LANraragi::Model::Config->get_redis_metrics;
    return () unless $metrics_redis;

    my @output;
    
    # Group all metrics by metric name, collecting from both process types
    my %all_metrics_by_name;
    foreach my $process_type (qw(http minion shinobu)) {
        my @keys = $metrics_redis->keys("metrics:$process_type:*");
        
        foreach my $key (@keys) {
            if ( $key =~ /^metrics:$process_type:(\d+)$/ ) {
                my $worker_pid = $1;
                my %process_data = $metrics_redis->hgetall($key);
                next unless %process_data;

                my $labels = qq{worker_pid="$worker_pid",process_type="$process_type"};
                foreach my $metric_name ( qw(
                    cpu_user_seconds_total cpu_system_seconds_total cpu_seconds_total 
                    virtual_memory_bytes resident_memory_bytes 
                    open_fds max_fds start_time_seconds
                    read_bytes_total write_bytes_total) ) {
                    if ( defined $process_data{$metric_name} ) {
                        $all_metrics_by_name{$metric_name}{$labels} = $process_data{$metric_name};
                    }
                }
            }
        }
    }

    # Output CPU and I/O metrics (counters)
    foreach my $metric_name ( qw(cpu_user_seconds_total cpu_system_seconds_total cpu_seconds_total read_bytes_total write_bytes_total) ) {
        next unless $all_metrics_by_name{$metric_name};

        my $help_text = {
            cpu_user_seconds_total   => "Total user CPU time spent by process in seconds",
            cpu_system_seconds_total => "Total system CPU time spent by process in seconds", 
            cpu_seconds_total        => "Total user and system CPU time spent by process in seconds",
            read_bytes_total         => "Total bytes read from storage by process",
            write_bytes_total        => "Total bytes written to storage by process",
        }->{$metric_name};

        push @output, "# TYPE lanraragi_process_$metric_name counter";
        
        if ( $metric_name =~ /_bytes_total$/ ) {
            push @output, "# UNIT lanraragi_process_$metric_name bytes";
        } elsif ( $metric_name =~ /_seconds_total$/ ) {
            push @output, "# UNIT lanraragi_process_$metric_name seconds";
        }
        
        push @output, "# HELP lanraragi_process_$metric_name $help_text";
        foreach my $labels ( sort keys %{$all_metrics_by_name{$metric_name}} ) {
            my $value = $all_metrics_by_name{$metric_name}{$labels};
            push @output, "lanraragi_process_$metric_name\{$labels\} $value";
        }
    }

    # Output memory and FD metrics (gauges)
    foreach my $metric_name ( qw(virtual_memory_bytes resident_memory_bytes open_fds max_fds start_time_seconds) ) {
        next unless $all_metrics_by_name{$metric_name};

        my $help_text = {
            virtual_memory_bytes => "Virtual memory size of process in bytes",
            resident_memory_bytes => "Resident memory size of process in bytes",
            open_fds => "Number of open file handles in process",
            max_fds => "Maximum number of file handles allowed for process",
            start_time_seconds => "Unix epoch time when process started",
        }->{$metric_name};

        push @output, "# TYPE lanraragi_process_$metric_name gauge";

        if ( $metric_name =~ /_bytes$/ ) {
            push @output, "# UNIT lanraragi_process_$metric_name bytes";
        } elsif ( $metric_name =~ /_seconds$/ ) {
            push @output, "# UNIT lanraragi_process_$metric_name seconds";
        }

        push @output, "# HELP lanraragi_process_$metric_name $help_text";
        foreach my $labels ( sort keys %{$all_metrics_by_name{$metric_name}} ) {
            my $value = $all_metrics_by_name{$metric_name}{$labels};
            push @output, "lanraragi_process_$metric_name\{$labels\} $value";
        }
    }

    # Minion's own stats expose queue pressure and worker availability, which
    # process RSS/CPU alone cannot explain. Keep this best-effort so a Minion
    # backend outage does not make the Prometheus endpoint fail wholesale.
    eval {
        my $stats = LANraragi::Model::Config->get_minion->stats;
        my %job_fields = (
            active   => "active_jobs",
            inactive => "inactive_jobs",
            failed   => "failed_jobs",
            finished => "finished_jobs",
        );
        push @output, "# TYPE lanraragi_minion_jobs gauge";
        push @output, "# HELP lanraragi_minion_jobs Minion jobs by state";
        foreach my $state ( sort keys %job_fields ) {
            push @output, qq{lanraragi_minion_jobs{state="$state"} } . ( $stats->{ $job_fields{$state} } // 0 );
        }
        push @output, "# TYPE lanraragi_minion_workers gauge";
        push @output, "# HELP lanraragi_minion_workers Minion workers by state";
        push @output, qq{lanraragi_minion_workers{state="active"} } . ( $stats->{active_workers} // 0 );
        push @output, qq{lanraragi_minion_workers{state="inactive"} } . ( $stats->{inactive_workers} // 0 );
    };

    $metrics_redis->quit();
    return @output;
}

# Get server/configuration metrics
sub get_prometheus_stats_metrics {
    my $controller      = shift;
    my @output;

    # Get Redis connection for cache info
    my $config_redis    = $controller->LRR_CONF->get_redis_config;
    my $last_clear      = $config_redis->hget("LRR_SEARCHCACHE", "created") || time;
    $config_redis->quit();

    # Get archive and page stats
    my $arc_stat        = LANraragi::Model::Stats::get_archive_count;
    my $page_stat       = LANraragi::Model::Stats::get_page_stat;

    # Server info metric (with labels)
    my $name            = $controller->LRR_CONF->get_htmltitle || "";
    my $motd            = $controller->LRR_CONF->get_motd || "";
    my $version         = $controller->LRR_VERSION || "";
    my $version_name    = $controller->LRR_VERNAME || "";
    my $version_desc    = $controller->LRR_DESC || "";

    my $server_labels = sprintf(
        'name="%s",motd="%s",version="%s",version_name="%s",version_desc="%s"',
        LANraragi::Utils::Metrics::escape_label_value($name),
        LANraragi::Utils::Metrics::escape_label_value($motd),
        LANraragi::Utils::Metrics::escape_label_value($version),
        LANraragi::Utils::Metrics::escape_label_value($version_name),
        LANraragi::Utils::Metrics::escape_label_value($version_desc)
    );

    # "info" metadata type is OpenMetrics 1.0 format, currently not supported by Prometheus.
    # push @output, "# TYPE lanraragi_server_info info";
    push @output, "# TYPE lanraragi_server_info gauge";
    push @output, "# HELP lanraragi_server_info Server information with version and configuration details";
    push @output, "lanraragi_server_info{$server_labels} 1";

    # Configuration metrics
    push @output, "# TYPE lanraragi_has_password gauge";
    push @output, "# HELP lanraragi_has_password Whether the server has password protection enabled";
    push @output, "lanraragi_has_password " . ($controller->LRR_CONF->enable_pass ? 1 : 0);

    push @output, "# TYPE lanraragi_debug_mode gauge";
    push @output, "# HELP lanraragi_debug_mode Whether the server is running in debug mode";
    push @output, "lanraragi_debug_mode " . ($controller->LRR_CONF->enable_devmode ? 1 : 0);

    push @output, "# TYPE lanraragi_nofun_mode gauge";
    push @output, "# HELP lanraragi_nofun_mode Whether the server is running in no-fun mode";
    push @output, "lanraragi_nofun_mode " . ($controller->LRR_CONF->enable_nofun ? 1 : 0);

    push @output, "# TYPE lanraragi_server_resizes_images gauge";
    push @output, "# HELP lanraragi_server_resizes_images Whether the server resizes images for bandwidth optimization";
    push @output, "lanraragi_server_resizes_images " . ($controller->LRR_CONF->enable_resize ? 1 : 0);

    push @output, "# TYPE lanraragi_archives_per_page gauge";
    push @output, "# HELP lanraragi_archives_per_page Number of archives displayed per page";
    push @output, "lanraragi_archives_per_page " . $controller->LRR_CONF->get_pagesize;

    # Archive and page statistics
    push @output, "# TYPE lanraragi_archives_total gauge";
    push @output, "# HELP lanraragi_archives_total Current number of archives in the library";
    push @output, "lanraragi_archives_total $arc_stat";

    push @output, "# TYPE lanraragi_pages_read_total counter";
    push @output, "# HELP lanraragi_pages_read_total Total number of pages read across all archives";
    push @output, "lanraragi_pages_read_total $page_stat";

    push @output, "# TYPE lanraragi_cache_last_cleared_timestamp_seconds gauge";
    push @output, "# UNIT lanraragi_cache_last_cleared_timestamp_seconds seconds";
    push @output, "# HELP lanraragi_cache_last_cleared_timestamp_seconds Unix timestamp when the search cache was last cleared";
    push @output, "lanraragi_cache_last_cleared_timestamp_seconds $last_clear";

    return @output;
}

# Record HTTP request metrics to Redis
# takes a Mojo controller corresponding to the request being handled.
# called on every HTTP request; unrecognized endpoints are filtered out.
sub collect_request_metrics {
    my $controller      = shift;
    my $start_time      = $controller->stash('metrics.start_time');
    return unless $start_time;

    my $duration        = tv_interval($start_time);
    my $method          = $controller->req->method;
    my $path            = $controller->req->url->path->to_string;
    my $status_code     = $controller->res->code || 0;

    my $request_size    = $controller->req->content->body_size || 0;
    my $response_size   = $controller->res->content->body_size || 0;
    my $endpoint        = LANraragi::Utils::Metrics::extract_endpoint($path);
    return unless $endpoint;

    my $endpoint_encoded = _encode_endpoint($endpoint);
    my $metric_base      = "metrics:worker:$$:v2:${endpoint_encoded}:${method}";

    # Update in-process cache
    my $entry = ( $REQUEST_METRICS_CACHE{$metric_base} ||= {
        count             => 0,
        duration_sum      => 0.0,
        request_size_sum  => 0,
        response_size_sum => 0
    } );
    $entry->{count}++;
    $entry->{duration_sum}      += $duration;
    $entry->{request_size_sum}  += $request_size;
    $entry->{response_size_sum} += $response_size;
    $entry->{"status_$status_code"}++ if $status_code >= 100 && $status_code <= 599;
    foreach my $upper_bound ( REQUEST_DURATION_BUCKETS ) {
        $entry->{ _bucket_field($upper_bound) }++ if $duration <= $upper_bound;
    }
    $REQUEST_METRICS_UPDATE_COUNT++;

    # Conditionally flush to redis
    flush_request_metrics_to_redis();
}

# Record process-level metrics to Redis with the specified key prefix
# Accepted key prefixes are "http", "minion" or "shinobu"
sub collect_process_metrics {
    my $key_prefix = shift;

    my $metrics_redis = LANraragi::Model::Config->get_redis_metrics;
    my $error;
    if ( IS_LINUX ) {
        # Read process information from /proc/self/stat, /proc/self/statm, and /proc/self/io
        my $proc_stat   = LANraragi::Utils::Metrics::read_proc_stat();
        my $proc_statm  = LANraragi::Utils::Metrics::read_proc_statm();
        my $proc_fds    = LANraragi::Utils::Metrics::read_fd_stats();
        my $proc_io     = LANraragi::Utils::Metrics::read_proc_io_bytes();

        return unless $proc_stat && $proc_statm; # Skip if couldn't read proc files

        my $worker_pid = $$;
        my $process_key = "metrics:$key_prefix:$worker_pid";

        eval {
            # CPU metrics (counters)
            $metrics_redis->hset($process_key, "cpu_user_seconds_total", $proc_stat->{utime}, sub { });
            $metrics_redis->hset($process_key, "cpu_system_seconds_total", $proc_stat->{stime}, sub { });
            $metrics_redis->hset($process_key, "cpu_seconds_total", $proc_stat->{utime} + $proc_stat->{stime}, sub { });

            # Memory metrics (gauges)
            $metrics_redis->hset($process_key, "virtual_memory_bytes", $proc_statm->{vsize}, sub { });
            $metrics_redis->hset($process_key, "resident_memory_bytes", $proc_statm->{rss}, sub { });

            # File descriptor metrics (gauges)
            $metrics_redis->hset($process_key, "open_fds", $proc_fds->{open}, sub { }) if defined $proc_fds->{open};
            $metrics_redis->hset($process_key, "max_fds", $proc_fds->{max}, sub { }) if defined $proc_fds->{max};

            # Process start time (gauge)
            $metrics_redis->hset($process_key, "start_time_seconds", $proc_stat->{starttime}, sub { });

            # I/O metrics (counters)
            $metrics_redis->hset($process_key, "read_bytes_total", $proc_io->{read_bytes}, sub { });
            $metrics_redis->hset($process_key, "write_bytes_total", $proc_io->{write_bytes}, sub { });
            $metrics_redis->expire( $process_key, 90, sub { } );
            $metrics_redis->wait_all_responses;
        };
        $error = $@;

    } elsif ( IS_MACOS ) {
        # TODO: macos
    } elsif ( IS_WIN32 ) {
        # TODO: windows
    } else {
        $metrics_redis->quit();
        die "Unsupported OS: $^O";
    }
    $metrics_redis->quit();

    if ( $error ) {
        my $logger = get_logger( "Metrics", "lanraragi" );
        $logger->error("Failed to collect metrics processes ($key_prefix): $error");
    }
}

# Clean up all existing metrics data on startup
sub cleanup_metrics {

    my $metrics_redis   = LANraragi::Model::Config->get_redis_metrics;
    my $logger          = get_logger( "Metrics", "lanraragi" );

    # Get all metrics keys
    eval {
        my @api_keys        = $metrics_redis->keys("metrics:worker:*");
        my @http_keys       = $metrics_redis->keys("metrics:http:*");
        my @minion_keys     = $metrics_redis->keys("metrics:minion:*");
        my @shinobu_keys    = $metrics_redis->keys("metrics:shinobu:*");
        my @image_keys      = $metrics_redis->keys("metrics:image:*");
        my @search_keys     = $metrics_redis->keys("metrics:search:*");
        my @all_keys        = (@api_keys, @http_keys, @minion_keys, @shinobu_keys, @image_keys, @search_keys);
        if ( @all_keys ) {
            $metrics_redis->del(@all_keys);
            my $count = scalar(@all_keys);
            $logger->info("Cleaned up $count metrics keys.");
        }
    };
    my $error = $@;
    $metrics_redis->quit();

    if ( $error ) {
        $logger->error("Failed to clean up metrics keys: $error");
    }
}

# Flush to Redis if time interval elapsed or update count cap reached.
sub flush_request_metrics_to_redis {
    my $now                 = Time::HiRes::time();
    my $should_flush_time   = ( $now - $REQUEST_METRICS_LAST_FLUSH ) >= REQUEST_METRICS_FLUSH_INTERVAL;
    my $should_flush_count  = $REQUEST_METRICS_UPDATE_COUNT >= REQUEST_METRICS_FLUSH_MAX_UPDATES;
    return unless ( $should_flush_time || $should_flush_count );
    return unless %REQUEST_METRICS_CACHE;

    my $redis = LANraragi::Model::Config->get_redis_metrics;
    my $error;
    eval {
        foreach my $base ( keys %REQUEST_METRICS_CACHE ) {
            my $fields = $REQUEST_METRICS_CACHE{$base} || {};
            $redis->hincrby($base, "count",               $fields->{count}             || 0, sub { });
            $redis->hincrbyfloat($base, "duration_sum",   $fields->{duration_sum}      || 0, sub { });
            $redis->hincrby($base, "request_size_sum",    $fields->{request_size_sum}  || 0, sub { });
            $redis->hincrby($base, "response_size_sum",   $fields->{response_size_sum} || 0, sub { });
            foreach my $field ( grep { /^(?:status_|duration_bucket_)/ } keys %{$fields} ) {
                $redis->hincrby( $base, $field, $fields->{$field} || 0, sub { } );
            }
        }
        $redis->wait_all_responses;
    };
    $error = $@;
    $redis->quit();

    if ( $error ) {
        my $logger = get_logger( "Metrics", "lanraragi" );
        $logger->error("Failed to update metrics info (flush): $error");
        return;
    }

    %REQUEST_METRICS_CACHE        = ();
    $REQUEST_METRICS_UPDATE_COUNT = 0;
    $REQUEST_METRICS_LAST_FLUSH   = $now;
}

1;
