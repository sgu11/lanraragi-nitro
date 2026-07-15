use strict;
use warnings;
use utf8;

use Test::More;
use Test::Deep;
use Mojo::Path;

BEGIN { use_ok('LANraragi::Utils::Routing'); }

note('cover review export is registered only on the authenticated API router');
{
    open my $fh, '<', 'lib/LANraragi/Utils/Routing.pm' or die $!;
    local $/;
    my $source = <$fh>;
    close $fh;
    my $route = q{$logged_in_api->get('/api/duplicates/cover/review-events')};
    my $route_count = () = $source =~ /\Q$route\E/g;
    is( $route_count, 1, 'review export has one authenticated route' );
    unlike( $source, qr/\$api->get\('\/api\/duplicates\/cover\/review-events'/, 'no unauthenticated explicit route remains' );
}

use Cwd qw(getcwd);

my $cwd = getcwd();
my $jsdir = $cwd."/tests/samples/routing/js";

note('testing is_path_within ...');
{
    my $result = LANraragi::Utils::Routing::is_path_within("$jsdir/safe/ok2.txt", $jsdir);
    is( $result, 1, "Simple safe path should pass" );
}

{
    my $result = LANraragi::Utils::Routing::is_path_within("$jsdir/safe/../ok.txt", $jsdir."/safe/../");
    is( $result, 1, "Traversal within directory to test against should pass" );
}

{
    my $result = LANraragi::Utils::Routing::is_path_within("$jsdir/safe/../ok.txt", $jsdir);
    is( $result, 1, "Traversal within directory should pass" );
}

{
    my $result = LANraragi::Utils::Routing::is_path_within("$jsdir/../robots.txt", $jsdir);
    is( $result, 0, "Path traversing past root should be blocked" );
}

{
    my $result = LANraragi::Utils::Routing::is_path_within("/../absolute", $jsdir);
    is( $result, 0, "Path with leading parent traversal should be blocked" );
}

done_testing();
