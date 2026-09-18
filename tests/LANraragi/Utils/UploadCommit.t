use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use LANraragi::Utils::UploadCommit;

sub fixture {
    my $dir = tempdir(CLEANUP => 1);
    path("$dir/old.cbz")->spurt('old archive');
    path("$dir/new.upload")->spurt('new archive');
    return ($dir, "$dir/old.cbz", "$dir/new.upload");
}

subtest 'failed final rename leaves old bytes and metadata untouched' => sub {
    my ($dir, $old, $staged) = fixture();
    my $writes = 0;
    no warnings 'redefine';
    local *LANraragi::Utils::UploadCommit::rename_path = sub {
        my ($from, $to) = @_;
        if ($from eq $staged) { $! = 13; return 0; }
        return CORE::rename($from, $to);
    };
    my $ok = eval { LANraragi::Utils::UploadCommit::publish($staged, $old, $old, sub { $writes++ }, sub { die 'unexpected rollback' }); 1 };
    ok(!$ok, 'rename failure is returned');
    is(path($old)->slurp, 'old archive', 'old bytes restored');
    is($writes, 0, 'metadata was never touched');
};

subtest 'metadata failure restores old file before restoring metadata' => sub {
    my ($dir, $old, $staged) = fixture();
    my $metadata = 'old metadata';
    my $ok = eval { LANraragi::Utils::UploadCommit::publish($staged, $old, $old,
        sub { $metadata = 'partial'; die "DB failure\n" },
        sub { is(path($old)->slurp, 'old archive', 'old file visible during rollback'); $metadata = 'old metadata' }); 1 };
    ok(!$ok, 'DB failure is returned');
    is($metadata, 'old metadata', 'metadata restored');
    is(path($old)->slurp, 'old archive', 'old bytes restored');
};

subtest 'replacement commit keeps a backup until metadata succeeds' => sub {
    my ($dir, $old, $staged) = fixture();
    my $result = LANraragi::Utils::UploadCommit::publish($staged, $old, $old, sub {
        is(path($old)->slurp, 'new archive', 'new bytes installed before metadata');
        my @backups = glob "$dir/.lrr-upload-*/archive";
        is(scalar @backups, 1, 'backup retained during metadata write');
        is(path($backups[0])->slurp, 'old archive', 'backup is the previous file');
        return 'committed';
    }, sub { die 'unexpected rollback' });
    is($result, 'committed', 'commit result returned');
    is_deeply([glob "$dir/.lrr-upload-*"], [], 'backup removed after commit');
};

subtest 'failed rollback retains the recoverable old copy' => sub {
    my ($dir, $old, $staged) = fixture();
    no warnings 'redefine';
    local *LANraragi::Utils::UploadCommit::rename_path = sub {
        my ($from, $to) = @_;
        return 0 if $from =~ /\/archive$/;
        return CORE::rename($from, $to);
    };
    eval { LANraragi::Utils::UploadCommit::publish($staged, $old, $old, sub { die "DB failure\n" }, sub {}); };
    like($@, qr/Rollback requires recovery/, 'recovery requirement is explicit');
    my @backups = glob "$dir/.lrr-upload-*/archive";
    is(path($backups[0])->slurp, 'old archive', 'old bytes remain recoverable');
};

done_testing();
