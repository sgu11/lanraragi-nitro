#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use MIME::Base64 qw(decode_base64);
use Compress::Zlib qw(uncompress);
use LANraragi::Utils::PageSideDetector;
use LANraragi::Utils::AdaptiveOffsetVote;

# Actual worker-core trace only. Golden traces are independently captured from
# the original PageSide implementation and preregistered Python vote recipe.
my $input = decode_json(do { local $/; <STDIN> });
my @trace;
for my $fixture (@{$input->{pixels}}) {
    my $bytes = uncompress(decode_base64($fixture->{gray_zlib_base64}));
    die "invalid_raster\n" unless defined $bytes && length($bytes) == $fixture->{width} * $fixture->{height};
    no warnings 'redefine';
    local *LANraragi::Utils::PageSideDetector::_decode_page_luminance_with_vips = sub {
        return unless $fixture->{decoded};
        return {width => $fixture->{width}, height => $fixture->{height}, pixel_at => sub ($x, $y) {
            return ord(substr($bytes, $y * $fixture->{width} + $x, 1)) / 255;
        }};
    };
    local *LANraragi::Utils::PageSideDetector::_decode_page_luminance_with_imagemagick = sub { return; };
    my $result = LANraragi::Utils::PageSideDetector::detect_page_side('', 0);
    push @trace, {id => $fixture->{id}, tuple => {side => $result->{side}, reason => $result->{reason},
        confidence => 0 + sprintf('%.6f', $result->{confidence})}};
}
for my $fixture (@{$input->{votes}}) {
    my @observations = map { {index => $_->[0], slot => $_->[1], side => $_->[2]{side}, strength => $_->[2]{strength}} } @{$fixture->{observations}};
    my $result = LANraragi::Utils::AdaptiveOffsetVote::aggregate(\@observations);
    $result->{relative_gap} = 0 + sprintf('%.6f', $result->{relative_gap});
    $result->{vote_scores}{$_} = 0 + sprintf('%.6f', $result->{vote_scores}{$_}) for qw(LEFT RIGHT);
    push @trace, {id => $fixture->{id}, tuple => $result};
}
print encode_json(\@trace), "\n";
