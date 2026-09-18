use strict;
use warnings;
use utf8;

use Test::More;
use Test::MockModule;
use Test::MockObject;

use LANraragi::Utils::Minion::PageSide;

my %tasks;
my $minion = Test::MockObject->new;
$minion->mock(
    add_task => sub {
        my ( $self, $name, $cb ) = @_;
        $tasks{$name} = $cb;
    }
);

LANraragi::Utils::Minion::PageSide::add_tasks($minion);

ok( $tasks{detect_first_spread_start},         "single-archive spread-start detection task is registered" );
ok( $tasks{detect_recent_first_spread_starts}, "recent spread-start backfill detection task is registered" );
ok( $tasks{detect_first_page_side},            "legacy single-archive detection task alias is registered" );
ok( $tasks{detect_recent_first_page_sides},    "legacy recent backfill detection task alias is registered" );

my $page_side = Test::MockModule->new('LANraragi::Utils::PageSide');
my $received_recent_limit;
$page_side->redefine(
    detect_recent_first_spread_starts => sub {
        my ( $job, $limit ) = @_;
        $received_recent_limit = $limit;
        return { processed => 123, limit => $limit };
    }
);

my $finished;
my $job = Test::MockObject->new;
$job->mock( finish => sub { my ( $self, $payload ) = @_; $finished = $payload; } );

$tasks{detect_recent_first_spread_starts}->($job);

is( $received_recent_limit, undef, "recent backfill task defaults to an uncapped sweep" );
is_deeply( $finished, { processed => 123, limit => undef }, "recent backfill task finishes with detector payload" );

$tasks{detect_recent_first_spread_starts}->( $job, 9000 );

is( $received_recent_limit, 9000, "recent backfill task preserves explicit positive limits" );

my @delays;
my $failed;
my $retries = 0;
$job->mock(retries => sub { $retries });
$job->mock(retry => sub { push @delays, $_[1]->{delay}; return 1; });
$job->mock(fail => sub { $failed = $_[1]; });
$page_side->redefine(detect_and_store_first_spread_start => sub { { error => 'temporary', reason => 'error' } });
$finished = undef;
for my $attempt (0 .. 2) { $retries = $attempt; $tasks{detect_first_spread_start}->($job, 'abc'); }
is_deeply(\@delays, [5, 10], 'transient detection errors retry twice with bounded backoff');
is_deeply($failed, { errors => ['temporary'] }, 'exhausted retries report failure');
ok(!defined $finished, 'errors are never reported as successful UNKNOWN');
$page_side->redefine(detect_and_store_first_spread_start => sub { { first_spread_start => 'UNKNOWN', reason => 'weak' } });
$tasks{detect_first_spread_start}->($job, 'abc');
is($finished->{first_spread_start}, 'UNKNOWN', 'successful uncertainty finishes normally');

done_testing();
