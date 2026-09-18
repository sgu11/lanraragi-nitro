use strict;
use warnings;
use utf8;
use Test::More;
use Mojo::JSON qw(encode_json);
use Encode qw(decode_utf8);
use LANraragi::Controller::Batch;
use LANraragi::Model::Plugins;

package BatchTestClient {
    sub finish { my ( $self, @args ) = @_; push @{$self->{finished}}, \@args }
    sub send { my ( $self, $args ) = @_; push @{$self->{sent}}, $args }
}
package BatchTestController {
    sub tx { $_[0]{client} }
    sub LRR_CONF { 'BatchTestConfig' }
    sub inactivity_timeout { 1 }
    sub on { $_[0]{callbacks}{$_[1]} = $_[2] }
}
package BatchTestConfig {
    sub get_redis { bless {}, 'BatchTestRedis' }
}
package BatchTestRedis {
    sub quit { 1 }
    sub hmget { [ 'fixture.cbz', 'Saved title', 'existing:tag', '/tmp/fixture.cbz', 'fixture-thumb' ] }
}
package NamedBatchPlugin {
    our @received;
    sub plugin_info {
        return ( name => 'Named fixture', namespace => 'named_fixture', type => 'metadata',
            parameters => {
                z_mode => { type => 'string', default_value => 'default mode' },
                a_limit => { type => 'int', default_value => 5 },
                m_label => { type => 'string', default_value => 'default label' },
            } );
    }
    sub get_tags {
        my ( $self, $info, $args ) = @_;
        push @received, { %$args };
        return ( tags => 'fixture:named', title => 'Updated title', summary => 'Updated summary' );
    }
}
package BatchTestLogger {
    our @messages;
    sub info { shift; push @messages, @_ }
    sub debug { shift; push @messages, @_ }
    sub trace { shift; push @messages, @_ }
}
package main;
no warnings 'redefine';
my $real_batch_plugin = \&LANraragi::Controller::Batch::batch_plugin;
local *LANraragi::Controller::Batch::get_logger = sub { bless {}, 'BatchTestLogger' };
local *LANraragi::Controller::Batch::get_computed_tagrules = sub { () };
local *LANraragi::Controller::Batch::build_tag_replace_hash = sub { ([], {}) };
local *LANraragi::Controller::Batch::get_plugin = sub { 'SyntheticPlugin' };
local *LANraragi::Controller::Batch::get_plugin_parameters = sub { (customargs => []) };
my @executions;
local *LANraragi::Controller::Batch::batch_plugin = sub {
    my ( $id, $plugin, %args ) = @_;
    push @executions, $args{customargs};
    return { id => $id, success => 1 };
};
my $controller = bless { client => bless({}, 'BatchTestClient') }, 'BatchTestController';
LANraragi::Controller::Batch::socket($controller);
my $id = 'a' x 40;
$controller->{callbacks}{message}->($controller, encode_json({ operation => 'plugin', archive => $id, plugin => 'fixture', args => ['synthetic-credential'] }));
is_deeply($executions[0], ['synthetic-credential'], 'override reaches the requested plugin');
unlike(join(' ', @BatchTestLogger::messages), qr/synthetic-credential/, 'socket logging does not expose override values');
is($controller->{client}{sent}[0]{json}{success}, 1, 'valid request responds normally');
for my $input ('{', '[]', encode_json({ operation => 'plugin', archive => $id, args => {} }), encode_json({ operation => 'delete', archive => '../bad' })) {
    my $ok = eval { $controller->{callbacks}{message}->($controller, $input); 1 };
    ok($ok, 'invalid command does not throw in the event loop');
    is($controller->{client}{finished}[-1][0], 1007, 'invalid command closes with a data error');
}
is(scalar @executions, 1, 'invalid commands execute no plugin');

subtest 'named overrides reach the model in declared parameter order' => sub {
    local *LANraragi::Controller::Batch::get_plugin = sub { 'NamedBatchPlugin' };
    my %saved = ( a_limit => 7, m_label => 'Saved label', z_mode => 'default mode',
        enabled => 0, installed_path => 'LANraragi/Plugin/Metadata/Fixture.pm', type => 'metadata' );
    local *LANraragi::Controller::Batch::get_plugin_parameters = sub { %saved };
    local *LANraragi::Controller::Batch::batch_plugin = $real_batch_plugin;
    local *LANraragi::Model::Plugins::get_logger = sub { bless {}, 'BatchTestLogger' };
    local *LANraragi::Model::Config::get_redis = sub { bless {}, 'BatchTestRedis' };
    local *LANraragi::Model::Config::enable_tagrules = sub { 0 };
    local *LANraragi::Model::Config::can_replacetitles = sub { 1 };
    my %updated;
    local *LANraragi::Controller::Batch::set_tags = sub { $updated{tags} = $_[1] };
    local *LANraragi::Controller::Batch::set_title = sub { $updated{title} = $_[1] };
    local *LANraragi::Controller::Batch::set_summary = sub { $updated{summary} = $_[1] };
    for my $case (
        [ [ 0, '한글 설정', '', 'ignored extra' ], { %saved, a_limit => '0', m_label => '한글 설정', z_mode => '' } ],
        [ [ 0 ], { %saved, a_limit => '0' } ],
        [ [], { %saved } ],
    ) {
        my ( $overrides, $expected ) = @$case;
        my $message = decode_utf8(encode_json({ operation => 'plugin', archive => $id,
            plugin => 'named_fixture', args => $overrides }));
        $controller->{callbacks}{message}->($controller, $message);
        my $response = $controller->{client}{sent}[-1]{json};
        is( $response->{success}, 1, 'actual metadata model consumes named override parameters' );
        is_deeply( $NamedBatchPlugin::received[-1], $expected,
            'declared keys retain zero, Unicode, empty values and saved metadata without customargs' );
    }
    is_deeply( \%updated, { tags => ' fixture:named', title => 'Updated title', summary => 'Updated summary' },
        'successful named execution persists returned archive metadata' );
};
done_testing();
