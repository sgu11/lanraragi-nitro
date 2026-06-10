package LANraragi::Utils::Minion::Tachiyomi;

use strict;
use warnings;
use utf8;

use LANraragi::Model::Config;
use LANraragi::Utils::Archive qw(get_filelist);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Path    qw(get_archive_path);

# Fork-only Minion tasks supporting Tachiyomi/Mihon-style API clients. Kept
# outside LANraragi::Utils::Minion so upstream merges of that task registry stay
# close to a single add_tasks() hook.

sub add_tasks {
    my $minion = shift;

    $minion->add_task(
        warm_filelist => sub {
            my ( $job, @args ) = @_;
            my ($id) = @args;

            my $logger = get_logger( "Minion", "minion" );
            my $redis  = LANraragi::Model::Config->get_redis;

            if ( $redis->hget( $id, "pagefiles" ) ) {
                $redis->quit;
                $job->finish( { success => 1, cached => 1 } );
                return;
            }

            my $archive = get_archive_path( $redis, $id );
            $redis->quit;

            my @files;
            eval { @files = get_filelist( $archive, $id, 0 ); };
            if ($@) {
                my $msg = "Error warming filelist for $id: $@";
                $logger->debug($msg);
                $job->fail( { error => $msg } );
                return;
            }

            $job->finish( { success => 1, cached => 0, pages => scalar @files } );
        }
    );
}

1;
