package LANraragi::Controller::Plugins;
use Mojo::Base 'Mojolicious::Controller';

use v5.36;
use experimental 'try';

use Redis;
use Encode;
use Mojo::JSON qw(encode_json);
use LANraragi::Utils::PluginUpload qw(install_sideloaded_plugin);

use LANraragi::Utils::Generic qw(generate_themes_header);
use LANraragi::Utils::Plugins qw(get_plugins get_plugin_parameters is_plugin_enabled);
use LANraragi::Utils::Logging qw(get_logger);

# This action will render a template
sub index {

    my $self = shift;

    # Build plugin lists, array of hashes
    my @metaplugins     = get_plugins("metadata");
    my @loginplugins    = get_plugins("login");
    my @scriptplugins   = get_plugins("script");
    my @downloadplugins = get_plugins("download");

    $self->render(
        template      => "plugins",
        title         => $self->LRR_CONF->get_htmltitle,
        descstr       => $self->LRR_DESC,
        replacetitles => $self->LRR_CONF->can_replacetitles,
        metadata      => craft_plugin_array(@metaplugins),
        downloaders   => craft_plugin_array(@downloadplugins),
        logins        => craft_plugin_array(@loginplugins),
        scripts       => craft_plugin_array(@scriptplugins),
        csshead       => generate_themes_header($self),
        version       => $self->LRR_VERSION
    );

}

sub craft_plugin_array {

    my @pluginarray = ();
    foreach my $pluginfo (@_) {
        my $namespace  = $pluginfo->{namespace};
        my %paramsconf = get_plugin_parameters($namespace);

        if ( $pluginfo->{type} ne "login" ) {

            # Add whether the plugin is enabled to the hash directly
            $pluginfo->{enabled} = is_plugin_enabled($namespace);
        }

        # Add redis values to the members of the parameters array
        my @paramhashes = ();

        # For backwards compatibility, we can return either an array or a hash for plugin parameters
        if ( ref( $pluginfo->{parameters} ) eq 'ARRAY' ) {
            my $counter     = 0;
            my @redisparams = @{ $paramsconf{'customargs'} };
            foreach my $param ( @{ $pluginfo->{parameters} } ) {
                $param->{value} = $redisparams[$counter];
                push @paramhashes, $param;
                $counter++;
            }
        } elsif ( ref( $pluginfo->{parameters} ) eq 'HASH' ) {
            foreach my $key ( sort keys %{ $pluginfo->{parameters} } ) {
                my $param = $pluginfo->{parameters}{$key};
                $param->{name}  = $key;
                $param->{value} = $paramsconf{$key};
                push @paramhashes, $param;
            }
        }

        #Add the parameter hashes to the plugin info for the template to parse
        $pluginfo->{parameters} = \@paramhashes;

        push @pluginarray, $pluginfo;
    }

    return \@pluginarray;
}

sub save_config {

    my $self     = shift;
    my $redis    = $self->LRR_CONF->get_redis_config;
    my %response = ( operation => 'plugins', success => 1, message => '' );

    # Update settings for every plugin.
    my @plugins = get_plugins("all");

    #Plugin list is an array of hashes
    my @pluginlist = ();

    no warnings 'experimental::try';
    try {

        # Save title preference first
        my $replacetitles = ( scalar $self->req->param('replacetitles') ? '1' : '0' );
        $redis->hset( "LRR_CONFIG", "replacetitles", $replacetitles );
        LANraragi::Model::Config::invalidate_config_cache();

        # Save each plugin's settings
        foreach my $pluginfo (@plugins) {
            my $namespace = $pluginfo->{namespace};
            my $namerds   = "LRR_PLUGIN_" . uc($namespace);

            # Get whether the plugin is enabled for auto-plugin or not
            my $enabled = ( scalar $self->req->param($namespace) ? '1' : '0' );

            if ( ref( $pluginfo->{parameters} ) eq 'ARRAY' ) {

                #Get expected number of custom arguments from the plugin itself
                my $argcount = scalar @{ $pluginfo->{parameters} };

                my @customargs = ();

                #Loop through the namespaced request parameters
                #Start at 1 because that's where TT2's loop.count starts
                for ( my $i = 1; $i <= $argcount; $i++ ) {
                    my $param = $namespace . "_CFG_" . $i;

                    my $value = $self->req->param($param);

                    # Check if the parameter exists in the request
                    if (defined $value) {
                        push( @customargs, $value );
                    } else {

                        # Checkboxes don't exist in the parameter list if they're not checked.
                        push( @customargs, "" );
                    }

                }

                my $encodedargs = encode_json( \@customargs );

                $redis->hset( $namerds, "enabled",    $enabled );
                $redis->hset( $namerds, "customargs", $encodedargs );

            } elsif ( ref( $pluginfo->{parameters} ) eq 'HASH' ) {

                # TODO: del nukes plugin on config save, hence commented out
                # # TODO: remove this line (and the ARRAY check above)
                # # after plugins with array parameters are deprecated
                # $redis->del($namerds);

                #Loop through the namespaced request parameters
                foreach my $key ( keys %{ $pluginfo->{parameters} } ) {

                    my $value = $self->req->param("${namespace}_CFG_${key}");

                    # Checkboxes don't exist in the parameter list if they're not checked.
                    $redis->hset( $namerds, $key, $value // "" );
                }

                $redis->hset( $namerds, "enabled", $enabled );

            }

        }
    } catch ($e) {
        $response{success} = 0;
        $response{message} = $e;
    }

    $redis->quit();
    $self->render( json => \%response );
}

sub process_upload {
    my $self = shift;
    my $redis = $self->LRR_CONF->get_redis_config;
    my $result = eval { install_sideloaded_plugin( $self->req->upload('file'), $redis ) };
    unless ($result) {
        get_logger( "Plugin Upload", "lanraragi" )->error('Plugin upload failed during staging or commit.');
        $result = { success => 0, error => 'Plugin upload failed during staging or commit. Check storage and database availability.' };
    }
    $redis->quit();
    $result->{operation} = 'upload_plugin';
    $self->render( json => $result );
}

1;
