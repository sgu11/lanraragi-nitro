use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempfile);
use POSIX qw(_exit);

use LANraragi::Model::Config;

package FakePersistentRedis {
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            id          => $args{id},
            select_db   => undef,
            quit_count  => 0,
            ping_count  => 0,
        }, $class;
    }

    sub select {
        my ( $self, $db ) = @_;
        $self->{select_db} = $db;
        return 1;
    }

    sub ping {
        my ($self) = @_;
        $self->{ping_count}++;
        return "PONG";
    }

    sub quit {
        my ($self) = @_;
        $self->{quit_count}++;
        return 1;
    }
}

package main;

my $reset_handles = LANraragi::Model::Config->can("reset_redis_handles");
ok( $reset_handles, "Config exposes a reset hook for persistent Redis handles" );

SKIP: {
    skip "persistent Redis handle reset hook is not implemented yet", 11 unless $reset_handles;

    my @created;
    no warnings qw(once redefine);
    local *Redis::new = sub {
        my ( $class, @args ) = @_;
        push @created, [ $$, \@args ];
        return FakePersistentRedis->new( id => scalar @created );
    };

    LANraragi::Model::Config::reset_redis_handles();

    my $first = LANraragi::Model::Config::get_redis_internal(0);
    is( $first->ping, "PONG", "first shared handle delegates Redis methods" );
    $first->quit();

    my $second = LANraragi::Model::Config::get_redis_internal(0);
    is( scalar @created, 1, "same process and DB reuse one Redis connection even after caller quit" );
    is( $second->ping, "PONG", "reused handle remains usable after caller quit" );
    is( $first, $second, "same DB returns the same shared wrapper in one process" );

    my $config_db = LANraragi::Model::Config::get_redis_internal(2);
    isnt( $config_db, $first, "different DB gets a different shared handle" );
    is( scalar @created, 2, "one connection is opened per DB in the process" );

    my $underlying = $first->_lrr_redis_handle;
    is( $underlying->{quit_count}, 0, "caller quit is a no-op for shared helper ownership" );

    LANraragi::Model::Config::reset_redis_handles();
    is( $underlying->{quit_count}, 1, "reset hook closes the underlying Redis handle" );

    my ( $fh, $path ) = tempfile();
    close $fh;
    @created = ();
    LANraragi::Model::Config::reset_redis_handles();

    my $parent = LANraragi::Model::Config::get_redis_internal(0);
    open my $parent_fh, ">>", $path or die "open $path: $!";
    print {$parent_fh} "parent_wrapper=$parent\n";
    close $parent_fh;

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ( $pid == 0 ) {
        my $child = LANraragi::Model::Config::get_redis_internal(0);
        open my $child_fh, ">>", $path or die "open $path: $!";
        print {$child_fh} "child_wrapper=$child\n";
        close $child_fh;
        _exit(0);
    }
    waitpid( $pid, 0 );

    open my $read_fh, "<", $path or die "open $path: $!";
    my @lines = <$read_fh>;
    close $read_fh;

    my ($parent_line) = grep { /^parent_wrapper=/ } @lines;
    my ($child_line)  = grep { /^child_wrapper=/ } @lines;
    chomp( $parent_line, $child_line );
    ok( $parent_line, "parent recorded its shared handle" );
    ok( $child_line,  "child recorded its shared handle" );
    isnt( $child_line, $parent_line, "child does not reuse the parent's pre-fork shared wrapper" );
}

done_testing();
