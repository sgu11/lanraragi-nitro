use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojolicious;
use LANraragi::Controller::Plugins;

package SettingsTestRedis {
    sub new { bless { hashes => {} }, shift }
    sub hset {
        my ( $self, $key, @pairs ) = @_;
        while (@pairs) {
            my $field = shift @pairs;
            $self->{hashes}{$key}{$field} = shift @pairs;
        }
        return 1;
    }
    sub quit { 1 }
}
package SettingsTestConfig {
    our $redis;
    sub get_redis_config { $redis }
}
package main;
my $redis = SettingsTestRedis->new;
$SettingsTestConfig::redis = $redis;
my $app = Mojolicious->new;
$app->routes->namespaces(['LANraragi::Controller']);
$app->helper(LRR_CONF => sub { 'SettingsTestConfig' });
$app->routes->post('/save')->to('plugins#save_config');
no warnings 'redefine';
local *LANraragi::Controller::Plugins::get_plugins = sub {
    return (
        { namespace => 'old', parameters => [{}, {}] },
        { namespace => 'named', parameters => { limit => {}, checkbox => {} } },
    );
};
local *LANraragi::Model::Config::invalidate_config_cache = sub {};
my $test = Test::Mojo->new($app);
$test->post_ok('/save' => form => { old_CFG_1 => '0', named_CFG_limit => '0' })
    ->status_is(200)->json_is('/success', 1);
is($redis->{hashes}{LRR_PLUGIN_OLD}{customargs}, '["0",""]', 'legacy zero retained and absent checkbox cleared');
is($redis->{hashes}{LRR_PLUGIN_NAMED}{limit}, '0', 'named zero retained');
is($redis->{hashes}{LRR_PLUGIN_NAMED}{checkbox}, '', 'absent named checkbox cleared');
$test->post_ok('/save' => form => { old_CFG_1 => '', named_CFG_limit => '' })->json_is('/success', 1);
is($redis->{hashes}{LRR_PLUGIN_OLD}{customargs}, '["",""]', 'explicit empty legacy value retained');
is($redis->{hashes}{LRR_PLUGIN_NAMED}{limit}, '', 'explicit empty named value retained');
done_testing();
