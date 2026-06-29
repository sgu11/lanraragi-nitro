use strict;
use warnings;
use utf8;

use File::Temp qw(tempfile);
use Test::More;

use LANraragi::Utils::Database;
use LANraragi::Model::Archive;

package FakeChangeIdRedis {
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            hashes => $args{hashes} || {},
            sets   => {},
            hdel   => [],
            quit   => 0,
        }, $class;
    }

    sub exists {
        my ( $self, $key ) = @_;
        return exists $self->{hashes}{$key} ? 1 : 0;
    }

    sub rename {
        my ( $self, $old, $new ) = @_;
        $self->{hashes}{$new} = delete $self->{hashes}{$old};
        return 1;
    }

    sub srem { return 1 }
    sub sadd { return 1 }

    sub hdel {
        my ( $self, $key, @fields ) = @_;
        push @{ $self->{hdel} }, [ $key, @fields ];
        delete @{ $self->{hashes}{$key} }{@fields};
        return scalar @fields;
    }

    sub hset {
        my ( $self, $key, $field, $value ) = @_;
        $self->{hashes}{$key}{$field} = $value;
        return 1;
    }

    sub hget {
        my ( $self, $key, $field ) = @_;
        return $self->{hashes}{$key}{$field};
    }

    sub quit {
        my ($self) = @_;
        $self->{quit}++;
        return 1;
    }
}

package main;

my $old_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
my $new_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
my ( $fh, $archive_path ) = tempfile( UNLINK => 1 );
print {$fh} "archive bytes";
close $fh;

my $redis = FakeChangeIdRedis->new(
    hashes => {
        $old_id => {
            file  => $archive_path,
            tags  => "artist:someone",
            title => "Old title",
        },
    },
);
my @path_clears;
my @page_cache_clears;

{
    no warnings 'redefine';
    local *LANraragi::Model::Config::get_redis = sub { return $redis };
    local *LANraragi::Utils::Database::get_archive_path = sub { return $archive_path };
    local *LANraragi::Model::Archive::invalidate_archive_path_cache = sub { push @path_clears, @_ };
    local *LANraragi::Utils::Database::clear_by_id = sub { push @page_cache_clears, @_ };
    local *LANraragi::Model::Category::get_categories_containing_archive = sub { return () };
    local *LANraragi::Model::Tankoubon::get_tankoubons_containing_archive = sub { return () };

    LANraragi::Utils::Database::change_archive_id( $old_id, $new_id );
}

is_deeply( \@path_clears, [ $old_id, $new_id ], "change_archive_id invalidates archive path memo for old and new ids" );
is_deeply( \@page_cache_clears, [ $old_id, $new_id ], "change_archive_id clears page-cache variants for old and new ids" );

done_testing();
