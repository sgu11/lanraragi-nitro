use strict;
use warnings;
use Cwd qw(getcwd);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Fcntl qw(:flock);
use Mojo::File qw(path);
use Mojo::Upload;
use Mojo::Asset::Memory;
use Test::More;
use LANraragi::Utils::PluginUpload qw(install_sideloaded_plugin);
use LANraragi::Utils::Plugins qw(get_plugin);

package UploadTestRedis {
    sub new { bless { hashes => {} }, shift }
    sub hget { $_[0]{hashes}{$_[1]}{$_[2]} }
    sub hexists { exists $_[0]{hashes}{$_[1]}{$_[2]} }
    sub keys { keys %{$_[0]{hashes}} }
    sub hset {
        my ( $self, $key, @pairs ) = @_;
        die "synthetic Redis write failure\n" if delete $self->{fail_next_write};
        while (@pairs) { my $field = shift @pairs; $self->{hashes}{$key}{$field} = shift @pairs; }
        return 1;
    }
    sub hdel { delete $_[0]{hashes}{$_[1]}{$_[2]}; 1 }
    sub set {
        my ( $self, $key, $value ) = @_;
        return if exists $self->{locks}{$key};
        $self->{locks}{$key} = $value;
        return 'OK';
    }
    sub eval {
        my ( $self, $script, $count, $key, $value ) = @_;
        return 0 unless ($self->{locks}{$key} // '') eq $value;
        delete $self->{locks}{$key};
        return 1;
    }
    sub quit { 1 }
}
package main;
my $cwd = getcwd();
my $tmp = tempdir( CLEANUP => 1 );
make_path("$tmp/script", "$tmp/lib/LANraragi/Plugin/Sideloaded");
path("$tmp/script/check_plugin_loads.pl")->spew(path("$cwd/script/check_plugin_loads.pl")->slurp);
local $ENV{PERL5LIB} = join ':', "$cwd/lib", ($ENV{PERL5LIB} // '');
local @INC = ("$tmp/lib", "$cwd/lib", @INC);
chdir $tmp or die $!;
my $redis = UploadTestRedis->new;
my $target = "$tmp/lib/LANraragi/Plugin/Sideloaded/Fixture.pm";
my $key = 'LRR_PLUGIN_UPLOAD_FIXTURE';

sub upload {
    my ( $filename, $content ) = @_;
    return Mojo::Upload->new(filename => $filename, asset => Mojo::Asset::Memory->new->add_chunk($content));
}
sub source {
    my ($name) = @_;
    return "package LANraragi::Plugin::Metadata::Fixture; use strict; use warnings; sub plugin_info { return (name => '$name', namespace => 'upload_fixture', type => 'metadata', parameters => {}); } sub get_tags { return (tags => 'fixture'); } 1;\n";
}

ok(!install_sideloaded_plugin(undef, $redis)->{success}, 'missing file is rejected');
for my $filename ('../Fixture.pm', 'sub/Fixture.pm', 'Fixture.pm.php', 'Fixture.pm\0') {
    ok(!install_sideloaded_plugin(upload($filename, source('one')), $redis)->{success}, 'unsafe filename rejected');
}
my $result = install_sideloaded_plugin(upload('Fixture.pm', source('one')), $redis);
ok($result->{success}, 'valid legacy plugin is installed');
is($redis->hget($key, 'installed_path'), 'LANraragi/Plugin/Sideloaded/Fixture.pm', 'path registered immediately');
is($redis->hget($key, 'type'), 'metadata', 'type registered');
like(path($target)->slurp, qr/package LANraragi::Plugin::Sideloaded::Fixture;/, 'package matches installed path');
{
    no warnings 'redefine';
    local *LANraragi::Model::Config::get_redis_config = sub { $redis };
    is(get_plugin('upload_fixture'), 'LANraragi::Plugin::Sideloaded::Fixture', 'normal worker lookup loads the new plugin');
}
my $original = path($target)->slurp;
$redis->hset($key, enabled => '1', secret_setting => 'synthetic-only');
$result = install_sideloaded_plugin(upload('Fixture.pm', source('broken') . 'invalid syntax here'), $redis);
ok(!$result->{success}, 'syntax failure rejected');
is(path($target)->slurp, $original, 'syntax failure preserves old artifact');
is($redis->hget($key, 'secret_setting'), 'synthetic-only', 'existing configuration preserved');
my $missing_method = source('bad method'); $missing_method =~ s/sub get_tags/sub other_method/;
ok(!install_sideloaded_plugin(upload('Fixture.pm', $missing_method), $redis)->{success}, 'required method validated before replacement');
is(path($target)->slurp, $original, 'contract failure preserves old artifact');

$redis->{fail_next_write} = 1;
$result = install_sideloaded_plugin(upload('Fixture.pm', source('two')), $redis);
ok(!$result->{success}, 'registration failure reported');
is(path($target)->slurp, $original, 'registration failure restores old artifact');
is($redis->hget($key, 'installed_path'), 'LANraragi/Plugin/Sideloaded/Fixture.pm', 'registration restored');
$result = install_sideloaded_plugin(upload('Fixture.pm', source('two')), $redis);
ok($result->{success}, 'valid replacement succeeds');
ok($result->{restart_required}, 'replacement signals cached worker packages need restart');
is($redis->hget('LRR_SERVER', 'restart_pending'), 1, 'restart state persisted');

my $other_namespace = source('other'); $other_namespace =~ s/upload_fixture/other_namespace/g;
ok(!install_sideloaded_plugin(upload('Fixture.pm', $other_namespace), $redis)->{success}, 'same filename cannot replace another namespace');
my $other_name = source('other'); $other_name =~ s/::Fixture/::Other/g;
ok(!install_sideloaded_plugin(upload('Other.pm', $other_name), $redis)->{success}, 'same namespace cannot move to another filename');
{
    open my $lock, '>>', "$tmp/lib/LANraragi/Plugin/Sideloaded/.upload.lock" or die $!;
    flock($lock, LOCK_EX | LOCK_NB) or die $!;
    ok(!install_sideloaded_plugin(upload('Fixture.pm', source('three')), $redis)->{success}, 'concurrent commit rejected without touching the installed file');
}
my @residue = glob("$tmp/lib/LANraragi/Plugin/Sideloaded/.upload-* $tmp/lib/LANraragi/Plugin/Sideloaded/.rollback-*");
is(scalar @residue, 0, 'candidate and successful rollback temporary files cleaned up');
chdir $cwd or die $!;
done_testing();
