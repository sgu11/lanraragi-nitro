#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Time::HiRes qw(time);
use JSON::PP qw(encode_json);
use LANraragi::Utils::PHash qw(hamming_packed);

# Synthetic, deterministic input only. No production archive data is exported.
my $size = $ARGV[0] // 1500;
die "size must be 2..10000\n" unless $size =~ /^\d+$/ && $size >= 2 && $size <= 10000;
srand 19;
my @hashes = ('0000000000000000', '0001000100010001');
push @hashes, join('', map { sprintf('%04x', int(rand(65536))) } 1..4) while @hashes < $size;
my @packed = map { pack('H*', $_) } @hashes;
my @counts = map { unpack('%32b*', pack('C', $_)) } 0..255;
my (%reference, %exact, %banded, %seconds);
my $threshold = 22;
for my $mode (qw(reference packed banded)) {
    my $started = time();
    for my $i (0 .. $#hashes - 1) {
        for my $j ($i + 1 .. $#hashes) {
            my $distance;
            if ($mode eq 'reference') {
                # Previous implementation, independent of the optimized helper.
                my $xor = pack('H*', $hashes[$i]) ^. pack('H*', $hashes[$j]);
                $distance = 0;
                $distance += $counts[$_] for unpack('C*', $xor);
            } else {
                if ($mode eq 'banded') {
                    next unless grep { substr($hashes[$i], $_, 4) eq substr($hashes[$j], $_, 4) } (0, 4, 8, 12);
                }
                $distance = hamming_packed($packed[$i], $packed[$j]);
            }
            next if $distance > $threshold;
            my $dest = $mode eq 'reference' ? \%reference : $mode eq 'packed' ? \%exact : \%banded;
            $dest->{"$i|$j"} = $distance;
        }
    }
    $seconds{$mode} = time() - $started;
}
die "Exact matcher differs from reference\n" if keys(%reference) != keys(%exact)
    || grep { !exists($exact{$_}) || $exact{$_} != $reference{$_} } keys %reference;
say encode_json({size => 0+$size, threshold => $threshold, comparisons => $size * ($size - 1) / 2,
    seconds => \%seconds, speedup => $seconds{reference} / $seconds{packed},
    reference_pairs => scalar(keys %reference), exact_pairs => scalar(keys %exact),
    banded_pairs => scalar(keys %banded), banded_recall => keys(%banded) / keys(%reference),
    note => 'Banded timing includes a simple candidate predicate scan, not Redis bucket generation.'});
