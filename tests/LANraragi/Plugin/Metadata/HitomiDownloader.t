use strict;
use warnings;
use utf8;

use Cwd        qw( getcwd );
use File::Temp qw(tempfile);
use File::Copy "cp";

use Mojolicious;
use LANraragi::Model::Config;

use Test::More;
use Test::Deep;
use Test::Trap;

my $cwd = getcwd();

require "$cwd/tests/mocks.pl";
setup_redis_mock();
my $SAMPLES = "${cwd}/tests/samples/hitomi_downloader";

use_ok('LANraragi::Plugin::Metadata::HitomiDownloader');

note("reading hitomi_downloader info.txt");
{
    my ( $fh, $filename ) = tempfile();
    cp( "${SAMPLES}/info.txt", $fh );
    close($fh);

    my %res = LANraragi::Plugin::Metadata::HitomiDownloader::read_file($filename);

    like( $res{title}, qr/Zokuzoku/, 'title parsed' );
    like( $res{tags},  qr/source:hitomi\.la\/galleries\/2734444\.html/, 'source URL from gallery number' );
    like( $res{tags},  qr/group:alps1mando/, 'group tag' );
    like( $res{tags},  qr/category:doujinshi/, 'type as category' );
    like( $res{tags},  qr/language:Korean/, 'language tag' );
    like( $res{tags},  qr/female:big breasts/, 'female tag present' );
    like( $res{tags},  qr/male:dilf/, 'male tag present' );
    like( $res{tags},  qr/tag:multi-work series/, 'bare tag is normalized into the tag namespace' );
    unlike( $res{tags}, qr/(?:^|, )multi-work series(?:,|$)/, 'bare tag is not emitted without a namespace' );
    unlike( $res{tags}, qr/artist:/, 'artist N/A is excluded' );
    unlike( $res{tags}, qr/parody:/, 'series "original" is excluded' );
    unlike( $res{tags}, qr/character:/, 'character N/A is excluded' );
    ok( !-e $filename, 'temp file deleted' );
}

note("checking get_tags with replace_title enabled");
{
    my $lrr_info    = { file_path => "/a/file.zip" };
    my %parsed_data = (
        title => 'Test Title',
        tags  => 'one, two, three',
    );

    no warnings 'once', 'redefine';
    local *LANraragi::Plugin::Metadata::HitomiDownloader::get_plugin_logger         = sub { return get_logger_mock(); };
    local *LANraragi::Plugin::Metadata::HitomiDownloader::extract_file_from_archive = sub { return; };
    local *LANraragi::Plugin::Metadata::HitomiDownloader::is_file_in_archive        = sub { 1 };
    local *LANraragi::Plugin::Metadata::HitomiDownloader::read_file                 = sub { return %parsed_data; };

    my $params = { replace_title => 1 };
    my %res    = LANraragi::Plugin::Metadata::HitomiDownloader::get_tags( undef, $lrr_info, $params );
    ok( exists $res{title}, 'title returned when replace_title is on' );
    ok( exists $res{tags},  'tags returned' );
}

note("checking get_tags with replace_title disabled");
{
    my $lrr_info    = { file_path => "/a/file.zip" };
    my %parsed_data = (
        title => 'Test Title',
        tags  => 'one, two, three',
    );

    no warnings 'once', 'redefine';
    local *LANraragi::Plugin::Metadata::HitomiDownloader::get_plugin_logger         = sub { return get_logger_mock(); };
    local *LANraragi::Plugin::Metadata::HitomiDownloader::extract_file_from_archive = sub { return; };
    local *LANraragi::Plugin::Metadata::HitomiDownloader::is_file_in_archive        = sub { 1 };
    local *LANraragi::Plugin::Metadata::HitomiDownloader::read_file                 = sub { return %parsed_data; };

    my $params = { replace_title => 0 };
    my %res    = LANraragi::Plugin::Metadata::HitomiDownloader::get_tags( undef, $lrr_info, $params );
    ok( !exists $res{title}, 'title not returned when replace_title is off' );
    ok( exists $res{tags},   'tags returned' );
}

note("archive read failures use a user-facing exception without a stack suffix");
{
    my $lrr_info = { file_path => "/a/broken.zip" };
    no warnings 'once', 'redefine';
    local *LANraragi::Plugin::Metadata::HitomiDownloader::is_file_in_archive = sub { die "libarchive failed at helper.pm line 10.\n" };

    trap { LANraragi::Plugin::Metadata::HitomiDownloader::get_tags( undef, $lrr_info, {} ); };
    is(
        $trap->die,
        "Could not read archive '/a/broken.zip': libarchive failed at helper.pm line 10.\n",
        'exception preserves the cause and ends with a newline'
    );
}

note("read_file dies when file is not present");
{
    trap { LANraragi::Plugin::Metadata::HitomiDownloader::read_file("${SAMPLES}/missing.txt"); };

    is( $trap->exit,   undef, 'no exit code' );
    is( $trap->stdout, '',    'no STDOUT' );
    is( $trap->stderr, '',    'no STDERR' );
    like( $trap->die, qr/^Could not open.*missing\.txt/, 'could not open file' );
}

done_testing();
