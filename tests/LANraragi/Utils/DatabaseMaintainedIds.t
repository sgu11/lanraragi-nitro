use strict;
use warnings;
use Test::More;
use LANraragi::Utils::Database;

package MaintainedRedis {
    sub new { bless { strings => {}, members => [], scans => 0 }, shift }
    sub smembers { @{ $_[0]{members} } }
    sub keys { $_[0]{scans}++; return () }
    sub get { $_[0]{strings}{$_[1]} }
    sub set { $_[0]{strings}{$_[1]} = $_[2] }
}
package main;
for my $function (qw(all_archive_ids all_category_ids all_tank_ids)) {
    my $redis = MaintainedRedis->new;
    my $enumerate = LANraragi::Utils::Database->can($function);
    is_deeply( [ $enumerate->($redis) ], [], "$function backfills an empty library" );
    is_deeply( [ $enumerate->($redis) ], [], "$function accepts an initialized empty set" );
    is( $redis->{scans}, 1, 'empty set only scans once' );
    $redis->{members} = ['added'];
    is_deeply( [ $enumerate->($redis) ], ['added'], 'later writes remain visible' );
    $redis->{members} = [];
    $enumerate->($redis);
    is( $redis->{scans}, 1, 'deleting the last member does not restart backfill' );
    $redis->{strings} = {};
    $enumerate->($redis);
    is( $redis->{scans}, 2, 'database reset permits a new backfill' );
}
done_testing();
