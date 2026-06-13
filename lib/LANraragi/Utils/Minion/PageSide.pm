package LANraragi::Utils::Minion::PageSide;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PageSide qw(RECENT_DETECTION_LIMIT);

sub _clamped_limit {
    my ($requested) = @_;
    my $limit = defined $requested ? int($requested) : RECENT_DETECTION_LIMIT;
    $limit = RECENT_DETECTION_LIMIT if $limit <= 0;
    return $limit > RECENT_DETECTION_LIMIT ? RECENT_DETECTION_LIMIT : $limit;
}

sub add_tasks {
    my ($minion) = @_;

    my $detect_one = sub {
        my ( $job, @args ) = @_;
        my ($id) = @args;

        eval {
            my $result = LANraragi::Utils::PageSide::detect_and_store_first_spread_start($id);
            $job->finish($result);
        };
        if ($@) {
            $job->fail( { errors => ["$@"] } );
        }
    };

    my $detect_recent = sub {
        my ( $job, @args ) = @_;
        my $limit = _clamped_limit( $args[0] );

        eval {
            my $result = LANraragi::Utils::PageSide::detect_recent_first_spread_starts( $job, $limit );
            $job->finish($result);
        };
        if ($@) {
            $job->fail( { errors => ["$@"] } );
        }
    };

    $minion->add_task( detect_first_spread_start         => $detect_one );
    $minion->add_task( detect_recent_first_spread_starts => $detect_recent );
    $minion->add_task( detect_first_page_side            => $detect_one );
    $minion->add_task( detect_recent_first_page_sides    => $detect_recent );
}

1;
