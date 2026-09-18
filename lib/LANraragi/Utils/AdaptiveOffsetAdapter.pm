package LANraragi::Utils::AdaptiveOffsetAdapter;

use v5.36;
use strict;
use warnings;
use List::Util qw(min);

# Archive policy only. This adapter has no chapter relationships, persistence,
# manual corrections or image acquisition. The caller owns content identity.
sub vote_inputs ($evidence, $page_count) {
    die "invalid_archive_page_count\n" unless defined $page_count && "$page_count" =~ /\A[1-9][0-9]*\z/ && $page_count <= 1_000_000;
    my %byindex = map { $_->{page_index} => $_ } @$evidence;
    die "invalid_archive_prefix\n" unless keys(%byindex) == min(12, $page_count)
      && !grep { !exists $byindex{$_} } 0 .. min(11, $page_count - 1);
    my @wide = sort {$a <=> $b} grep { $byindex{$_}{source_width} > $byindex{$_}{source_height} } keys %byindex;
    my $stop = (grep { $_ >= 1 } @wide)[0] // $page_count;
    my $observations = sub ($start, $end, $origin) {
        return [map {
            my $e = $byindex{$_};
            {index => 0 + $_, slot => $_ - $origin, side => $e->{side}, strength => $e->{confidence}, sha256 => $e->{sha256}}
        } grep { exists $byindex{$_} } $start .. $end - 1];
    };
    my @groups = ({id => 'global', observations => $observations->(2, min(10, $stop), 1)});
    my @segments;
    for my $wide (grep { $_ >= 1 && $_ + 1 < $page_count } @wide) {
        my $start = $wide + 1;
        next unless exists $byindex{$start};
        next if grep { $_ == $start } @wide;
        my $end = (grep { $_ > $start } @wide)[0] // $page_count;
        my $id = "segment_$start";
        push @groups, {id => $id, observations => $observations->($start, min($start + 8, $end), $start)};
        push @segments, {id => $id, segmentStart => $start, segmentEnd => $end, boundary => 'until_next_wide'};
    }
    return (\@groups, \@segments);
}

sub vote_archive ($client, $evidence, $revision, $page_count) {
    my ($groups, $segments) = vote_inputs($evidence, $page_count);
    my $votes = $client->vote_groups($groups, $revision);
    my %byid = map { $_->{id} => $_ } @$votes;
    my $global = $byid{global};
    my %wire = (LEFT => '4', RIGHT => '2', UNKNOWN => 'UNKNOWN');
    return {
        first_spread_start => $wire{$global->{side}},
        global => $global,
        segments => [map {
            my $vote = $byid{$_->{id}};
            +{%$_, contentRevision => $revision, provenance => 'detector', vote => $vote,
                firstPairStart => $vote->{side} eq 'UNKNOWN' ? undef : $_->{segmentStart} + ($vote->{side} eq 'LEFT' ? 1 : 0)}
        } @$segments]
    };
}

1;
