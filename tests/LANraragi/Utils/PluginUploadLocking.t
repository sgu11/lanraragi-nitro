use v5.36;
use strict;
use warnings;
use Cwd qw(getcwd);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Mojo::File qw(path);
use Mojo::Upload;
use Mojo::Asset::Memory;
use Test::More;
use Test::MockModule qw(strict);
use LANraragi::Utils::PluginUpload qw(install_sideloaded_plugin);
use LANraragi::Utils::Generic qw(exec_with_lock_pure);
use LANraragi::Model::Plugins;
require './tests/redis_test_server.pl';
my ($redis, $guard) = start_test_redis();
my $cwd = getcwd();
my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/script", "$tmp/lib/LANraragi/Plugin/Sideloaded");
path("$tmp/script/check_plugin_loads.pl")->spew(path("$cwd/script/check_plugin_loads.pl")->slurp);
local $ENV{PERL5LIB} = join ':', "$cwd/lib", ($ENV{PERL5LIB} // '');
local @INC = ("$tmp/lib", "$cwd/lib", @INC);
chdir $tmp or die $!;
my $target = "$tmp/lib/LANraragi/Plugin/Sideloaded/LockFixture.pm";
my $namespace = 'locking_fixture';
my $key = 'LRR_PLUGIN_' . uc($namespace);
my $lock_key = 'plugin-write:' . uc($namespace);
{
    package PluginLockLogger;
    sub info { 1 }
    sub warn { 1 }
    sub error { 1 }
}
my $model = Test::MockModule->new('LANraragi::Model::Plugins');
$model->redefine(get_logger => sub { bless {}, 'PluginLockLogger' });
sub upload {
    my ($name) = @_;
    my $content = "package LANraragi::Plugin::Metadata::LockFixture; use strict; use warnings; sub plugin_info { return (name => '$name', namespace => 'locking_fixture', type => 'metadata', parameters => {}); } sub get_tags { return (tags => 'synthetic'); } 1;\n";
    return Mojo::Upload->new(filename => 'LockFixture.pm', asset => Mojo::Asset::Memory->new->add_chunk($content));
}
ok(install_sideloaded_plugin(upload('original'), $redis)->{success}, 'initial sideloaded plugin installs');
$redis->hset($key, enabled => 1, setting => 'synthetic-only');
my $unregister = LANraragi::Model::Plugins->can('unregister_plugin');
my $overlap;
$model->redefine(unregister_plugin => sub {
    # This is the real uninstall's critical gap: old file removed, registration
    # still present. Its namespace Redis lease is held throughout the callback.
    ok(!-e $target, 'uninstall has removed old file before interleaving');
    ok(defined $redis->hget($key, 'installed_path'), 'old registration still exists at interleaving');
    ok($redis->exists($lock_key), 'actual namespace lease is held by uninstall');
    my $upload_redis = Redis->new(sock => "$guard->{dir}/redis.sock");
    $overlap = install_sideloaded_plugin(upload('replacement'), $upload_redis);
    $upload_redis->quit;
    ok(!$overlap->{success}, 'upload overlapping locked uninstall is rejected');
    return $unregister->(@_);
});
my ($acquired, $status) = exec_with_lock_pure([$lock_key], sub {
    my ($code) = LANraragi::Model::Plugins::uninstall_plugin($namespace, $redis);
    return $code;
}, $redis, 300);
ok($acquired, 'uninstall acquired shared plugin-write namespace lock');
is($status, 200, 'uninstall completes successfully');
ok(!-e $target, 'rejected upload leaves no orphan replacement file');
ok(!defined $redis->hget($key, 'installed_path'), 'uninstall removes registration');
is($redis->hget($key, 'setting'), 'synthetic-only', 'user settings survive successful uninstall');
ok(!$redis->exists($lock_key), 'namespace lease releases after uninstall');
my @residue = glob("$tmp/lib/LANraragi/Plugin/Sideloaded/.upload-* $tmp/lib/LANraragi/Plugin/Sideloaded/.rollback-*");
is(scalar @residue, 0, 'rejected overlap cleans its staged candidate');
my $retry = install_sideloaded_plugin(upload('after uninstall'), $redis);
ok($retry->{success}, 'upload succeeds after namespace lock releases');
ok(-f $target, 'retry publishes its new artifact');
is($redis->hget($key, 'installed_path'), 'LANraragi/Plugin/Sideloaded/LockFixture.pm', 'retry registers its artifact');
chdir $cwd or die $!;
done_testing();
