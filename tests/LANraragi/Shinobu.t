use strict;
use warnings;
use utf8;

use Cwd qw(getcwd);
use File::Temp qw(tempfile);
use Test::More;
use Test::MockModule qw(strict);
use Time::HiRes qw(time);

# Shinobu creates a logger at file scope, and cold logger creation reads
# devmode from Redis — so the Redis mock must be installed before the
# BEGIN-time use_ok() compiles Shinobu.
my $cwd;

BEGIN {
    $cwd = getcwd();
    require "$cwd/tests/mocks.pl";
    setup_redis_mock();
}

BEGIN { use_ok('Shinobu'); }

package ShinobuCoverDedupRedis {
    sub new { bless {}, shift }
    sub quit { 1 }
}

package ShinobuCoverDedupMinion {
    our @enqueued;
    sub new { bless {}, shift }
    sub enqueue {
        my ($self, $task, $args, $opts) = @_;
        push @enqueued, [ $task, $args, $opts ];
        return scalar @enqueued;
    }
}

package main;

note('wait_for_stable_size returns once a writer stops appending');
{
    my ( $fh, $filename ) = tempfile( UNLINK => 1 );
    close $fh;

    # Child writes for ~3s then stops, so stability should be reached around
    # T+5 (3s of growth + 2 ticks of no growth).
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ( $pid == 0 ) {
        open my $w, '>>', $filename or die $!;
        $w->autoflush(1);
        for ( 1 .. 3 ) {
            print {$w} "x" x 100_000;
            sleep 1;
        }
        close $w;
        exit 0;
    }

    my $start = time;
    Shinobu::wait_for_stable_size($filename);
    my $elapsed = time - $start;
    waitpid( $pid, 0 );

    cmp_ok( $elapsed, '>=', 4, "waited through the writer's activity (>=4s)" );
    cmp_ok( $elapsed, '<',  15, "didn't wait absurdly long (<15s)" );
}

note('wait_for_stable_size short-circuits when the file disappears');
{
    my ( $fh, $filename ) = tempfile();
    close $fh;
    unlink $filename;
    ok( !-e $filename, 'file really is gone' );

    my $start = time;
    Shinobu::wait_for_stable_size($filename);
    my $elapsed = time - $start;

    cmp_ok( $elapsed, '<', 2, "exited promptly when file is missing" );
}

note('same-ID replacement cover dedup refresh enqueues legacy and v2 cover work');
{
    @ShinobuCoverDedupMinion::enqueued = ();
    my @invalidated;

    my $config_mod = Test::MockModule->new('LANraragi::Model::Config');
    $config_mod->redefine('get_redis_config', sub { ShinobuCoverDedupRedis->new });
    $config_mod->redefine('get_minion',       sub { ShinobuCoverDedupMinion->new });

    my $cover_mod = Test::MockModule->new('LANraragi::Model::Dedup::CoverIndex');
    $cover_mod->redefine('invalidate_cover_dedup_signals', sub {
        my ($redis_arc, $redis_cfg, $id) = @_;
        push @invalidated, $id;
        return 1;
    });

    Shinobu::_invalidate_and_enqueue_cover_dedup_signals(ShinobuCoverDedupRedis->new, 'id1');

    is_deeply(\@invalidated, [ 'id1' ], "cover dedup signals invalidated");
    is_deeply(
        [ map { $_->[0] } @ShinobuCoverDedupMinion::enqueued ],
        [ 'compute_coverhash', 'compute_cover_fingerprint' ],
        "replacement path enqueues both coverhash and v2 fingerprint computation"
    );
}

done_testing();
