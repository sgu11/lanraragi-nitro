use strict;
use warnings;
use utf8;

use Cwd qw(getcwd);
use File::Temp qw(tempfile);
use Test::More;
use Time::HiRes qw(time);

my $cwd = getcwd();
require "$cwd/tests/mocks.pl";
setup_redis_mock();

BEGIN { use_ok('Shinobu'); }

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

done_testing();
