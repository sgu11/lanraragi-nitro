use strict;
use warnings;
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep);
use Redis;

# Isolated Unix-socket server, no TCP listener and no persistence. No test may
# fall back to the application's Redis when the executable is unavailable.
sub start_test_redis {
    my $executable;
    for my $dir (split /:/, $ENV{PATH}) {
        for my $name (qw(valkey-server redis-server)) {
            $executable = "$dir/$name" if !$executable && -x "$dir/$name";
        }
    }
    Test::More::plan(skip_all => 'Redis/Valkey executable required for isolated Lua tests') unless $executable;
    my $dir = tempdir(CLEANUP => 1);
    my $socket = "$dir/redis.sock";
    my $pid = fork();
    die "Cannot fork test Redis: $!" unless defined $pid;
    if (!$pid) {
        exec $executable, '--port', '0', '--unixsocket', $socket, '--save', '', '--appendonly', 'no', '--logfile', '/dev/null';
        die "Cannot start test Redis: $!";
    }
    my $redis;
    for (1..100) {
        $redis = eval { Redis->new(sock => $socket, reconnect => 0) };
        last if $redis && eval { $redis->ping eq 'PONG' };
        sleep 0.02;
    }
    if (!$redis) { kill 'TERM', $pid; waitpid $pid, 0; die "Test Redis did not start"; }
    return ($redis, bless { pid => $pid, owner => $$, dir => $dir }, 'LRRTestRedisGuard');
}

package LRRTestRedisGuard;
sub DESTROY {
    my ($self) = @_;
    return unless $$ == $self->{owner};
    kill 'TERM', $self->{pid};
    waitpid $self->{pid}, 0;
}
1;
