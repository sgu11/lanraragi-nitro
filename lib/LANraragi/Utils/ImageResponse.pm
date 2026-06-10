package LANraragi::Utils::ImageResponse;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(render_thumbnail_placeholder);

sub render_thumbnail_placeholder {
    my ($controller) = @_;

    $controller->res->headers->cache_control('public, max-age=86400');
    $controller->render_file(
        filepath            => "./public/img/noThumb.png",
        content_disposition => "inline",
        content_type        => "image/png"
    );
}

1;
