package LANraragi::Utils::RedisScript;

use v5.36;
use strict;
use warnings;

use Exporter qw(import);

our @EXPORT_OK = qw(evalsha_cached release_owned_lease);

sub release_owned_lease ( $redis, $key, $token ) {
    return unless $key && defined $token;
    my $script = <<'LUA';
if redis.call('GET', ARGV[1]) ~= ARGV[2] then return 0 end
return redis.call('DEL', ARGV[1])
LUA
    return evalsha_cached($redis, 'release_minion_lease', $script, $key, $token);
}

# Per-worker memo of Lua script SHAs so a script body is uploaded once per
# process instead of on every request. The script body travels with the SHA so
# a long-lived worker reloads it if a caller reuses a logical name for changed
# Lua. EVALSHA after a Redis restart (script cache flushed) raises NOSCRIPT,
# so reload once and retry. Callers retain responsibility for their existing
# fallback behavior when Lua is unavailable.
my %LUA_CACHE;

sub evalsha_cached ( $redis, $name, $script, @args ) {

    my $cached = $LUA_CACHE{$name};
    my $sha = $cached && $cached->{script} eq $script ? $cached->{sha} : undef;
    unless ($sha) {
        $sha = $redis->script_load($script);
        $LUA_CACHE{$name} = {
            script => $script,
            sha    => $sha,
        };
    }

    my $result = eval { $redis->evalsha( $sha, 0, @args ) };
    if ($@) {
        die $@ unless $@ =~ /NOSCRIPT/i;
        $sha = $redis->script_load($script);
        $LUA_CACHE{$name} = {
            script => $script,
            sha    => $sha,
        };
        $result = $redis->evalsha( $sha, 0, @args );
    }
    return $result;
}

1;
