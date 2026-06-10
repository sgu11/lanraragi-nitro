package LANraragi::Utils::Tachiyomi;

use strict;
use warnings;
use utf8;

use Digest::SHA qw(sha1_hex);
use Exporter 'import';
use Storable   qw(nfreeze thaw);

use LANraragi::Model::Config;

our @EXPORT_OK = qw(
  is_tachiyomi_client tachiyomi_cache_identity tachiyomi_cache_key
  get_tachiyomi_response_cache set_tachiyomi_search_cache set_tachiyomi_random_cache
  get_tachiyomi_metadata_cache set_tachiyomi_metadata_cache enqueue_tachiyomi_filelist_warm
);

use constant TACHIYOMI_SEARCH_CACHE_TTL   => 30;
use constant TACHIYOMI_RANDOM_CACHE_TTL   => 10;
use constant TACHIYOMI_METADATA_CACHE_TTL => 30;
use constant TACHIYOMI_WARM_FILELIST_TTL  => 60;

my %METADATA_CACHE;
my %FILELIST_WARMED;

sub is_tachiyomi_client {
    my ($controller) = @_;

    my $ua = eval { $controller->req->headers->user_agent } // "";
    return $ua =~ /(?:Tachiyomi|Mihon|Aniyomi|Suwayomi)/i ? 1 : 0;
}

sub tachiyomi_cache_identity {
    my ($controller) = @_;

    my $authorization = eval { $controller->req->headers->authorization } // "";
    return $authorization if length $authorization;

    return eval { $controller->tx->remote_address } // "";
}

sub tachiyomi_cache_key {
    my ( $controller, $scope, @parts ) = @_;

    my $identity = tachiyomi_cache_identity($controller);
    return "LRR_TACHIYOMI_API:$scope:" . sha1_hex( join "\x1f", $identity, map { defined $_ ? $_ : "" } @parts );
}

sub get_tachiyomi_response_cache {
    my ($cachekey) = @_;
    return unless $cachekey;

    my $redis = LANraragi::Model::Config->get_redis_search;
    my $gen   = $redis->get("LRR_SEARCHCACHE_GEN") // 0;
    my $blob  = $redis->get("LRR_SEARCHCACHE:$gen:$cachekey");
    $redis->quit;

    return unless defined $blob && length $blob;
    my $payload = eval { thaw($blob) };
    return $@ ? undef : $payload;
}

sub _set_tachiyomi_response_cache {
    my ( $cachekey, $payload, $ttl ) = @_;
    return unless $cachekey && $payload;

    my $redis = LANraragi::Model::Config->get_redis_search;
    my $gen   = $redis->get("LRR_SEARCHCACHE_GEN") // 0;
    eval { $redis->set( "LRR_SEARCHCACHE:$gen:$cachekey", nfreeze($payload), 'EX', $ttl ); };
    $redis->quit;
}

sub set_tachiyomi_search_cache {
    my ( $cachekey, $payload ) = @_;
    _set_tachiyomi_response_cache( $cachekey, $payload, TACHIYOMI_SEARCH_CACHE_TTL );
}

sub set_tachiyomi_random_cache {
    my ( $cachekey, $payload ) = @_;
    _set_tachiyomi_response_cache( $cachekey, $payload, TACHIYOMI_RANDOM_CACHE_TTL );
}

sub get_tachiyomi_metadata_cache {
    my ($id) = @_;
    my $entry = $METADATA_CACHE{$id};
    return unless $entry;

    if ( $entry->{expiry} <= time ) {
        delete $METADATA_CACHE{$id};
        return;
    }

    return $entry->{value};
}

sub set_tachiyomi_metadata_cache {
    my ( $id, $value ) = @_;
    $METADATA_CACHE{$id} = {
        value  => $value,
        expiry => time + TACHIYOMI_METADATA_CACHE_TTL
    };
}

sub enqueue_tachiyomi_filelist_warm {
    my ( $controller, $id ) = @_;
    return unless defined $id && $id =~ /^[A-Za-z0-9_]{40}$/;

    my $now = time;
    return if ( $FILELIST_WARMED{$id} // 0 ) > $now;

    $FILELIST_WARMED{$id} = $now + TACHIYOMI_WARM_FILELIST_TTL;
    eval { $controller->minion->enqueue( warm_filelist => [$id] => { priority => 0, attempts => 1 } ); };
}

1;
