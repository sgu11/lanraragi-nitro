package LANraragi::Model::Stats;

use feature qw(signatures);
no warnings 'experimental::signatures';

use strict;
use warnings;
use utf8;

use Redis;
use File::Find;
use Mojo::JSON qw(encode_json);
use LANraragi::Model::Tankoubon;

use LANraragi::Utils::Generic  qw(is_archive intersect_arrays);
use LANraragi::Utils::String   qw(trim trim_CRLF trim_url);
use LANraragi::Utils::Redis    qw(redis_decode redis_encode);
use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::Database qw(get_arcsize);

sub get_archive_count {
    my $redis = LANraragi::Model::Config->get_redis_search;

    return $redis->scard("LRR_TANKGROUPED") + 0;

    # Total number of archives (as int) -- Tanks are included and replace the archives they contain.
}

sub get_page_stat {

    my $redis = LANraragi::Model::Config->get_redis_config;
    my $stat  = ($redis->get("LRR_TOTALPAGESTAT") || 0) + 0;
    $redis->quit();

    return $stat;
}

# This operation builds the following hashes:
# - LRR_URL_MAP, which maps URLs to IDs in the database that have them as a source: tag
# - LRR_STATS, which is a sorted set used to build the statistics/tag cloud JSON
# - LRR_UNTAGGED, which is a set used by the untagged archives API
# - LRR_NEW, which contains all archives that have isnew=true
# - LRR_TITLES, which is a lexicographically sorted set containing all (archive + tank) titles in the DB, alongside their ID. (In the "title\0ID" format)
# - LRR_TANKGROUPED, which is a set containing all tank IDs in the DB, and the archive IDs that aren't in any tanks.
# * It also builds index sets for each distinct tag.
sub build_stat_hashes {

  # This method does only one atomic write transaction, using Redis' watch/multi mode.
  # But we can't use the connection to get other data while it's in transaction mode!
  # So we instantiate a second connection to get the data we need. Helps as well now that both connections are made on separate DBs.
    my $redis   = LANraragi::Model::Config->get_redis;
    my $redistx = LANraragi::Model::Config->get_redis_search;
    my $logger  = get_logger( "Tag Stats", "lanraragi" );

    # Archive IDs via maintained LRR_ALL_ARCHIVES set (B.3). Lazy backfill inside.
    my @keys          = LANraragi::Utils::Database::all_archive_ids($redis);
    my $archive_count = scalar @keys;
    my ( $total, $filtered, @tanks ) = LANraragi::Model::Tankoubon::get_tankoubon_list(-1);

    # Cancel the transaction if the hashes have been modified by another job in the meantime.
    # This also allows for the previous stats/map to still be readable until we're done.
    $redistx->watch( "LRR_STATS", "LRR_URLMAP", "LRR_UNTAGGED", "LRR_TITLES", "LRR_NEW", "LRR_TANKGROUPED" );
    $redistx->multi;

    # Hose the entire index DB since we're rebuilding it
    $redistx->flushdb();

    # Iterate on hashes to get their tags
    $logger->info("Building stat indexes... ($archive_count archives, $total tankoubons)");

    # Read each archive once, including those shared by several tankoubons.
    # Bound queued callbacks while keeping the metadata available for tank tags.
    my %prefetch;
    my @pending = @keys;
    while (@pending) {
        my @batch = splice @pending, 0, 256;
        my $error;
        for my $id (@batch) {
            $redis->hmget( $id, 'tags', 'title', 'isnew', sub {
                my ( $reply, $err ) = @_;
                $error //= $err;
                $prefetch{$id} = $reply;
            } );
        }
        $redis->wait_all_responses;
        if (defined $error) {
            $redistx->discard;
            die $error;
        }
    }

    my %grouped;
    foreach my $tank (@tanks) {
        my $tank_id = $tank->{id};
        my @members = @{ $tank->{archives} };
        $grouped{$_} = 1 for @members;
        $redistx->sadd( "LRR_TANKGROUPED", $tank_id ) if @members;

        my $encoded_title = redis_encode( trim( trim_CRLF( lc($tank->{name}) ) ) );
        $redistx->zadd( "LRR_TITLES", 0, "$encoded_title\0$tank_id" );

        my @member_tags = map { redis_decode( $prefetch{$_}[0] // "" ) } @members;
        my $unified = LANraragi::Model::Tankoubon::get_tank_unified_tags( $tank_id, \@member_tags );

        # Own tags contribute once to statistics. Imputed tags only contribute
        # membership; the source archives are counted separately below.
        foreach my $tag ( @{ $unified->{own_tags} } ) {
            next unless length $tag;
            $redistx->zincrby( "LRR_STATS", 1, redis_encode(lc($tag)) );
        }
        foreach my $tag ( @{ $unified->{own_tags} }, @{ $unified->{imputed_tags} } ) {
            next unless length $tag;
            my $index = "INDEX_" . redis_encode(lc($tag));
            $redistx->sadd( $index, $tank_id );
            $redistx->zadd( "LRR_TAG_INDEX_NAMES", 0, $index );
        }
    }

    foreach my $id (@keys) {
        $redistx->sadd( "LRR_TANKGROUPED", $id ) unless $grouped{$id};
        my ( $rawtags, $title, $isnew ) = @{ $prefetch{$id} // [] };
        my $has_tags = _index_prefetched_tags( $redistx, $id, $id, $rawtags, $title );
        $redistx->sadd( "LRR_UNTAGGED", $id ) unless $has_tags;
        $redistx->sadd( "LRR_NEW", $id ) if defined $isnew && $isnew eq "true";
    }

    # Add a stamp to the stats hash to indicate when it was last updated
    $redistx->set( "LAST_JOB_TIME", time() );

    $redistx->exec;
    my $total_visible_archives = scalar grep { !$grouped{$_} } @keys;
    $logger->info("Stat indexes built! ($total_visible_archives archives, $total tankoubons)");
    $redis->quit;
    $redistx->quit;
}

# Index an archive using its prefetched metadata. Tank membership is maintained
# separately so an archive contributes to statistics exactly once.
sub _index_prefetched_tags ( $redistx, $index_id, $archive_id, $rawtags, $title ) {
    my $logger   = get_logger( "Tag Stats", "lanraragi" );
    my $has_tags = 0;

    if ( defined $rawtags ) {
        my @tags = split( /,\s?/, redis_decode($rawtags) );

        foreach my $t (@tags) {
            $t = trim($t);
            $t = trim_CRLF($t);
            next unless length $t;

            $has_tags = 1 unless $t =~ /(artist|parody|series|language|event|group|date_added|timestamp|source):.*/;

            if ( $t =~ /source:(.*)/i ) {
                my $url = trim_url($1);
                $redistx->hset( "LRR_URLMAP", $url, $archive_id );
            }

            my $redis_tag = redis_encode( lc($t) );
            $redistx->zincrby( "LRR_STATS", 1, $redis_tag );
            $redistx->sadd( "INDEX_" . $redis_tag, $index_id );
            if ( $index_id ne $archive_id ) {
                $redistx->sadd( "INDEX_" . $redis_tag, $archive_id );
            }
            $redistx->zadd( "LRR_TAG_INDEX_NAMES", 0, "INDEX_" . $redis_tag );
        }
    }

    if ( defined $title && length $title ) {
        my $t = lc( redis_decode($title) );
        $t = trim($t);
        $t = trim_CRLF($t);
        $t = redis_encode($t);
        $redistx->zadd( "LRR_TITLES", 0, "$t\0$archive_id" );
    }

    return $has_tags;
}

# Parse the tags of the given archive_id,
# and add the given index_id to all the search indexes that contain said tags.
sub index_tags_for_id ( $redis, $redistx, $index_id, $archive_id ) {
    return 0 unless $redis->hexists( $archive_id, "tags" );
    return _index_prefetched_tags(
        $redistx, $index_id, $archive_id,
        $redis->hget( $archive_id, "tags" ), $redis->hget( $archive_id, "title" )
    );
}

sub is_url_recorded ($url) {

    my $logger = get_logger( "Tag Stats", "lanraragi" );
    my $redis  = LANraragi::Model::Config->get_redis_search;
    my $id     = 0;
    $logger->debug("Checking if url $url is in the url map.");

    # Trim last slash from url if it's present
    $url = trim_url($url);

    if ( $redis->hexists( "LRR_URLMAP", $url ) ) {
        $id = $redis->hget( "LRR_URLMAP", $url );
        $logger->debug("Found! id $id.");
    }
    $redis->quit;
    return $id;
}

sub build_tag_stats {

    my ( $minscore, $excluded_ns ) = @_;
    my $logger = get_logger( "Tag Stats", "lanraragi" );
    $logger->debug("Serving tag statistics with a minimum weight of $minscore");

    # Convert excluded namespaces into a hash for quick lookup
    my %excluded = map { $_ => 1 } @{ $excluded_ns || [] };

    # Login to Redis and grab the stats sorted set
    my $redis    = LANraragi::Model::Config->get_redis_search;
    my %tagcloud = $redis->zrangebyscore( "LRR_STATS", $minscore, "+inf", "WITHSCORES" );
    $redis->quit();

    # Go through the data from stats and build an array
    my @tags;

    for ( keys %tagcloud ) {
        my $w = $tagcloud{$_};

        # Split namespace
        # detect the : symbol and only use what's after it
        my $ns = "";
        my $t  = redis_decode($_);
        if ( $t =~ /([^:]*):(.*)/ ) { $ns = $1; $t = $2; }

        next if $_ eq "";                       # Skip empty Redis keys
        next if %excluded && $excluded{$ns};    # Skip tags in excluded namespaces

        push( @tags, { text => $t, namespace => $ns, weight => $w } );
    }

    return \@tags;
}

sub compute_content_size {
    my $redis_db = LANraragi::Model::Config->get_redis;

    my @keys = LANraragi::Utils::Database::all_archive_ids($redis_db);

    $redis_db->multi;
    foreach my $id (@keys) {
        get_arcsize( $redis_db, $id );
    }
    my @result = $redis_db->exec;
    $redis_db->quit;

    my $size = 0;
    foreach my $row (@result) {
        if ( defined($row) ) {
            $size = $size + $row;
        }
    }

    return int( $size / 1073741824 * 100 ) / 100;
}

1;
