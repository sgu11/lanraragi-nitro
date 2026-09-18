package LANraragi::Utils::PluginUpload;

use strict;
use warnings;
use Cwd qw(getcwd);
use Fcntl qw(:flock);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use IPC::Cmd qw(run);
use Mojo::JSON qw(decode_json);
use LANraragi::Utils::Generic qw(exec_with_lock_pure);
use LANraragi::Model::Server qw(set_restart_pending);
use LANraragi::Utils::Plugins qw(read_registered_plugins);
use LANraragi::Utils::Registry qw(find_namespace_conflict);

use Exporter 'import';
our @EXPORT_OK = qw(install_sideloaded_plugin);

# Uploaded plugins are executable administrator code. Check them in a fresh
# process so a rejected candidate cannot replace a package loaded by this worker.
sub check_candidate {
    my ( $candidate, $package ) = @_;
    my ( $ok, undef, undef, $stdout ) = run(
        command => [ $^X, getcwd() . '/script/check_plugin_loads.pl', $candidate, $package ],
        timeout => 20,
        verbose => 0,
    );
    return unless $ok;
    my ($json) = join( '', @{ $stdout // [] } ) =~ /^LRR_PLUGIN_INFO (.+)$/m;
    return unless defined $json;
    my $info = eval { decode_json($json) };
    return ref($info) eq 'HASH' ? $info : undef;
}

sub install_sideloaded_plugin {
    my ( $upload, $redis ) = @_;
    return { success => 0, error => 'Please upload a Perl Module (.pm) file.' } unless $upload;
    my $filename = $upload->filename // '';
    my ($stem) = $filename =~ /\A([A-Za-z_][A-Za-z0-9_]*)\.pm\z/;
    return { success => 0, error => 'Use a plugin filename containing only letters, digits and underscores.' } unless $stem;
    return { success => 0, error => 'Plugin files must be at most 1 MiB.' } if $upload->size > 1024 * 1024;

    my $content = $upload->slurp;
    my $package = "LANraragi::Plugin::Sideloaded::$stem";
    my ($declared) = $content =~ /^\s*package\s+(LANraragi::Plugin::[A-Za-z0-9_:]+)\s*;/m;
    return { success => 0, error => 'The plugin must declare its matching Sideloaded package or a legacy plugin type package.' }
      unless defined $declared && ( $declared eq $package
        || $declared =~ /\ALANraragi::Plugin::(?:Login|Metadata|Scripts|Download)::\Q$stem\E\z/ );
    # Preserve legacy upload support while making discovery and worker lookup
    # use the actual installation path. Explicit self-references need the same
    # canonical namespace; never silently rewrite arbitrary executable code.
    if ( $declared ne $package ) {
        $content =~ s/^(\s*package\s+)\Q$declared\E(\s*;)/$1$package$2/m;
        return { success => 0, error => "Use __PACKAGE__ or $package for references to this plugin's package." }
          if $content =~ /\Q$declared\E(?:::|\s*->)/;
    }

    my $dir = getcwd() . '/lib/LANraragi/Plugin/Sideloaded';
    make_path($dir) unless -d $dir;
    my $candidate_fh = File::Temp->new( TEMPLATE => '.upload-XXXXXXXX', DIR => $dir, UNLINK => 1 );
    my $candidate = $candidate_fh->filename;
    binmode $candidate_fh;
    print {$candidate_fh} $content or die "Cannot stage plugin upload: $!\n";
    close $candidate_fh or die "Cannot finish plugin staging: $!\n";
    my $info = check_candidate( $candidate, $package );
    return { success => 0, error => 'The plugin failed its load or metadata contract check. The installed plugin was preserved.' } unless $info;

    # A stable filesystem lock has no expiring lease and covers all sideloaded
    # namespaces sharing this directory. Keep the inode after releasing it.
    open my $lock, '>>', "$dir/.upload.lock" or die "Cannot open plugin upload lock: $!\n";
    return { success => 0, error => 'Another plugin upload is completing. Try again.' }
      unless flock( $lock, LOCK_EX | LOCK_NB );
    my ( $acquired, $result ) = exec_with_lock_pure(
        [ 'plugin-write:' . uc($info->{namespace}) ],
        sub { return commit_candidate( $dir, $filename, $candidate, $info, $redis ); },
        $redis,
    );
    return $acquired ? $result : { success => 0, error => 'Another operation is updating this plugin. Try again.' };
}

sub commit_candidate {
    my ( $dir, $filename, $candidate, $info, $redis ) = @_;
    my $target = "$dir/$filename";
    my $relative = "LANraragi/Plugin/Sideloaded/$filename";
    return { success => 0, error => 'The installed plugin is a symbolic link. Its owner must update the linked file.' }
      if -l $target;
    my $key = 'LRR_PLUGIN_' . uc($info->{namespace});
    my $old_path = $redis->hget( $key, 'installed_path' );
    my $old_type = $redis->hget( $key, 'type' );
    return { success => 0, error => 'That namespace belongs to another installed plugin.' }
      if defined $old_path && $old_path ne $relative;
    my %registered = read_registered_plugins($redis);
    for my $namespace ( keys %registered ) {
        return { success => 0, error => 'That filename belongs to another installed namespace.' }
          if $registered{$namespace} eq $relative && uc($namespace) ne uc($info->{namespace});
    }
    return { success => 0, error => 'An unregistered plugin already occupies that filename. The existing file was preserved.' }
      if -e $target && !defined $old_path;
    return { success => 0, error => 'That namespace already exists in another plugin file.' }
      if find_namespace_conflict( $info->{namespace}, $target );

    my ( $backup_fh, $backup );
    if ( -e $target ) {
        ( $backup_fh, $backup ) = tempfile( '.rollback-XXXXXXXX', DIR => $dir, UNLINK => 0 );
        close $backup_fh;
        copy( $target, $backup ) or die "Cannot back up installed plugin: $!\n";
        chmod( (stat($target))[2] & oct('777'), $backup ) or die "Cannot preserve plugin mode: $!\n";
    }
    chmod 0644, $candidate or die "Cannot set plugin mode: $!\n";
    rename( $candidate, $target ) or die "Cannot publish plugin upload: $!\n";
    my $registered = eval {
        $redis->hset( $key, installed_path => $relative, type => $info->{type} );
        set_restart_pending($redis) if defined $old_path;
        1;
    };
    unless ($registered) {
        my $restored = $backup ? rename( $backup, $target ) : unlink($target);
        my $registry_restored = eval {
            for my $entry ( [ installed_path => $old_path ], [ type => $old_type ] ) {
                defined $entry->[1] ? $redis->hset( $key, @$entry ) : $redis->hdel( $key, $entry->[0] );
            }
            1;
        };
        return { success => 0, recovery_required => 1,
            error => 'Plugin registration failed and rollback was incomplete. Preserve the Sideloaded directory and its rollback file for recovery.' }
          unless $restored && $registry_restored;
        return { success => 0, error => 'Plugin registration failed. The previous plugin and settings were restored.' };
    }
    unlink $backup if defined $backup && -e $backup;
    return { success => 1, name => $info->{name}, restart_required => defined $old_path ? 1 : 0 };
}

1;
