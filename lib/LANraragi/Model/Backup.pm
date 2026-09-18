package LANraragi::Model::Backup;

use strict;
use warnings;
use utf8;

use Redis;
use Mojo::JSON qw(decode_json encode_json);

use LANraragi::Model::Category;
use LANraragi::Model::Tankoubon;
use LANraragi::Utils::String   qw(trim_CRLF);
use LANraragi::Utils::Database qw(invalidate_cache set_title set_tags set_summary);
use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::Redis    qw(redis_decode redis_encode);

#build_backup_JSON($job)
#Goes through the Redis archive IDs and builds a JSON string containing their metadata.
#If $job is provided (Minion job), progress will be reported via job notes.
sub build_backup_JSON {
    my ($job)  = @_;
    my $redis  = LANraragi::Model::Config->get_redis;
    my $logger = get_logger( "Backup/Restore", "lanraragi" );

    # Basic structure of the backup object
    my %backup = (
        categories => [],
        archives   => [],
        tankoubons => [],
        stamps     => []
    );

    # Backup categories first
    my @cats       = LANraragi::Utils::Database::all_category_ids($redis);
    my $cat_count  = 0;
    my $total_cats = scalar @cats;

    # Parse the category list and add them to JSON.
    foreach my $key (@cats) {

        # Use an eval block in case decode_json fails. This'll drop the category from the backup,
        # But it's probably dinged anyways...
        eval {
            my %data = $redis->hgetall($key);
            my ( $name, $search, $archives ) = @data{qw(name search archives)};

            # redis-decode the name, and the search terms if they exist
            ( $_ = redis_decode($_) ) for ( $name, $search );

            my %category = (
                catid    => $key,
                name     => $name,
                search   => $search,
                archives => decode_json($archives)
            );

            push @{ $backup{categories} }, \%category;
        };

        $logger->trace("Backing up category $key: $@");
        $cat_count++;

        # Report progress if job is provided
        if ($job) {
            $job->note(
                categories_processed => $cat_count,
                total_categories     => $total_cats,
                status               => "Processing categories..."
            );
        }
    }

    # Backup tanks
    my ( $total, $filtered, @tanks ) = LANraragi::Model::Tankoubon::get_tankoubon_list(-1);
    my $tank_count  = 0;
    my $total_tanks = scalar @tanks;

    foreach my $tank (@tanks) {

        my $tank_id       = %$tank{id};
        my $tank_title    = %$tank{name};
        my $tank_summary  = %$tank{summary} // "";
        my $tank_tags     = %$tank{tags}    // "";
        my @tank_archives = @{ %$tank{archives} };

        my %tank = (
            tankid   => $tank_id,
            name     => $tank_title,
            summary  => $tank_summary,
            tags     => $tank_tags,
            archives => \@tank_archives
        );

        push @{ $backup{tankoubons} }, \%tank;
        $tank_count++;

        # Report progress if job is provided
        if ($job) {
            $job->note(
                categories_processed => $cat_count,
                total_categories     => $total_cats,
                tankoubons_processed => $tank_count,
                total_tankoubons     => $total_tanks,
                status               => "Processing tankoubons..."
            );
        }
    }

    # Backup stamps
    my @stamp_ids = $redis->keys('STAMPS_*');

    foreach my $stamp_id (@stamp_ids) {
        eval {
            my %stamp_hash = $redis->hgetall($stamp_id);
            my ( $content, $position, $archive_id ) = @stamp_hash{qw(content position archive_id)};

            ( $_ = redis_decode($_) ) for ( $content, $position, $archive_id );
            ( $_ = trim_CRLF($_) )    for ( $content, $position, $archive_id );

            my %stamp = (
                stamp_id    => $stamp_id,
                content     => $content,
                position    => $position,
                archive_id  => $archive_id
            );

            push @{ $backup{stamps} }, \%stamp;
        };

        $logger->trace("Backing up stamp $stamp_id: $@");
    }

    # Backup archives themselves next
    my @keys       = LANraragi::Utils::Database::all_archive_ids($redis);
    my $arc_count  = 0;
    my $total_arcs = scalar @keys;

    # Pipelined HMGET — fetch only the 5 fields we need for backup, one round-trip instead of N.
    # Callback sig is (reply, error); use $_[0] for the arrayref of field values.
    my @hmget_results;
    my @fields = qw(name title tags summary thumbhash spreadstart stamps toc);
    for my $id (@keys) {
        $redis->hmget( $id, @fields, sub { push @hmget_results, [ $id, $_[0] ] } );
    }
    $redis->wait_all_responses;

    for my $pair (@hmget_results) {
        my ( $id, $values ) = @$pair;
        eval {
            my ( $name, $title, $tags, $summary, $thumbhash, $spreadstart, $stamps, $toc ) = @$values;

            ( $_ = redis_decode($_) ) for ( $name, $title, $tags, $summary, $toc );
            ( $_ = trim_CRLF($_) )    for ( $name, $title, $tags, $summary );

            # Backup all user-generated metadata, alongside the unique ID.
            my %arc = (
                arcid       => $id,
                title       => $title,
                tags        => $tags,
                summary     => $summary,
                thumbhash   => $thumbhash,
                filename    => $name,
                spreadstart => $spreadstart,
                stamps      => $stamps,
                toc         => $toc
            );

            push @{ $backup{archives} }, \%arc;
        };

        $logger->trace("Backing up archive $id: $@");
        $arc_count++;

        # Report progress every 100 archives if job is provided
        if ( $job && $arc_count % 100 == 0 ) {
            $job->note(
                categories_processed => $cat_count,
                total_categories     => $total_cats,
                tankoubons_processed => $tank_count,
                total_tankoubons     => $total_tanks,
                archives_processed   => $arc_count,
                total_archives       => $total_arcs,
                status               => "Processing archives..."
            );
        }

    }

    # Final progress update
    if ($job) {
        $job->note(
            categories_processed => $cat_count,
            total_categories     => $total_cats,
            tankoubons_processed => $tank_count,
            total_tankoubons     => $total_tanks,
            archives_processed   => $arc_count,
            total_archives       => $total_arcs,
            status               => "Finalizing backup..."
        );
    }

    $redis->quit();
    return encode_json \%backup;

}

sub _validate_restore_payload {
    my ($json) = @_;

    die "Invalid backup: root must be an object.\n" unless ref $json eq "HASH";

    for my $field (qw(categories archives)) {
        die "Invalid backup: '$field' must be an array.\n"
          unless ref $json->{$field} eq "ARRAY";
    }

    for my $field (qw(tankoubons stamps)) {
        $json->{$field} = [] unless exists $json->{$field};
        die "Invalid backup: '$field' must be an array.\n"
          unless ref $json->{$field} eq "ARRAY";
    }

    for my $category ( @{ $json->{categories} } ) {
        die "Invalid backup: every category must be an object.\n" unless ref $category eq "HASH";
        die "Invalid backup: category identifiers and names must be strings.\n"
          unless defined $category->{catid}
          && !ref $category->{catid}
          && defined $category->{name}
          && !ref $category->{name};
        die "Invalid backup: category identifier has an invalid format.\n"
          unless $category->{catid} =~ /^SET_\d{10}$/;
        die "Invalid backup: category archives must be an array.\n"
          unless ref $category->{archives} eq "ARRAY";
        for my $id ( @{ $category->{archives} } ) {
            die "Invalid backup: category archive identifier has an invalid format.\n"
              unless defined($id) && !ref($id) && ( $id =~ /^[a-f0-9]{40}$/i || $id =~ /^TANK_\d{10}$/ );
        }
        $category->{search} = "" unless defined $category->{search};
        die "Invalid backup: category search must be a string.\n" if ref $category->{search};
    }

    for my $tank ( @{ $json->{tankoubons} } ) {
        die "Invalid backup: every tankoubon must be an object.\n" unless ref $tank eq "HASH";
        die "Invalid backup: tankoubon identifiers and names must be strings.\n"
          unless defined $tank->{tankid}
          && !ref $tank->{tankid}
          && defined $tank->{name}
          && !ref $tank->{name};
        die "Invalid backup: tankoubon identifier has an invalid format.\n"
          unless $tank->{tankid} =~ /^TANK_\d{10}$/;
        die "Invalid backup: tankoubon archives must be an array.\n"
          unless ref $tank->{archives} eq "ARRAY";
        for my $id ( @{ $tank->{archives} } ) {
            die "Invalid backup: tankoubon archive identifier has an invalid format.\n"
              unless defined($id) && !ref($id) && $id =~ /^[a-f0-9]{40}$/i;
        }
        for my $field (qw(summary tags)) {
            $tank->{$field} = "" unless defined $tank->{$field};
            die "Invalid backup: tankoubon '$field' must be a string.\n" if ref $tank->{$field};
        }
    }

    for my $archive ( @{ $json->{archives} } ) {
        die "Invalid backup: every archive must be an object.\n" unless ref $archive eq "HASH";
        die "Invalid backup: archive identifiers must be strings.\n"
          unless defined $archive->{arcid} && !ref $archive->{arcid};
        die "Invalid backup: archive identifier has an invalid format.\n"
          unless $archive->{arcid} =~ /^[a-f0-9]{40}$/i;
        for my $field (qw(title tags summary)) {
            $archive->{$field} = "" unless defined $archive->{$field};
            die "Invalid backup: archive '$field' must be a string.\n" if ref $archive->{$field};
        }
        for my $field (qw(thumbhash spreadstart stamps toc)) {
            die "Invalid backup: archive '$field' must be a string or null.\n"
              if defined $archive->{$field} && ref $archive->{$field};
        }
    }

    for my $stamp ( @{ $json->{stamps} } ) {
        die "Invalid backup: every stamp must be an object.\n" unless ref $stamp eq "HASH";
        for my $field (qw(stamp_id content position archive_id)) {
            die "Invalid backup: stamp '$field' must be a string.\n"
              unless defined $stamp->{$field} && !ref $stamp->{$field};
        }
        die "Invalid backup: stamp identifier has an invalid format.\n"
          unless $stamp->{stamp_id} =~ /^STAMPS_\d+_\d+$/;
        die "Invalid backup: stamp archive identifier has an invalid format.\n"
          unless $stamp->{archive_id} =~ /^[a-f0-9]{40}$/i;
    }

    return $json;
}

#restore_from_JSON(backupJSON, $job)
#Restores metadata from a JSON to the Redis archive, for existing IDs.
#If $job is provided (Minion job), progress will be reported via job notes.
sub restore_from_JSON {
    my ( $json_data, $job ) = @_;
    my $json   = _validate_restore_payload( decode_json($json_data) );
    my $redis  = LANraragi::Model::Config->get_redis;
    my $logger = get_logger( "Backup/Restore", "lanraragi" );

    $logger->info("Received a JSON backup to restore.");

    # Clean the database before restoring from JSON
    LANraragi::Utils::Database::clean_database();

    my $cat_count   = 0;
    my $total_cats  = scalar @{ $json->{categories} };
    my $tank_count  = 0;
    my $total_tanks = $json->{tankoubons} ? scalar @{ $json->{tankoubons} } : 0;
    my $arc_count   = 0;
    my $total_arcs  = scalar @{ $json->{archives} };

    my $skipped_memberships = 0;

    # Create tankoubons before resolving category references to them.
    foreach my $tank ( @{ $json->{tankoubons} } ) {

        my $tank_id = $tank->{"tankid"};
        $logger->info("Restoring Tankoubon $tank_id...");

        LANraragi::Model::Tankoubon::create_tankoubon( $tank->{name}, $tank_id )
          unless $redis->exists($tank_id);
        my ( $updated, $error ) = LANraragi::Model::Tankoubon::update_metadata(
            $tank_id, { metadata => { map { $_ => $tank->{$_} // "" } qw(name summary tags) } }
        );
        die "Could not restore Tankoubon $tank_id: $error\n" unless $updated;

        # Metadata backups can be restored over a partial matching library.
        # Keep available members and report missing references instead of
        # silently rejecting the complete list.
        my @archives = grep { $redis->exists($_) } @{ $tank->{archives} };
        $skipped_memberships += @{ $tank->{archives} } - @archives;
        ( $updated, $error ) = LANraragi::Model::Tankoubon::update_archive_list(
            $tank_id, { archives => \@archives }
        );
        die "Could not restore Tankoubon $tank_id members: $error\n" unless $updated;

        $tank_count++;

        # Report progress if job is provided
        if ($job) {
            $job->note(
                categories_processed => $cat_count,
                total_categories     => $total_cats,
                tankoubons_processed => $tank_count,
                total_tankoubons     => $total_tanks,
                status               => "Restoring tankoubons..."
            );
        }
    }

    foreach my $category ( @{ $json->{categories} } ) {

        my $cat_id = $category->{"catid"};
        $logger->info("Restoring Category $cat_id...");

        my $name     = $category->{"name"};
        my $search   = $category->{"search"};
        my @archives = @{ $category->{"archives"} };

        LANraragi::Model::Category::create_category( $name, $search, 0, $cat_id );

        # Explicitly set "new category" values to avoid them being absent from the DB entry
        # (which likely breaks a bunch of things)
        $redis->hset( $cat_id, "archives", "[]" );

        foreach my $arcid (@archives) {
            next if length $search;
            unless ( $redis->exists($arcid) ) {
                $skipped_memberships++;
                next;
            }
            my ( $added, $error ) = LANraragi::Model::Category::add_to_category( $cat_id, $arcid );
            die "Could not restore Category $cat_id: $error\n" unless $added;
        }

        $cat_count++;

        # Report progress if job is provided
        if ($job) {
            $job->note(
                categories_processed => $cat_count,
                total_categories     => $total_cats,
                status               => "Restoring categories..."
            );
        }
    }

    foreach my $archive ( @{ $json->{archives} } ) {
        my $id = $archive->{"arcid"};

        #If the archive exists, restore metadata.
        if ( $redis->exists($id) ) {

            $logger->info("Restoring metadata for Archive $id...");
            my $thumbhash = redis_encode( $archive->{"thumbhash"} // "" );

            set_title( $id, $archive->{"title"} );
            set_tags( $id, $archive->{"tags"} );
            set_summary( $id, $archive->{"summary"} );

            if ( exists $archive->{"spreadstart"} ) {
                $redis->hset( $id, "spreadstart", $archive->{"spreadstart"} );
            }

            if (   $redis->hexists( $id, "thumbhash" )
                && $redis->hget( $id, "thumbhash" ) ne "" ) {
                $redis->hset( $id, "thumbhash", $thumbhash );
            }

            if ( defined $archive->{"stamps"} ) {
                my $stamps = redis_encode( $archive->{"stamps"} );
                $redis->hset( $id, "stamps", $stamps );
            } else {
                $redis->hset( $id, "stamps", "[]" );
            }

            if ( defined $archive->{"toc"} ) {
                my $toc = redis_encode( $archive->{"toc"} );
                $redis->hset( $id, "toc", $toc );
            } else {
                $redis->hset( $id, "toc", "{}" );
            }

        }

        $arc_count++;

        # Report progress periodically (every 100 archives) if job is provided
        if ( $job && $arc_count % 100 == 0 ) {
            $job->note(
                categories_processed => $cat_count,
                total_categories     => $total_cats,
                tankoubons_processed => $tank_count,
                total_tankoubons     => $total_tanks,
                archives_processed   => $arc_count,
                total_archives       => $total_arcs,
                status               => "Restoring archives..."
            );
        }
    }

    foreach my $stamp ( @{ $json->{stamps} } ) {
        my $stamp_id = $stamp->{"stamp_id"};

        my $content = $stamp->{"content"};
        my $position = $stamp->{"position"};
        my $archive_id = $stamp->{"archive_id"};

        #If the archive exists, restore metadata.
        if ( $redis->exists($archive_id) ) {

            ( $_ = redis_encode($_) ) for ( $content, $position, $archive_id );

            $redis->hset( $stamp_id, "content", $content);
            $redis->hset( $stamp_id, "position", $position);
            $redis->hset( $stamp_id, "archive_id", $archive_id);
        }

    }

    $logger->warn("Skipped $skipped_memberships missing collection members during restore.")
      if $skipped_memberships;

    # Final progress update
    if ($job) {
        $job->note(
            categories_processed => $cat_count,
            total_categories     => $total_cats,
            tankoubons_processed => $tank_count,
            total_tankoubons     => $total_tanks,
            archives_processed   => $arc_count,
            total_archives       => $total_arcs,
            skipped_memberships  => $skipped_memberships,
            status               => "Finalizing restore..."
        );
    }

    # Force a refresh
    invalidate_cache();
    $redis->quit();
}

1;
