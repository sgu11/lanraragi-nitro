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

ok( $tasks{detect_first_page_side},        "single-archive detection task is registered" );
ok( $tasks{detect_recent_first_page_sides}, "recent backfill detection task is registered" );

my $page_side = Test::MockModule->new('LANraragi::Utils::PageSide');
my $received_recent_limit;
$page_side->redefine(
    detect_recent_first_page_sides => sub {
        my ( $job, $limit ) = @_;
        $received_recent_limit = $limit;
        return { processed => $limit, limit => $limit };
    }
);

my $finished;
my $job = Test::MockObject->new;
$job->mock( finish => sub { my ( $self, $payload ) = @_; $finished = $payload; } );

$tasks{detect_recent_first_page_sides}->( $job, 9000 );

is( $received_recent_limit, 50, "recent backfill task clamps requested limits to 50 archives" );
is_deeply( $finished, { processed => 50, limit => 50 }, "recent backfill task finishes with detector payload" );

done_testing();
