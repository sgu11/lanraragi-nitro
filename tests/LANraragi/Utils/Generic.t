use strict;
use warnings;
use utf8;
use Data::Dumper;
use Encode qw(decode_utf8);

use Test::More;
use Test::Deep;

BEGIN { use_ok('LANraragi::Utils::Generic'); }

package FakeLockRedis {
    sub new {
        my ($class) = @_;
        return bless { set_calls => [], eval_calls => [] }, $class;
    }

    sub set {
        my ( $self, @args ) = @_;
        push @{ $self->{set_calls} }, \@args;
        return 1;
    }

    sub eval {
        my ( $self, @args ) = @_;
        push @{ $self->{eval_calls} }, \@args;
        return 1;
    }
}

package main;

note('testing rules flattening...');

{
    my $tagrules = [
        [ 'strip_ns', 'namespace', '' ],
        [ 'replace', 'scream', 'Please Stop' ],
        [ 'remove', 'ping', '']
    ];

    my @flattened_rules = LANraragi::Utils::Generic::flat(@$tagrules);
    cmp_deeply(
        \@flattened_rules,
        [
            'strip_ns',
            'namespace',
            '',
            'replace',
            'scream',
            'Please Stop',
            'remove',
            'ping',
            ''
        ],
        'flattened rules');
}

note('testing lock names...');

{
    my $redis = FakeLockRedis->new;
    my ( $acquired, $response );
    my $err = "";

    eval {
        ( $acquired, $response ) = LANraragi::Utils::Generic::exec_with_lock_pure(
            ["upload:한글.zip"],
            sub { return "locked"; },
            $redis
        );
        1;
    } or $err = $@;

    is( $err,      "",       "unicode lock names do not fail digest token generation" );
    ok( $acquired,           "unicode lock is acquired" );
    is( $response, "locked", "unicode lock callback response is returned" );
    my $lock_key = $redis->{set_calls}[0] ? $redis->{set_calls}[0][0] : "";
    ok( $lock_key ne "" && !utf8::is_utf8($lock_key), "unicode lock key is passed to redis as bytes" );
    is( $lock_key ne "" ? decode_utf8($lock_key) : "", "upload:한글.zip", "unicode lock key preserves its text" );
}

done_testing();
