package LANraragi::Utils::Tachiyomi;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(is_tachiyomi_client tachiyomi_cache_identity);

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

1;
