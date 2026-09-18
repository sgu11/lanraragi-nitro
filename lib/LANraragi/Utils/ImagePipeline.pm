package LANraragi::Utils::ImagePipeline;

use v5.36;
use strict;
use warnings;
use Config;
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use Fcntl qw(:flock);
use Mojo::IOLoop;
use Mojo::IOLoop::Subprocess;
use Mojo::Promise;
use Storable qw(nfreeze thaw);
use Time::HiRes qw(time);
use LANraragi::Utils::TempFolder qw(get_temp);

# Two shared execution slots bound image CPU/RSS across all web workers. Each
# parent runs at most one child, so a fork cannot inherit another child's locks.
my %INFLIGHT;
my $PID = $$;
my $RUNNING = 0;

sub _try_lock ($path) {
    open my $fh, '>>', $path or die "Cannot open image transform lock: $!\n";
    return $fh if flock($fh, LOCK_EX | LOCK_NB);
    close $fh;
    return;
}

sub run_p ( $key, $lookup, $compute ) {
    if ($PID != $$) { %INFLIGHT = (); $RUNNING = 0; $PID = $$; }
    return $INFLIGHT{$key} if $INFLIGHT{$key};
    my $cached = $lookup->();
    return Mojo::Promise->resolve($cached) if defined $cached;
    # Mojolicious subprocesses cannot use Windows fork emulation.
    return Mojo::Promise->new->resolve($compute->()) if $Config{d_pseudofork};

    my $dir = get_temp() . '/image-transform-locks';
    make_path($dir) unless -d $dir;
    my $lock_path = "$dir/" . sha256_hex($key);
    my $deadline = time() + 30;
    my $promise = Mojo::Promise->new;
    my $poll;
    $poll = sub {
        my $ok = eval {
            my $cached = $lookup->();
            if (defined $cached) {
                $poll = undef;
                $promise->resolve($cached);
                return;
            }
            die "Timed out waiting for image processing capacity\n" if time() >= $deadline;
            my $lock = !$RUNNING ? _try_lock($lock_path) : undef;
            my $slot;
            if ($lock) {
                for my $index (0 .. 1) {
                    $slot = _try_lock("$dir/slot-$index");
                    last if $slot;
                }
            }
            if ($lock && $slot) {
                $RUNNING = 1;
                $poll = undef;
                my $child = Mojo::IOLoop::Subprocess->new(serialize => \&nfreeze, deserialize => \&thaw);
                $child->run_p(sub {
                    my $cached = $lookup->();
                    return defined $cached ? $cached : $compute->();
                })->then(sub {
                    my $result = shift;
                    close $lock;
                    close $slot;
                    $RUNNING = 0;
                    $promise->resolve($result);
                    return;
                })->catch(sub {
                    close $lock;
                    close $slot;
                    $RUNNING = 0;
                    $promise->reject(@_);
                    return;
                });
            } else {
                close $lock if $lock;
                Mojo::IOLoop->timer(0.05 => $poll);
            }
            1;
        };
        if (!$ok && $@) { $poll = undef; $promise->reject($@); }
    };
    Mojo::IOLoop->next_tick($poll);
    my $result = $promise->finally(sub { delete $INFLIGHT{$key}; return; });
    $INFLIGHT{$key} = $result;
    return $result;
}

1;
