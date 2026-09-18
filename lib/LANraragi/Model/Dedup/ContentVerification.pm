package LANraragi::Model::Dedup::ContentVerification;

use v5.36;
use strict;
use warnings;

use Archive::Libarchive qw(ARCHIVE_OK ARCHIVE_EOF);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(S_IFREG);
use Time::HiRes qw(stat time);
use LANraragi::Utils::Generic qw(is_image);
use LANraragi::Utils::Archive ();
use LANraragi::Utils::Path ();

# Exact compressed-container-independent image evidence. No extraction, image
# decoding, network access, deletion, or inference from pHash is involved.
use constant MAX_BYTES => 2 * 1024 * 1024 * 1024;
use constant MAX_ENTRIES => 10_000;
use constant MAX_SECONDS => 120;

sub file_stamp {
    my ($path) = @_;
    my @s = stat($path);
    die "Archive is unavailable\n" unless @s && -f _ && -r $path;
    return sha256_hex(join ':', @s[0, 1, 7, 9, 10]);
}

sub image_manifest {
    my ($path, $limits) = @_;
    $limits //= {};
    die "PDF and remote comics require manual review\n" if $path =~ /\.(?:pdf|cbw)\z/i;
    my $before = file_stamp($path);
    my $deadline = time() + ($limits->{seconds} // MAX_SECONDS);
    my $max_bytes = $limits->{bytes} // MAX_BYTES;
    my $max_entries = $limits->{entries} // MAX_ENTRIES;
    my $reader = Archive::Libarchive::ArchiveRead->new;
    $reader->support_filter_all;
    $reader->support_format_all;
    die "Cannot open archive for verification\n" unless $reader->open_filename($path, 64 * 1024) == ARCHIVE_OK;
    my $entry = Archive::Libarchive::Entry->new;
    my ($bytes, $entries) = (0, 0);
    my (@digests, %names);
    my $result;
    my $ok = eval {
        while (1) {
            die "Verification time limit exceeded\n" if time() > $deadline;
            my $rc = $reader->next_header($entry);
            last if $rc == ARCHIVE_EOF;
            die "Archive header could not be read\n" unless $rc == ARCHIVE_OK;
            die "Archive entry limit exceeded\n" if ++$entries > $max_entries;
            my $name = $entry->pathname;
            unless (is_image($name)) {
                die "Archive entry could not be skipped\n" unless $reader->read_data_skip == ARCHIVE_OK;
                next;
            }
            die "Image entry is not a regular file\n" unless $entry->filetype == S_IFREG;
            die "Ambiguous duplicate image filename\n" if $names{$name}++;
            die "Verification byte limit exceeded\n" if $entry->size > $max_bytes - $bytes;
            my $sha = Digest::SHA->new(256);
            my ($size, $prefix) = (0, '');
            while (1) {
                die "Verification time limit exceeded\n" if time() > $deadline;
                my $buffer;
                my $n = $reader->read_data(\$buffer, 64 * 1024);
                die "Image data could not be read\n" if $n < 0;
                last if $n == 0;
                $size += $n;
                $bytes += $n;
                die "Verification byte limit exceeded\n" if $bytes > $max_bytes;
                $prefix .= substr($buffer, 0, 4 - length($prefix)) if length($prefix) < 4;
                $sha->add($buffer);
            }
            # Match the reader's AppleDouble exclusion without loading the
            # whole entry into memory or opening the container again.
            next if LANraragi::Utils::Archive::is_apple_signature_like_path($name)
                && ($prefix eq "\x00\x05\x16\x07" || $prefix eq "\x00\x05\x16\x00");
            die "Empty image entry requires manual review\n" unless $size;
            push @digests, $sha->hexdigest;
        }
        die "No image pages to verify\n" unless @digests;
        die "Archive changed during verification\n" unless file_stamp($path) eq $before;
        # Keep repeated images: sets would falsely equate [A,A,B] and [A,B,B].
        $result = { digest => sha256_hex(join '', sort @digests), pages => scalar(@digests),
            bytes => $bytes, stamp => $before };
        1;
    };
    my $error = $@;
    $reader->close;
    die $error unless $ok;
    return $result;
}

sub verify_pair {
    my ($redis, $a, $b, $cache) = @_;
    $cache //= {};
    my @manifests;
    my @paths;
    for my $id ($a, $b) {
        my $path = LANraragi::Utils::Path::get_archive_path($redis, $id);
        die "Archive is unavailable\n" unless defined $path && length $path;
        my $stamp = file_stamp($path);
        my $cached = $cache->{$id};
        $cached = $cache->{$id} = image_manifest($path) unless $cached && $cached->{stamp} eq $stamp;
        push @manifests, $cached;
        push @paths, $path;
    }
    for my $i (0, 1) {
        die "Archive changed during verification\n" unless file_stamp($paths[$i]) eq $manifests[$i]{stamp};
    }
    return {
        state => $manifests[0]{digest} eq $manifests[1]{digest} ? 'same_images' : 'different_images',
        method => 'sha256_image_multiset_v1',
        pages_a => $manifests[0]{pages}, pages_b => $manifests[1]{pages},
        checked_at => int(time()),
    };
}

1;
