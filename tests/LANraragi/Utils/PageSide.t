use strict;
use warnings;
use utf8;
use File::Temp qw(tempdir);

use Test::More;
use Test::MockObject;

use LANraragi::Utils::PageSide qw(
  choose_first_page_side
  recent_archive_ids
);

subtest "uses confident first-page detection directly" => sub {
    my $result = choose_first_page_side(
        [
            {
                page_index => 0,
                side       => "LEFT",
                confidence => 0.83,
                reason     => "edge_complexity"
            }
        ]
    );

    is( $result->{side},   "LEFT",            "first page side is preserved" );
    is( $result->{reason}, "edge_complexity", "first page reason is preserved" );
    cmp_ok( $result->{confidence}, ">=", 0.83, "confidence is preserved" );
};

subtest "projects a confident page sample back to the first page side" => sub {
    my $result = choose_first_page_side(
        [
            {
                page_index => 1,
                side       => "LEFT",
                confidence => 0.78,
                reason     => "edge_complexity"
            }
        ]
    );

    is( $result->{side}, "RIGHT", "page 1 LEFT implies the first page is RIGHT" );
    like( $result->{reason}, qr/sample_vote/, "sample-vote reason is recorded" );
};

subtest "returns unknown when no sample is confident enough" => sub {
    my $result = choose_first_page_side(
        [
            {
                page_index => 0,
                side       => "UNKNOWN",
                confidence => 0.50,
                reason     => "aspect_reject"
            },
            {
                page_index => 1,
                side       => "LEFT",
                confidence => 0.54,
                reason     => "weak_margin"
            }
        ]
    );

    is( $result->{side}, "UNKNOWN", "weak samples produce UNKNOWN" );
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
