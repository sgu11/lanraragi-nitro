use v5.36;
use strict;
use warnings;
use Test::More;
use Mojo::File qw(path);
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep);
use Config;
use POSIX qw(_exit);
use LANraragi::Utils::ImagePipeline;

plan skip_all => 'native fork required' if $Config{d_pseudofork};
my $dir = tempdir(CLEANUP => 1);
my $cache = path("$dir/result");
my $calls = path("$dir/computations");
no warnings 'redefine';
local *LANraragi::Utils::ImagePipeline::get_temp = sub { $dir };
my @workers;
for (1..3) {
    my $pid = fork();
    die $! unless defined $pid;
    if (!$pid) {
        my $valid;
        LANraragi::Utils::ImagePipeline::run_p('same-variant', sub {
            return -e $cache ? {content => $cache->slurp} : undef;
        }, sub {
            open my $fh, '>>', $calls or die $!;
            say {$fh} $$; close $fh;
            sleep 0.15;
            $cache->spurt('result');
            return {content => 'result'};
        })->then(sub { $valid = $_[0]{content} eq 'result'; })->catch(sub { $valid = 0; })->wait;
        _exit($valid ? 0 : 1);
    }
    push @workers, $pid;
}
for my $pid (@workers) {
    waitpid $pid, 0;
    is($?, 0, 'independent web worker receives the shared result');
}
my @calls = split /\n/, $calls->slurp;
is(scalar @calls, 1, 'file lease prevents concurrent duplicate transforms across workers');

my $failed;
LANraragi::Utils::ImagePipeline::run_p('failure', sub { undef }, sub { die "transform failed\n" })
    ->catch(sub { $failed = $_[0] })->wait;
like($failed, qr/transform failed/, 'child error propagates');
my $retried;
LANraragi::Utils::ImagePipeline::run_p('failure', sub { undef }, sub { 'retried' })
    ->then(sub { $retried = $_[0] })->wait;
is($retried, 'retried', 'failed child releases its lease and inflight entry');
done_testing();
