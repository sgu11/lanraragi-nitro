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

done_testing();
