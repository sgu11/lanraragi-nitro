package LANraragi::Utils::UploadCommit;

use v5.36;
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use LANraragi::Utils::Path qw(rename_path unlink_path);

# The old bytes remain recoverable until the new file AND metadata commit.
# Callers hold the archive-write locks; write/rollback own only DB changes.
sub publish ( $staged, $output, $old_path, $write, $rollback ) {
    my ($backup_dir, $backup, $installed, $writing, $result);
    my $ok = eval {
        if (defined $old_path && -e $old_path) {
            $backup_dir = tempdir('.lrr-upload-XXXXXX', DIR => dirname($old_path), CLEANUP => 0);
            $backup = "$backup_dir/archive";
            rename_path($old_path, $backup) or die "Could not preserve the existing archive: $!\n";
        }
        rename_path($staged, $output) or die "The file couldn't be renamed in your content folder: $!\n";
        $installed = 1;
        die "The published archive is missing\n" unless -e $output;
        $writing = 1;
        $result = $write->();
        1;
    };
    if (!$ok) {
        my $error = $@;
        # Preserve both copies if rollback itself fails. Never delete the backup
        # merely because the request is returning an error.
        my $restored = eval {
            if ($installed && -e $output) {
                rename_path($output, $staged) or die "Could not retain the failed upload: $!\n";
            }
            if (defined $backup && -e $backup) {
                rename_path($backup, $old_path) or die "Could not restore the existing archive: $!\n";
            }
            $rollback->() if $writing;
            1;
        };
        $error .= "Rollback requires recovery: $@" unless $restored;
        if ($restored) {
            unlink_path($staged) if -e $staged;
            rmdir $backup_dir if defined $backup_dir;
        }
        die $error;
    }
    # Commit succeeded. Failed cleanup leaves a recoverable copy, not data loss.
    if (defined $backup && -e $backup) {
        unlink_path($backup);
        rmdir $backup_dir;
    }
    return $result;
}

1;
