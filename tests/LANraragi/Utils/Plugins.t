use strict;
use warnings;
use utf8;

use Test::More;

use LANraragi::Model::Config ();
use LANraragi::Utils::Plugins qw(get_plugin);

package FakePluginRegistryRedis {
    sub new {
        return bless { hashes => {}, quit_count => 0 }, shift;
    }

    sub hexists {
        my ( $self, $key, $field ) = @_;
        return exists $self->{hashes}{$key}{$field};
    }

    sub hget {
        my ( $self, $key, $field ) = @_;
        return $self->{hashes}{$key}{$field};
    }

    sub hgetall { my ($self, $key) = @_; return %{ $self->{hashes}{$key} // {} }; }

    sub quit {
        my ($self) = @_;
        $self->{quit_count}++;
        return 1;
    }
}

package main;

note('get_plugin follows Redis installed_path state on every lookup');
{
    my $redis = FakePluginRegistryRedis->new;
    $redis->{hashes}{LRR_PLUGIN_DYNAMIC}{installed_path} = 'LANraragi/Utils/Path.pm';

    no warnings 'redefine';
    local *LANraragi::Model::Config::get_redis_config = sub { return $redis };
    local *LANraragi::Utils::Plugins::get_logger = sub { return bless {}, 'FakePluginLogger' };

    is( get_plugin('dynamic'), 'LANraragi::Utils::Path', 'registered plugin path resolves to a package' );
    delete $redis->{hashes}{LRR_PLUGIN_DYNAMIC}{installed_path};
    is( get_plugin('dynamic'), 0, 'removed installed_path immediately makes the plugin unavailable' );
    is( $redis->{quit_count}, 2, 'each lookup uses and closes the current registry handle' );
}

package FakePluginLogger {
    sub warn { 1 }
}

package main;


{
    package MigratingPlugin;
    sub plugin_info { return (name => 'Fixture', parameters => { token => { default_value => '' } }); }
    package CapturePluginLogger;
    our @messages;
    sub warn { shift; push @messages, @_ }
    package main;
    my $redis = FakePluginRegistryRedis->new;
    $redis->{hashes}{LRR_PLUGIN_MIGRATING}{customargs} = '["synthetic-secret-marker"]';
    no warnings 'redefine';
    local *LANraragi::Model::Config::get_redis_config = sub { $redis };
    local *LANraragi::Utils::Plugins::get_plugin = sub { 'MigratingPlugin' };
    local *LANraragi::Utils::Plugins::get_logger = sub { bless {}, 'CapturePluginLogger' };
    my %params = LANraragi::Utils::Plugins::get_plugin_parameters('migrating');
    ok(@CapturePluginLogger::messages, 'unmappable legacy settings still produce an operator warning');
    unlike(join(' ', @CapturePluginLogger::messages), qr/synthetic-secret-marker/, 'warning does not contain parameter values');
    is($params{customargs}, '["synthetic-secret-marker"]', 'warning does not destroy existing settings');
}

done_testing();
