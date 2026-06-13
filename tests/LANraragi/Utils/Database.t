use strict;
use warnings;
use utf8;
use Cwd;

use Test::More;

my $cwd = getcwd;
require $cwd . "/tests/mocks.pl";
setup_redis_mock();

use LANraragi::Model::Config;
use LANraragi::Utils::Database qw(get_archive_json);

my $id = "e4c422fd10943dc169e3489a38cdbf57101a5f7e";
my $redis = LANraragi::Model::Config->get_redis;

$redis->hset( $id, "firstspreadstart",            "4" );
$redis->hset( $id, "firstspreadstart_confidence", "0.72" );
$redis->hset( $id, "firstspreadstart_reason",     "sample_vote" );
$redis->hset( $id, "firstspreadstart_v",          "1" );

my $json = get_archive_json( $redis, $id );

is( $json->{firstspreadstart},            "4",           "archive JSON includes detected first interior spread start" );
is( $json->{firstspreadstart_confidence}, "0.72",        "archive JSON includes detection confidence" );
is( $json->{firstspreadstart_reason},     "sample_vote", "archive JSON includes detection reason" );
is( $json->{firstspreadstart_v},          "1",           "archive JSON includes detection algorithm version" );

done_testing();
