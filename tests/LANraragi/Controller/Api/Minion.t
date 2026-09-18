use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi::Controller::Api::Minion;

package FakeMinionStatusJob {
    sub info {
        return {
            task  => 'download_url',
            state => 'failed',
            notes => undef,
            error => 'signed URL and local path must stay private',
        };
    }
}

package FakeMinionStatusBackend {
    sub job { return bless {}, 'FakeMinionStatusJob' }
}

package FakeMinionStatusController {
    sub new { bless { authenticated => $_[1] }, $_[0] }
    sub openapi { return $_[0] }
    sub valid_input { return $_[0] }
    sub stash { return 1 }
    sub minion { return bless {}, 'FakeMinionStatusBackend' }
    sub render { my ( $self, %args ) = @_; $self->{rendered} = \%args; return }
}

package main;

no warnings 'redefine';
local *LANraragi::Controller::Api::Minion::is_logged_in_api = sub { return $_[0]->{authenticated} };

my $public = FakeMinionStatusController->new(0);
LANraragi::Controller::Api::Minion::minion_job_status($public);
is( $public->{rendered}{openapi}{error}, 'Job failed.', 'public job status redacts internal failure details' );

my $authenticated = FakeMinionStatusController->new(1);
LANraragi::Controller::Api::Minion::minion_job_status($authenticated);
is( $authenticated->{rendered}{openapi}{error}, 'signed URL and local path must stay private',
    'authenticated callers retain diagnostic details' );

done_testing();
