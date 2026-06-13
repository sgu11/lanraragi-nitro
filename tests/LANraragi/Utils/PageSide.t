use strict;
use warnings;
use utf8;
use File::Temp qw(tempdir);

use Test::More;
use Test::MockObject;

use LANraragi::Utils::PageSide qw(
  choose_first_spread_start
  clear_first_spread_start_detection
  recent_archive_ids
);

subtest "projects interior samples to first spread starting at page 2" => sub {
    my $result = choose_first_spread_start(
        [
            {
                page_index => 2,
                side       => "LEFT",
                confidence => 0.83,
                reason     => "edge_complexity"
            },
            {
                page_index => 3,
                side       => "RIGHT",
                confidence => 0.79,
                reason     => "edge_complexity"
            }
        ]
    );

    is( $result->{first_spread_start}, 2, "page 3 LEFT / page 4 RIGHT implies Pair 2-3" );
    like( $result->{reason}, qr/sample_vote/, "sample-vote reason is recorded" );
};

subtest "projects interior samples to first spread starting at page 3" => sub {
    my $result = choose_first_spread_start(
        [
            {
                page_index => 2,
                side       => "RIGHT",
                confidence => 0.78,
                reason     => "edge_complexity"
            },
            {
                page_index => 3,
                side       => "LEFT",
                confidence => 0.76,
                reason     => "edge_complexity"
            }
        ]
    );

    is( $result->{first_spread_start}, 3, "page 3 RIGHT / page 4 LEFT implies Pair 3-4" );
};

subtest "ignores cover and page 2 samples for first interior spread detection" => sub {
    my $result = choose_first_spread_start(
        [
            {
                page_index => 0,
                side       => "LEFT",
                confidence => 0.95,
                reason     => "cover_art"
            },
            {
                page_index => 1,
                side       => "LEFT",
                confidence => 0.95,
                reason     => "title_page"
            }
        ]
    );

    is( $result->{first_spread_start}, "UNKNOWN", "cover and page 2 do not determine interior pairing" );
};

subtest "returns unknown when fewer than two interior samples are confident" => sub {
    my $result = choose_first_spread_start(
        [
            {
                page_index => 2,
                side       => "LEFT",
                confidence => 0.83,
                reason     => "edge_complexity"
            },
            {
                page_index => 3,
                side       => "UNKNOWN",
                confidence => 0.50,
                reason     => "wide_page"
            }
        ]
    );

    is( $result->{first_spread_start}, "UNKNOWN", "single confident sample is not enough" );
};

subtest "clears spread-start and legacy page-side detection fields" => sub {
    my @deleted;
    my $redis = Test::MockObject->new;
    $redis->mock( hdel => sub { my ( $self, $id, @fields ) = @_; push @deleted, @fields; return scalar @fields; } );

    clear_first_spread_start_detection( $redis, "abc" );

    my %deleted = map { $_ => 1 } @deleted;
    ok( $deleted{firstspreadstart},      "firstspreadstart is cleared" );
    ok( $deleted{firstspreadstart_v},    "firstspreadstart_v is cleared" );
    ok( $deleted{firstpageside},         "legacy firstpageside is cleared" );
    ok( $deleted{firstpageside_v},       "legacy firstpageside_v is cleared" );
};

subtest "recent archive selection sorts by file mtime and caps at 50" => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    my %files;
    my @ids;

    for my $i ( 1 .. 60 ) {
        my $id = sprintf( "%040d", $i );
        my $file = "$tmp/$i.cbz";
        open my $fh, ">", $file or die "Could not write $file: $!";
        print $fh $i;
        close $fh;
        utime( 1000 + $i, 1000 + $i, $file );
        push @ids, $id;
        $files{$id} = $file;
    }

    my $redis = Test::MockObject->new;
    $redis->mock( smembers => sub { return @ids; } );
    $redis->mock( hget     => sub { my ( $self, $id, $field ) = @_; return $field eq "file" ? $files{$id} : undef; } );

    my @recent = recent_archive_ids( $redis, 9000 );

    is( scalar @recent, 50, "recent archive selection is capped at 50" );
    is( $recent[0], sprintf( "%040d", 60 ), "newest archive is first" );
    is( $recent[-1], sprintf( "%040d", 11 ), "cap keeps only the newest 50 archives" );
};

done_testing();
