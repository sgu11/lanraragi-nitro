use strict;
use warnings;
use utf8;
use Data::Dumper;

use Cwd qw( getcwd );
use Mojo::JSON qw(decode_json encode_json);
use Mojo::File;
use Mojo::Transaction::HTTP;

use Test::More;
use Test::Deep;
use Test::MockObject;

my $cwd     = getcwd();
my $SAMPLES = "$cwd/tests/samples";
require "$cwd/tests/mocks.pl";
setup_redis_mock();

my @all_tags = ( 'language:japanese', 'artist:masamune shirow', 'full color', 'non-h', 'artbook', 'category:manga' );

use_ok('LANraragi::Plugin::Metadata::nHentai');

note('testing searching gallery by title ...');

{
    my $json = decode_json( Mojo::File->new("$SAMPLES/nh/002_search_results_empty.json")->slurp );

    no warnings 'once', 'redefine';
    local *LANraragi::Plugin::Metadata::nHentai::get_plugin_logger = sub { return get_logger_mock(); };
    local *LANraragi::Plugin::Metadata::nHentai::get_search_json   = sub { return $json; };

    my $gID = LANraragi::Plugin::Metadata::nHentai::get_gallery_id_from_title("you will not find this", undef);

    is( $gID, undef, 'empty gallery ID' );
}

{
    my $json = decode_json( Mojo::File->new("$SAMPLES/nh/001_search_results.json")->slurp );

    no warnings 'once', 'redefine';
    local *LANraragi::Plugin::Metadata::nHentai::get_plugin_logger = sub { return get_logger_mock(); };
    local *LANraragi::Plugin::Metadata::nHentai::get_search_json   = sub { return $json; };

    my $gID = LANraragi::Plugin::Metadata::nHentai::get_gallery_id_from_title("a title that exists", undef);

    is( $gID, '52249', 'gallery ID' );
}

subtest 'search quotes and escapes the filename title' => sub {
    no warnings 'once', 'redefine';
    local *LANraragi::Plugin::Metadata::nHentai::get_plugin_logger = sub { return get_logger_mock(); };

    my @urls;
    my $transaction = Mojo::Transaction::HTTP->new;
    $transaction->res->code(200);
    $transaction->res->body( Mojo::File->new("$SAMPLES/nh/001_search_results.json")->slurp );
    my $ua = Test::MockObject->new;
    $ua->mock( get => sub { push @urls, $_[1]; return $transaction; } );

    my $gID = LANraragi::Plugin::Metadata::nHentai::get_gallery_id_from_title(
        "/archives/JoJo's 冒険 & more+bonus?.cbz", $ua );

    is( $gID, '52249', 'returns the first gallery from the decoded search response' );
    is_deeply(
        \@urls,
        [ 'https://nhentai.net/api/v2/search?query=%22JoJo%27s%20%E5%86%92%E9%99%BA%20%26%20more%2Bbonus%3F%22' ],
        'wraps the title in quotes and escapes apostrophes, Unicode and query metacharacters'
    );
};

subtest 'malformed API responses fail explicitly' => sub {
    no warnings 'once', 'redefine';
    local *LANraragi::Plugin::Metadata::nHentai::get_plugin_logger = sub { return get_logger_mock(); };

    my $transaction = Mojo::Transaction::HTTP->new;
    $transaction->res->code(200);
    $transaction->res->body('<html>upstream unavailable</html>');
    my $ua = Test::MockObject->new;
    $ua->mock( get => sub { return $transaction; } );

    my $search_ok = eval { LANraragi::Plugin::Metadata::nHentai::get_search_json( 'example', $ua ); 1; };
    my $search_error = $@;
    ok( !$search_ok, 'malformed search JSON raises an error' );
    ok( length($search_error), 'search failure reports a parsing error' );

    my $gallery_ok = eval { LANraragi::Plugin::Metadata::nHentai::get_tags_from_nh( 52249, $ua, 0 ); 1; };
    my $gallery_error = $@;
    ok( !$gallery_ok, 'malformed gallery JSON does not return successful empty metadata' );
    ok( length($gallery_error), 'gallery failure reports a parsing error' );
};

note('testing getting tags from JSON ...');

{
    no warnings 'once', 'redefine';
    local *LANraragi::Plugin::Metadata::nHentai::get_plugin_logger = sub { return get_logger_mock(); };

    my $json = decode_json( Mojo::File->new("$SAMPLES/nh/003_gid_52249.json")->slurp );

    my @tags = LANraragi::Plugin::Metadata::nHentai::get_tags_from_json($json);

    cmp_bag( \@tags, \@all_tags, 'tag list' );
}

note('testing getting tags from JSON ...');

{
    no warnings 'once', 'redefine';
    local *LANraragi::Plugin::Metadata::nHentai::get_plugin_logger = sub { return get_logger_mock(); };

    my $json = decode_json( Mojo::File->new("$SAMPLES/nh/003_gid_52249.json")->slurp );

    my $title = LANraragi::Plugin::Metadata::nHentai::get_title_from_json($json);

    is( $title, 'Pieces 1', 'title' );
}

subtest 'title fallback preserves preferred names' => sub {
    is(
        LANraragi::Plugin::Metadata::nHentai::get_title_from_json(
            { title => { pretty => 'Preferred title', english => 'English title' } } ),
        'Preferred title',
        'uses the pretty title when available'
    );
    is(
        LANraragi::Plugin::Metadata::nHentai::get_title_from_json(
            { title => { pretty => '', english => 'English title' } } ),
        'English title',
        'uses the English title when the pretty title is empty'
    );
    is(
        LANraragi::Plugin::Metadata::nHentai::get_title_from_json(
            { title => { english => 'English title' } } ),
        'English title',
        'uses the English title when the pretty title is missing'
    );
};

done_testing();
