use v5.36;
use strict;
use warnings;
use Test::More;
use LANraragi::Utils::AdaptiveOffsetAdapter;

sub evidence ($count, @wide) {
    my %wide = map { $_ => 1 } @wide;
    return [map { {page_index => $_, source_width => $wide{$_} ? 200 : 100,
        source_height => 150, side => $_ % 2 ? 'RIGHT' : 'LEFT', confidence => 0.8,
        sha256 => 'a' x 64} } 0 .. $count - 1];
}

my ($groups, $segments) = LANraragi::Utils::AdaptiveOffsetAdapter::vote_inputs(evidence(12, 0, 1), 187);
is_deeply($groups->[0]{observations}, [], 'post-wide evidence cannot vote for the global archive anchor');
is_deeply([map { [$_->{index}, $_->{slot}] } @{$groups->[1]{observations}}],
    [[2,0],[3,1],[4,2],[5,3],[6,4],[7,5],[8,6],[9,7]], 'first post-wide segment uses its own slots');
is_deeply($segments, [{id => 'segment_2', segmentStart => 2, segmentEnd => 187, boundary => 'until_next_wide'}], 'segment stops at the next reader-observed wide even beyond the sampled prefix');

($groups, $segments) = LANraragi::Utils::AdaptiveOffsetAdapter::vote_inputs(evidence(12, 4, 7, 8), 12);
is_deeply([map { [$_->{index}, $_->{slot}] } @{$groups->[0]{observations}}], [[2,1],[3,2]], 'first wide ends global evidence');
is_deeply([map { [$_->{segmentStart}, $_->{segmentEnd}] } @$segments], [[5,7],[9,12]], 'consecutive wides do not form a portrait segment');
is_deeply([map { $_->{index} } @{$groups->[1]{observations}}], [5,6], 'segment evidence cannot cross another wide');

($groups, $segments) = LANraragi::Utils::AdaptiveOffsetAdapter::vote_inputs(evidence(1), 1);
is_deeply($groups->[0]{observations}, [], 'cover-only archive produces an empty vote');
is_deeply($segments, [], 'cover-only archive has no continuation');
eval { LANraragi::Utils::AdaptiveOffsetAdapter::vote_inputs(evidence(3), 12) };
like($@, qr/invalid_archive_prefix/, 'missing prefix evidence is not a successful unknown');
ok(!exists $INC{'LANraragi/Model/Config.pm'}, 'archive adapter does not load config or Redis');
($groups, $segments) = LANraragi::Utils::AdaptiveOffsetAdapter::vote_inputs(evidence(12, 11), 30);
is_deeply($segments, [], 'an unobserved next page is not declared a portrait segment');

{
    package FixtureClient;
    sub vote_groups ($self, $groups, $revision) {
        return [map { {id => $_->{id}, side => $self->{side}, evidence_indices => [],
            relative_gap => 0.8, vote_scores => {LEFT => 0, RIGHT => 0}, confidence_calibrated => 0} } @$groups];
    }
}
my $client = bless {}, 'FixtureClient';
for my $case (['LEFT', '4', 6], ['RIGHT', '2', 5], ['UNKNOWN', 'UNKNOWN', undef]) {
    $client->{side} = $case->[0];
    my $result = LANraragi::Utils::AdaptiveOffsetAdapter::vote_archive($client, evidence(12, 4), 'b' x 64, 12);
    is($result->{first_spread_start}, $case->[1], "$case->[0] uses the legacy global wire value");
    is($result->{segments}[0]{firstPairStart}, $case->[2], "$case->[0] uses a zero-based local first-pair index");
    is($result->{segments}[0]{contentRevision}, 'b' x 64, 'local evidence retains content identity');
}
done_testing;
