package LANraragi::Model::Config;

use strict;
use warnings;
use feature 'state';
use utf8;
use Cwd 'abs_path';
use URI::Escape;

use Mojo::Util qw(xml_escape);
use Minion;
use Mojolicious;
use Mojolicious::Plugin::Config;
use Mojo::Home;
use Mojo::JSON qw(decode_json);
use MIME::Base64 qw(encode_base64);
use Authen::Passphrase;

# Be very careful about importing LANraragi stuff; this file is used almost everywhere and it's easy to introduce dependency cycles!
use LANraragi::Utils::Redis qw(redis_decode);

# Find the project root directory to load the conf file
my $home = Mojo::Home->new;
$home->detect;

my $config = Mojolicious::Plugin::Config->register( Mojolicious->new, { file => $home . '/lrr.conf' } );
if ( $ENV{LRR_REDIS_ADDRESS} ) {
    $config->{redis_address} = $ENV{LRR_REDIS_ADDRESS};
}

{
    package LANraragi::Model::Config::RedisHandle;

    use strict;
    use warnings;

    our $AUTOLOAD;

    sub new {
        my ( $class, $redis, $db, $pid ) = @_;
        return bless { redis => $redis, db => $db, pid => $pid }, $class;
    }

    sub _lrr_redis_handle { return shift->{redis} }
    sub _lrr_redis_pid    { return shift->{pid} }

    sub _lrr_close {
        my ($self) = @_;
        return $self->{redis}->quit();
    }

    # Shared handles are owned by Config.pm. Existing callers still call quit()
    # in many places; keeping this as a no-op preserves those call sites while
    # letting the per-process handle stay warm until reset_redis_handles().
    sub quit { return 1 }

    sub AUTOLOAD {
        my $self = shift;
        ( my $method = $AUTOLOAD ) =~ s/^.*:://;
        return if $method eq 'DESTROY';
        return $self->{redis}->$method(@_);
    }

    sub DESTROY { }
}

# Address and port of your redis instance.
sub get_redisad { return $config->{redis_address} }

# Optional password of your redis instance.
sub get_redispassword { return $config->{redis_password} }

# LANraragi uses 4 Redis Databases. Redis databases are numbered, default is 0.

# Database used for archive data and tag indexes
sub get_archivedb { return $config->{redis_database} }

# Database used by Minion
sub get_miniondb { return $config->{redis_database_minion} }

# Database used to store config keys
sub get_configdb { return $config->{redis_database_config} }

# Database used to store search index and cache
sub get_searchdb { return $config->{redis_database_search} }

# Database used to store metrics
sub get_metricsdb { return $config->{redis_database_metrics} }

# Base URL for deployment under a path prefix
sub get_baseurl { return "$config->{base_url_path}" }

# Create a Minion object connected to the Minion database.
sub get_minion {
    my $redisad = get_redisad;

    # URL encode the unix socket path so it can be recognized as the host
    if ( $redisad =~ m{^/} ) { $redisad = uri_escape($redisad); }

    my $miniondb = $redisad . "/" . get_miniondb;
    my $password = get_redispassword;

    # If the password is non-empty, add the required delimiters
    if ($password) { $password = "x:" . $password . "@"; }

    return Minion->new( Redis => "redis://$password$miniondb" );
}

sub get_redis {
    return get_redis_internal(&get_archivedb);
}

sub get_redis_config {
    return get_redis_internal(&get_configdb);
}

sub get_redis_search {
    return get_redis_internal(&get_searchdb);
}

sub get_redis_metrics {
    return get_redis_internal(&get_metricsdb);
}

my %REDIS_HANDLES;

sub reset_redis_handles {
    foreach my $handle ( values %REDIS_HANDLES ) {
        next unless $handle->_lrr_redis_pid == $$;
        eval { $handle->_lrr_close(); 1 };
    }
    %REDIS_HANDLES = ();
    return 1;
}

sub get_redis_internal {

    my $db      = $_[0];
    my $handle  = $REDIS_HANDLES{$db};

    if ($handle) {
        return $handle if $handle->_lrr_redis_pid == $$;

        # Fork safety: child processes inherit the Perl hash and the parent's
        # file descriptor, but must not reuse or QUIT the parent's socket.
        delete $REDIS_HANDLES{$db};
    }

    my $redisad = &get_redisad;

    # Default redis server location is localhost:6379.
    # Auto-reconnect on, one attempt every 2ms up to 3 seconds. Die after that.
    # Auth if password is set
    my $redis = Redis->new(
        ( $redisad =~ m{^/} ? ( sock => $redisad ) : ( server => $redisad ) ),
        debug     => $ENV{LRR_DEVSERVER} ? "1" : "0",
        reconnect => 3,
        &get_redispassword ? ( password => &get_redispassword ) : ()
    );

    # Switch to specced database
    $redis->select($db);

    $REDIS_HANDLES{$db} = LANraragi::Model::Config::RedisHandle->new( $redis, $db, $$ );
    return $REDIS_HANDLES{$db};
}

#get_redis_conf(parameter, default)
#Gets a parameter from the Redis database. If it doesn't exist, we return the default given as a second parameter.
#
# Values are cached per-worker with a 30s TTL. `get_redis_config` returns the
# process-local shared handle, so cache misses still avoid Redis connection
# setup after the first config DB access in that worker.
# Worker config writes (see Controller/Config.pm) explicitly call invalidate_config_cache();
# other workers pick up changes within 30s via TTL expiry.
my %CONFIG_CACHE;

sub get_redis_conf {
    my ( $param, $default ) = @_;
    my $now = time;

    if ( my $entry = $CONFIG_CACHE{$param} ) {
        return $entry->{value} if $entry->{expiry} > $now;
    }

    my $redis = get_redis_config();
    my $result = $default;

    if ( $redis->hexists( "LRR_CONFIG", $param ) ) {
        my $value = redis_decode( $redis->hget( "LRR_CONFIG", $param ) );

        # Failsafe against blank config values
        $result = $value unless $value =~ /^\s*$/;
    }
    $redis->quit();

    $CONFIG_CACHE{$param} = { value => $result, expiry => $now + 30 };
    return $result;
}

# Clear the per-worker config cache. Call after writing to LRR_CONFIG so the same worker
# sees fresh values immediately; other workers refresh on their next TTL expiry (<= 30s).
sub invalidate_config_cache {
    %CONFIG_CACHE = ();
}

# Functions that return the config variables stored in Redis, or default values if they don't exist.
# Descriptions for each one of these can be found in the web configuration page.
sub get_userdir {

    # Content path can be overriden by LRR_DATA_DIRECTORY
    my $dir = &get_redis_conf( "dirname", "./content" );

    if ( $ENV{LRR_DATA_DIRECTORY} ) {
        $dir = $ENV{LRR_DATA_DIRECTORY};
    }

    # Try to create userdir if it doesn't already exist
    unless ( -e $dir ) {
        mkdir $dir;
    }

    # Return full path if it's relative, using the /lanraragi directory as a base
    return abs_path($dir);
}

sub get_thumbdir {

    # Content path can be overriden by LRR_THUMB_DIRECTORY
    my $dir = &get_redis_conf( "thumbdir", "./thumb" );

    if ( $ENV{LRR_THUMB_DIRECTORY} ) {
        $dir = $ENV{LRR_THUMB_DIRECTORY};
    }

    # Try to create userdir if it doesn't already exist
    unless ( -e $dir ) {
        mkdir $dir;
    }

    #Return full path if it's relative, using the /lanraragi directory as a base
    return abs_path($dir);
}

sub enable_devmode {

    if ( $ENV{LRR_FORCE_DEBUG} ) {
        return 1;
    }

    return &get_redis_conf( "devmode", "0" );
}

sub get_password {

    #bcrypt hash for "kamimamita"
    return &get_redis_conf( "password", '{CRYPT}$2a$08$4AcMwwkGXnWtFTOLuw/hduQlRdqWQIBzX3UuKn.M1qTFX5R4CALxy' );
}

sub get_tagrules {
    return &get_redis_conf( "tagrules",
        "-already uploaded;-forbidden content;-incomplete;-ongoing;-complete;-various;-digital;-translated;-russian;-chinese;-portuguese;-french;-spanish;-italian;-vietnamese;-german;-indonesian"
    );
}

sub get_disable_openapi {

    # LRR_DISABLE_OPENAPI env var overrides the Redis config.
    if ( $ENV{LRR_DISABLE_OPENAPI} ) {
        return 1;
    }

    return &get_redis_conf( "disableopenapi", "1" );
}

sub get_htmltitle        { return xml_escape( &get_redis_conf( "htmltitle", "LANraragi" ) ) }
sub get_motd             { return xml_escape( &get_redis_conf( "motd",      "Welcome to this Library running LANraragi!" ) ) }
sub get_tempmaxsize      { return &get_redis_conf( "tempmaxsize",     "500" ) }
sub get_pagesize         { return &get_redis_conf( "pagesize",        "30" ) }
sub enable_pass          { return &get_redis_conf( "enablepass",      "1" ) }
sub enable_nofun         { return &get_redis_conf( "nofunmode",       "0" ) }
sub enable_cors          { return &get_redis_conf( "enablecors",      "0" ) }
sub enable_metrics       { return &get_redis_conf( "enablemetrics",   "0" ) }
sub get_apikey           { return &get_redis_conf( "apikey",          "" ) }
sub enable_localprogress { return &get_redis_conf( "localprogress",   "0" ) }
sub enable_authprogress  { return &get_redis_conf( "authprogress",    "0" ) }
sub enable_tagrules      { return &get_redis_conf( "tagruleson",      "1" ) }
sub enable_resize        { return &get_redis_conf( "enableresize",    "0" ) }
sub get_threshold        { return &get_redis_conf( "sizethreshold",   "1000" ) }
sub get_readquality      { return &get_redis_conf( "readerquality",   "50" ) }
sub get_style            { return &get_redis_conf( "theme",           "modern.css" ) }
sub enable_dateadded     { return &get_redis_conf( "usedateadded",    "1" ) }
sub use_lastmodified     { return &get_redis_conf( "usedatemodified", "0" ) }
sub enable_cryptofs      { return &get_redis_conf( "enablecryptofs",  "0" ) }
sub get_hqthumbpages     { return &get_redis_conf( "hqthumbpages",    "0" ) }
sub get_jxlthumbpages    { return &get_redis_conf( "jxlthumbpages",   "0" ) }
sub enable_avif_thumbnails { return &get_redis_conf( "avifthumbpages", "0" ) }
sub get_replacedupe      { return &get_redis_conf( "replacedupe",     "0" ) }
sub can_replacetitles    { return &get_redis_conf( "replacetitles",   "1" ) }
sub get_language         { return &get_redis_conf( "language",        "auto" ) }
sub get_excludednamespaces { return &get_redis_conf( "excludednamespaces", "source, date_added" ) }

# DPI used by GhostScript when rendering PDF pages. Env var LRR_PDF_DPI overrides the Redis config.
# Default 200 matches the previous hardcoded value.
sub get_pdfdpi {
    if ( $ENV{LRR_PDF_DPI} ) {
        return $ENV{LRR_PDF_DPI};
    }
    return &get_redis_conf( "pdfdpi", "200" );
}

# Cached check for whether the default "kamimamita" password is still active.
# bcrypt is ~50-100ms; cache per-worker for 30s. Trade-off: prefork workers may serve stale
# state for up to 30s after a password change.
sub is_default_password {
    state ( $cached, $expiry );
    my $now = time;
    if ( !defined $expiry || $now >= $expiry ) {
        my $pw = &get_password;
        $cached = ( $pw && Authen::Passphrase->from_rfc2307($pw)->match("kamimamita") ) ? 1 : 0;
        $expiry = $now + 30;
    }
    return $cached;
}

# Returns ($apikey, $bearer_header) cached for 30s per worker. Avoids the
# Redis round-trip + base64 encode on every authenticated API request.
# Trade-off: rotated keys may take up to 30s to propagate across workers.
sub get_apikey_and_bearer {
    state ( $cached_key, $cached_bearer, $expiry );
    my $now = time;
    if ( !defined $expiry || $now >= $expiry ) {
        my $key = &get_apikey;
        $cached_key    = $key;
        $cached_bearer = $key ne "" ? "Bearer " . encode_base64( $key, "" ) : "";
        $expiry        = $now + 30;
    }
    return ( $cached_key, $cached_bearer );
}

1;
