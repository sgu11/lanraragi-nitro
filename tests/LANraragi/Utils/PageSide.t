use strict;
use warnings;
use utf8;
use File::Spec;
use File::Temp qw(tempdir);
use POSIX      qw(_exit);

use Test::More;
use Test::MockObject;

# The IM-dependent subtest below eval-guards `require Image::Magick`, but a
# failed require still registers Image::Magick's compiled END block, which
# dies during interpreter cleanup and clobbers the exit code. Track whether
# IM loaded successfully and neutralize that clobbering on the skip path.
our $IM_LOAD_OK;
END { $? = 0 if !$IM_LOAD_OK }

use LANraragi::Utils::PageSide qw(
  choose_first_spread_start
  clear_first_spread_start_detection
  recent_archive_ids
);

sub make_grayscale_test_page {
    my ( $width, $height, $dark_side ) = @_;
    my $strip = 25;
    my $body  = "";
    for my $y ( 0 .. $height - 1 ) {
        for my $x ( 0 .. $width - 1 ) {
            my $is_dark =
                 ( $dark_side eq "left"  && $x < $strip )
              || ( $dark_side eq "right" && $x >= $width - $strip );
            $body .= pack( "C", $is_dark ? 0 : 255 );
        }
    }
    return "P5\n$width $height\n255\n" . $body;
}

sub imagemagick_available {
    my $pid = fork();
    return 0 unless defined $pid;

    if ( $pid == 0 ) {
        open STDOUT, ">", File::Spec->devnull;
        open STDERR, ">", File::Spec->devnull;
        my $ok = eval {
            require Image::Magick;
            Image::Magick->new;
            1;
        };
        _exit( $ok ? 0 : 1 );
    }

    waitpid( $pid, 0 );
    return $? == 0;
}

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

subtest "projects interior samples to first spread anchored on page 4" => sub {
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

    is( $result->{first_spread_start}, 4, "page 3 RIGHT / page 4 LEFT implies Pair 3-4" );
};

subtest "detects page side through libvips when ImageMagick is unavailable" => sub {
    my $vips_ok = eval {
        require LANraragi::Utils::Vips;
        LANraragi::Utils::Vips::init("pageside-vips-test");
        LANraragi::Utils::Vips::is_vips_loaded();
    };
    plan skip_all => "libvips not available" unless $vips_ok;

    my $left_blob = make_grayscale_test_page( 200, 300, "left" );

    local @INC = (
        sub {
            my ( $coderef, $filename ) = @_;
            die "ImageMagick deliberately unavailable\n" if $filename eq "Image/Magick.pm";
            return;
        },
        @INC
    );

    my $left_sample = LANraragi::Utils::PageSide::detect_page_side( $left_blob, 3 );

    is( $left_sample->{side}, "LEFT", "libvips fallback detects the page as LEFT" );
    isnt( $left_sample->{reason}, "decode_failed", "decode succeeds without ImageMagick" );
};

subtest "detects page side from the lower-complexity blank strip" => sub {
    plan skip_all => "Image::Magick not available" unless imagemagick_available();

    $IM_LOAD_OK = eval { require Image::Magick; 1 };
    plan skip_all => "Image::Magick not available" unless $IM_LOAD_OK;

    my $left_page = Image::Magick->new( size => "200x300" );
    $left_page->ReadImage("xc:white");
    $left_page->Draw( primitive => "rectangle", points => "0,0 24,299", fill => "black" );
    $left_page->Set( magick => "PNG" );
    my $left_blob   = $left_page->ImageToBlob;
    my $left_sample = LANraragi::Utils::PageSide::detect_page_side( $left_blob, 2 );

    is( $left_sample->{side}, "LEFT", "blanker right strip means an RTL left page" );

    my $right_page = Image::Magick->new( size => "200x300" );
    $right_page->ReadImage("xc:white");
    $right_page->Draw( primitive => "rectangle", points => "175,0 199,299", fill => "black" );
    $right_page->Set( magick => "PNG" );
    my $right_blob   = $right_page->ImageToBlob;
    my $right_sample = LANraragi::Utils::PageSide::detect_page_side( $right_blob, 3 );

    is( $right_sample->{side}, "RIGHT", "blanker left strip means an RTL right page" );
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

subtest "recent archive selection sorts by file mtime and returns all archives by default" => sub {
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

    my @recent = recent_archive_ids($redis);

    is( scalar @recent, 60, "recent archive selection is uncapped by default" );
    is( $recent[0], sprintf( "%040d", 60 ), "newest archive is first" );
    is( $recent[-1], sprintf( "%040d", 1 ), "oldest archive is retained when no limit is provided" );
};

subtest "recent archive selection honors an explicit positive limit" => sub {
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

    my @recent = recent_archive_ids( $redis, 12 );

    is( scalar @recent, 12, "explicit limit keeps a bounded newest subset" );
    is( $recent[0], sprintf( "%040d", 60 ), "newest archive is first" );
    is( $recent[-1], sprintf( "%040d", 49 ), "explicit limit determines the last retained archive" );
};

done_testing();
