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

package ShinobuIngestRedis {
    our @deleted;
    sub new { bless {}, shift }
    sub set { return 1 }
    sub del { shift; push @deleted, @_; return 1 }
    sub quit { 1 }
}

package ShinobuTransactionalRedis {
    sub new { bless { LRR_FILEMAP => {}, LRR_FILEMAP_PENDING => {} }, shift }
    sub hexists { exists $_[0]->{$_[1]}{$_[2]} }
    sub hget { $_[0]->{$_[1]}{$_[2]} }
    sub hset { $_[0]->{$_[1]}{$_[2]} = $_[3]; 1 }
    sub hdel { delete $_[0]->{$_[1]}{$_[2]}; 1 }
    sub quit { 1 }
}

package ShinobuTransactionalArchiveRedis {
    sub new { bless { archives => {} }, shift }
    sub exists { exists $_[0]->{archives}{$_[1]} }
    sub hget { return $_[2] eq "arcsize" ? 512_001 : 1 }
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

note('new file events enqueue ingestion without waiting for archive stability');
{
    my ( $fh, $filename ) = tempfile( SUFFIX => '.cbz', UNLINK => 1 );
    print {$fh} "partial archive";
    close $fh;

    @ShinobuCoverDedupMinion::enqueued = ();
    @ShinobuIngestRedis::deleted = ();
    my $config_mod = Test::MockModule->new('LANraragi::Model::Config');
    $config_mod->redefine('get_redis_config', sub { ShinobuIngestRedis->new });
    $config_mod->redefine('get_minion', sub { ShinobuCoverDedupMinion->new });

    my $start = time;
    Shinobu::new_file_callback($filename);
    my $elapsed = time - $start;

    cmp_ok( $elapsed, '<', 0.5, 'watcher callback returns without polling file size' );
    is( $ShinobuCoverDedupMinion::enqueued[0][0], 'ingest_archive_file', 'archive ingestion moved to Minion' );
    is( $ShinobuCoverDedupMinion::enqueued[0][1][0], $filename, 'queued job keeps the exact file path' );
    is( $ShinobuCoverDedupMinion::enqueued[0][2]{attempts}, 3, 'transient ingest failures can retry' );
}

package ShinobuPageCacheLogger {
    sub new { bless {}, shift }
    sub debug { 1 }
    sub info  { 1 }
    sub warn  { 1 }
}

package ShinobuPageCacheRedisCfg {
    sub new { bless { file => $_[1], id => $_[2] }, $_[0] }
    sub hexists { 1 }
    sub hget { return $_[1] eq "LRR_FILEMAP" ? $_[0]->{id} : undef }
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
    ok( Shinobu::wait_for_stable_size($filename), 'stable file reports success' );
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
    ok( !Shinobu::wait_for_stable_size($filename), 'missing file reports failure' );
    my $elapsed = time - $start;

    cmp_ok( $elapsed, '<', 2, "exited promptly when file is missing" );
}

note('wait_for_stable_size reports timeout separately from success');
{
    my ( $fh, $filename ) = tempfile( UNLINK => 1 );
    close $fh;
    ok( !Shinobu::wait_for_stable_size( $filename, 1, 0 ), 'poll ceiling reports failure' );
}

note('add_new_file propagates core ingest failures after cleanup');
{
    my $config_mod = Test::MockModule->new('LANraragi::Model::Config');
    $config_mod->redefine('get_redis',        sub { ShinobuCoverDedupRedis->new });
    $config_mod->redefine('get_redis_search', sub { ShinobuCoverDedupRedis->new });

    no warnings 'redefine';
    local *Shinobu::add_archive_to_redis = sub { die "broken archive\n" };
    my $error;
    eval { Shinobu::add_new_file( 'abc123', '/tmp/broken.cbz' ); 1 } or $error = $@;
    like( $error, qr/^broken archive/, 'Minion caller can fail and retry the ingest job' );
}

note('failed initial ingest remains retryable until add_new_file completes');
{
    my ( $fh, $filename ) = tempfile( SUFFIX => '.cbz', UNLINK => 1 );
    print {$fh} "x" x 512_001;
    close $fh;

    my $redis_cfg = ShinobuTransactionalRedis->new;
    my $config_mod = Test::MockModule->new('LANraragi::Model::Config');
    $config_mod->redefine('get_redis', sub { ShinobuTransactionalArchiveRedis->new });

    my $calls = 0;
    no warnings 'redefine';
    local *Shinobu::is_archive = sub { 1 };
    local *Shinobu::wait_for_stable_size = sub { 1 };
    local *Shinobu::compute_id = sub { "1234567890abcdef1234567890abcdef12345678" };
    local *Shinobu::exec_with_lock_pure = sub {
        my (undef, $code) = @_;
        return (1, $code->());
    };
    local *Shinobu::add_new_file = sub {
        $calls++;
        die "first ingest failed\n" if $calls == 1;
        return 1;
    };
    local *Shinobu::invalidate_cache = sub { 1 };

    my $error;
    eval { Shinobu::add_to_filemap( $redis_cfg, $filename ); 1 } or $error = $@;
    like($error, qr/^first ingest failed/, "first ingest failure propagates");
    ok($redis_cfg->hexists("LRR_FILEMAP_PENDING", $filename), "failed ingest remains explicitly pending");

    Shinobu::add_to_filemap( $redis_cfg, $filename );
    is($calls, 2, "retry runs add_new_file again instead of accepting the partial filemap");
    ok(!$redis_cfg->hexists("LRR_FILEMAP_PENDING", $filename), "successful retry commits the ingest");
}

note('failed ingest with changed content migrates partial state and retries full ingest');
{
    my ( $fh, $filename ) = tempfile( SUFFIX => '.cbz', UNLINK => 1 );
    print {$fh} "x" x 512_001;
    close $fh;

    my $old_id = "1234567890abcdef1234567890abcdef12345678";
    my $new_id = "abcdef1234567890abcdef1234567890abcdef12";
    my $redis_cfg = ShinobuTransactionalRedis->new;
    my $redis_arc = ShinobuTransactionalArchiveRedis->new;
    my $config_mod = Test::MockModule->new('LANraragi::Model::Config');
    $config_mod->redefine('get_redis', sub { $redis_arc });

    my @computed_ids = ( $old_id, $new_id );
    my @ingested_ids;
    my @migrations;
    my @pending_during_ingest;
    no warnings 'redefine';
    local *Shinobu::is_archive = sub { 1 };
    local *Shinobu::wait_for_stable_size = sub { 1 };
    local *Shinobu::compute_id = sub { shift @computed_ids };
    local *Shinobu::exec_with_lock_pure = sub {
        my (undef, $code) = @_;
        return (1, $code->());
    };
    local *Shinobu::change_archive_id = sub {
        my ( $from, $to ) = @_;
        push @migrations, [ $from, $to ];
        delete $redis_arc->{archives}{$from};
        $redis_arc->{archives}{$to} = 1;
    };
    local *Shinobu::add_new_file = sub {
        my ( $id, undef ) = @_;
        push @ingested_ids, $id;
        push @pending_during_ingest, $redis_cfg->hget( "LRR_FILEMAP_PENDING", $filename );
        if ( @ingested_ids == 1 ) {
            $redis_arc->{archives}{$id} = 1;
            die "first ingest failed\n";
        }
        return 1;
    };
    local *Shinobu::invalidate_cache = sub { 1 };

    my $error;
    eval { Shinobu::add_to_filemap( $redis_cfg, $filename ); 1 } or $error = $@;
    like($error, qr/^first ingest failed/, "first ingest failure propagates");
    is($redis_cfg->hget("LRR_FILEMAP", $filename), $old_id, "failed ingest keeps the original filemap ID");
    is($redis_cfg->hget("LRR_FILEMAP_PENDING", $filename), $old_id, "failed ingest keeps the original pending ID");

    Shinobu::add_to_filemap( $redis_cfg, $filename );
    is_deeply( \@migrations, [ [ $old_id, $new_id ] ], "partial archive state migrates to the recomputed ID" );
    is_deeply( \@ingested_ids, [ $old_id, $new_id ], "changed-ID retry reruns full ingestion" );
    is_deeply( \@pending_during_ingest, [ $old_id, $new_id ], "pending marker tracks the active ID through successful ingestion" );
    is($redis_cfg->hget("LRR_FILEMAP", $filename), $new_id, "filemap tracks the recomputed ID");
    ok(!$redis_cfg->hexists("LRR_FILEMAP_PENDING", $filename), "pending marker clears only after retry succeeds");
}

note('compute_id failures propagate to the Minion retry boundary');
{
    my ( $fh, $filename ) = tempfile( SUFFIX => '.cbz', UNLINK => 1 );
    print {$fh} "x" x 512_001;
    close $fh;

    my $redis_cfg = ShinobuTransactionalRedis->new;
    my $config_mod = Test::MockModule->new('LANraragi::Model::Config');
    $config_mod->redefine('get_redis', sub { ShinobuTransactionalArchiveRedis->new });

    no warnings 'redefine';
    local *Shinobu::is_archive = sub { 1 };
    local *Shinobu::wait_for_stable_size = sub { 1 };
    local *Shinobu::compute_id = sub { die "cannot hash archive\n" };

    my $error;
    eval { Shinobu::add_to_filemap( $redis_cfg, $filename ); 1 } or $error = $@;
    like($error, qr/^cannot hash archive/, "hashing error is not converted into task success");
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
