package LANraragi::Utils::AdaptiveOffsetVote;

use v5.36;
use strict;
use warnings;
use JSON::PP ();
use List::Util qw(sum);
use Scalar::Util qw(looks_like_number);
use POSIX qw(isfinite);

use constant ALGORITHM_VERSION => 'lrr-vips320-v1-vote1';

# The preregistered common rule. Inputs are explicit logical slots, not chapter
# relationships or archive offsets. Scores are evidence, not probabilities.
sub aggregate ($observations) {
    my %votes = (LEFT => 0, RIGHT => 0);
    my @used;
    for my $observation (@$observations) {
        my ($index, $slot, $side, $strength) = @{$observation}{qw(index slot side strength)};
        die "invalid_strength\n" unless defined $strength && looks_like_number($strength)
          && isfinite($strength) && $strength >= 0 && $strength <= 1;
        next unless exists $votes{$side} && $strength >= 0.25;
        my $projected = $slot % 2 == 0 ? $side : $side eq 'LEFT' ? 'RIGHT' : 'LEFT';
        $votes{$projected} += $strength;
        push @used, $index;
    }
    my $total = sum(values %votes);
    my $gap = $total ? abs($votes{LEFT} - $votes{RIGHT}) / $total : 0;
    my $winner = $votes{LEFT} >= $votes{RIGHT} ? 'LEFT' : 'RIGHT';
    return {
        side => @used >= 2 && $gap >= 0.25 ? $winner : 'UNKNOWN',
        vote_scores => \%votes, relative_gap => $gap, evidence_indices => \@used,
        confidence_calibrated => JSON::PP::false,
    };
}

1;
