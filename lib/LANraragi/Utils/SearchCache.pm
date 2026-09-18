package LANraragi::Utils::SearchCache;

use v5.36;
use strict;
use warnings;
use List::Util qw(min max);
use Exporter qw(import);
our @EXPORT_OK = qw(store_results read_result_page);

# Versioned by search_cache_key. Two uint32 counts, then fixed-width ASCII IDs
# (40-char archive hashes or shorter TANK ids). GETRANGE reads only the page.
use constant HEADER_BYTES => 8;
use constant ID_BYTES => 40;

sub store_results ( $redis, $key, $keyed_count, $ids ) {
    die "Invalid search result id\n" if grep { !defined $_ || length($_) > ID_BYTES || /[^\x21-\x7e]/ } @$ids;
    my $count = scalar @$ids;
    $keyed_count = $count if $keyed_count < 0;
    $redis->set( $key, pack( 'NN', $count, $keyed_count ) . join('', map { pack('a40', $_) } @$ids), 'EX', 300 );
}

sub _read_range ( $redis, $key, $start, $end ) {
    return [] if $start > $end;
    my $bytes = $redis->getrange( $key, HEADER_BYTES + ID_BYTES * $start, HEADER_BYTES + ID_BYTES * ($end + 1) - 1 );
    return if !defined $bytes || length($bytes) != ID_BYTES * ($end - $start + 1);
    my @ids = unpack('(a40)*', $bytes);
    s/\0+$// for @ids;
    return \@ids;
}

sub read_result_page ( $redis, $key, $inverse_key, $start, $limit ) {
    for my $inverse (0, 1) {
        my $candidate = $inverse ? $inverse_key : $key;
        my $header = $redis->getrange( $candidate, 0, HEADER_BYTES - 1 );
        next if !defined $header || length($header) != HEADER_BYTES;
        my ( $count, $keyed ) = unpack('NN', $header);
        next if $keyed > $count;
        my $first = max(0, $start);
        my $last = $start == -1 ? $count - 1 : min($count - 1, $first + $limit - 1);
        return (1, $count) if $first > $last;
        my @ids;
        if ($inverse && $keyed > 0 && $first < $keyed) {
            my $prefix_end = min($last, $keyed - 1);
            my $prefix = _read_range( $redis, $candidate, $keyed - 1 - $prefix_end, $keyed - 1 - $first );
            next unless defined $prefix;
            push @ids, reverse @$prefix;
            $first = $prefix_end + 1;
        }
        my $suffix = _read_range( $redis, $candidate, $first, $last );
        next unless defined $suffix; # TTL expiry between header and payload is a miss.
        push @ids, @$suffix;
        return (1, $count, @ids);
    }
    return (0, 0);
}

1;
