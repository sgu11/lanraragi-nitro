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

package ShinobuPageCacheLogger {
    sub new { bless {}, shift }
    sub debug { 1 }
    sub info  { 1 }
    sub warn  { 1 }
}

package ShinobuPageCacheRedisCfg {
    sub new { bless { file => $_[1], id => $_[2] }, $_[0] }
    sub hexists { 1 }
    sub hget { return $_[0]->{id} }
    sub hset { 1 }
}

package ShinobuPageCacheRedisArc {
    sub new { bless { arcsize => $_[1] }, $_[0] }
    sub exists { 1 }
    sub hget {
        my ( $self, $id, $field ) = @_;
        return $self->{arcsize} if $field eq "arcsize";
        return 1 if $field eq "pagecount";
        return;
    }
    sub hdel { 1 }
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

note('same-ID replacement cover dedup refresh enqueues coverhash only by default');
{
    @ShinobuCoverDedupMinion::enqueued = ();
    my @invalidated;

    my $config_mod = Test::MockModule->new('LANraragi::Model::Config');
    $config_mod->redefine('get_redis_config', sub { ShinobuCoverDedupRedis->new });
    $config_mod->redefine('get_minion',       sub { ShinobuCoverDedupMinion->new });
    $config_mod->redefine('get_dedup_auto_signals', sub { 'cover_only' });

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
        [ 'compute_coverhash' ],
        "cover_only replacement path enqueues coverhash only (no fingerprint dual-write)"
    );
}

note('dedup auto-signal policy: cover_only / all / none');
{
    my $config_mod = Test::MockModule->new('LANraragi::Model::Config');
    $config_mod->redefine('get_minion', sub { ShinobuCoverDedupMinion->new });

    @ShinobuCoverDedupMinion::enqueued = ();
    $config_mod->redefine('get_dedup_auto_signals', sub { 'cover_only' });
    Shinobu::_enqueue_dedup_signals_for_archive('new1', mode => 'new');
    is_deeply(
        [ map { $_->[0] } @ShinobuCoverDedupMinion::enqueued ],
        [ 'compute_coverhash' ],
        "cover_only new-archive path enqueues only compute_coverhash"
    );

    @ShinobuCoverDedupMinion::enqueued = ();
    $config_mod->redefine('get_dedup_auto_signals', sub { 'all' });
    Shinobu::_enqueue_dedup_signals_for_archive('new2', mode => 'new');
    is_deeply(
        [ map { $_->[0] } @ShinobuCoverDedupMinion::enqueued ],
        [ 'compute_pagehashes', 'compute_coverhash', 'compute_dedup_signals' ],
        "all mode enqueues pagehashes + coverhash + relation signals (no fingerprint)"
    );

    @ShinobuCoverDedupMinion::enqueued = ();
    $config_mod->redefine('get_dedup_auto_signals', sub { 'none' });
    Shinobu::_enqueue_dedup_signals_for_archive('new3', mode => 'new');
    is(scalar @ShinobuCoverDedupMinion::enqueued, 0, "none mode enqueues nothing");
}

note('same-ID arcsize mismatch clears stale page-cache variants');
{
    my ( $fh, $filename ) = tempfile( UNLINK => 1 );
    print {$fh} "new archive bytes";
    close $fh;

    my $id = "1234567890abcdef1234567890abcdef12345678";
    my @page_cache_clears;

    my $shinobu_mod = Test::MockModule->new('Shinobu');
    $shinobu_mod->redefine('clear_first_spread_start_detection', sub { return 1 });
    $shinobu_mod->redefine('add_arcsize', sub { return 1 });
    $shinobu_mod->redefine('add_pagecount', sub { return 1 });
    $shinobu_mod->redefine('_invalidate_and_enqueue_cover_dedup_signals', sub { return 1 });
    $shinobu_mod->redefine('enqueue_first_spread_start_detection', sub { return 1 });
    $shinobu_mod->redefine('clear_by_id', sub { push @page_cache_clears, @_ });

    Shinobu::update_filemap_entry(
        ShinobuPageCacheLogger->new,
        $id,
        $filename,
        ShinobuPageCacheRedisCfg->new( $filename, $id ),
        ShinobuPageCacheRedisArc->new(1),
    );

    is_deeply( \@page_cache_clears, [$id], "same-ID arcsize mismatch clears page-cache variants" );
}

done_testing();
