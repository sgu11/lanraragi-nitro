use strict;
use warnings;
use utf8;

use File::Temp qw(tempdir tempfile);
use Mojo::Message::Response;
use Test::More;

use LANraragi::Model::Upload;

package FakeUploadRedis {
    sub new { bless { quit => 0 }, shift }
    sub exists { return 0 }
    sub quit { $_[0]->{quit}++; return 1 }
}

package FakeUploadLogger {
    sub debug { return 1 }
    sub info { return 1 }
    sub warn { return 1 }
}

package FakeUploadTransaction {
    sub new { bless { result => $_[1] }, $_[0] }
    sub result { return $_[0]->{result} }
}

package main;

my $userdir = tempdir( CLEANUP => 1 );
my ( $fh, $tempfile ) = tempfile( SUFFIX => '.zip', UNLINK => 1 );
print {$fh} "archive fixture";
close $fh;

my $archive_redis = FakeUploadRedis->new;
my $search_redis  = FakeUploadRedis->new;
my $config_redis  = FakeUploadRedis->new;
my $added         = 0;

no warnings 'redefine';
local *LANraragi::Model::Upload::get_logger = sub { bless {}, 'FakeUploadLogger' };
local *LANraragi::Model::Config::get_userdir = sub { return $userdir };
local *LANraragi::Model::Config::get_redis = sub { return $archive_redis };
local *LANraragi::Model::Config::get_redis_search = sub { return $search_redis };
local *LANraragi::Model::Config::get_redis_config = sub { return $config_redis };
local *LANraragi::Model::Config::get_replacedupe = sub { return 0 };
local *LANraragi::Model::Upload::move_path = sub { $! = 13; return 0 };
local *LANraragi::Model::Upload::add_archive_to_redis = sub { $added++; return 'unexpected' };

my ( $status, $id, $name, $message ) =
  LANraragi::Model::Upload::handle_incoming_file( $tempfile, undef, undef, undef, undef );
is( $status, 500, 'failed content-directory move is reported' );
like( $message, qr/couldn't be moved/, 'failed move has a useful error' );
is( $added, 0, 'failed move cannot create a phantom archive record' );
is( $archive_redis->{quit}, 1, 'archive Redis is closed on move failure' );
is( $search_redis->{quit}, 1, 'search Redis is closed on move failure' );
is( $config_redis->{quit}, 1, 'config Redis is closed on move failure' );

{
    my @validated_hosts;
    my @requested_hosts;
    local *LANraragi::Model::Upload::validate_public_http_url = sub {
        my ($url) = @_;
        push @validated_hosts, $url->host;
        die "Download host resolved to an unsafe address.\n" if $url->host eq 'private.example';
        return ( $url, '93.184.216.34' );
    };
    local *LANraragi::Model::Upload::_download_http_hop = sub {
        my ( $ua, $url ) = @_;
        push @requested_hosts, $url->host;
        my $response = Mojo::Message::Response->new->code(302);
        $response->headers->location('http://private.example/archive.zip');
        return FakeUploadTransaction->new($response);
    };

    my $ok = eval { LANraragi::Model::Upload::download_url( 'https://public.example/archive.zip', bless({}, 'FakeUA') ); 1 };
    ok( !$ok, 'private redirect target is rejected' );
    like( $@, qr/unsafe address/, 'private redirect reports the SSRF boundary' );
    is_deeply( \@validated_hosts, [ 'public.example', 'private.example' ], 'every redirect hop is revalidated' );
    is_deeply( \@requested_hosts, ['public.example'], 'private redirect is rejected before a request is made' );
}

done_testing();
