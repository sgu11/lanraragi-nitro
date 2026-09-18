use v5.36;
use strict;
use warnings;
use Test::More;
use Test::MockModule qw(strict);
use Archive::Zip qw(AZ_OK);
use File::Temp qw(tempdir);
use LANraragi::Model::Dedup::ContentVerification;

my $dir = tempdir(CLEANUP => 1);
my $manifest = \&LANraragi::Model::Dedup::ContentVerification::image_manifest;
sub archive {
    my ($name, @entries) = @_;
    my $zip = Archive::Zip->new;
    while (@entries) {
        my ($file, $bytes) = splice @entries, 0, 2;
        $zip->addString($bytes, $file);
    }
    my $path = "$dir/$name.cbz";
    die 'fixture write failed' unless $zip->writeToFileNamed($path) == AZ_OK;
    return $path;
}
my $a = archive('a', '1.jpg' => 'cover', '2.jpg' => 'page', 'info.txt' => 'first');
my $b = archive('b', 'renamed/2.jpg' => 'page', 'renamed/1.jpg' => 'cover', 'info.txt' => 'second');
my $c = archive('c', '1.jpg' => 'cover', '2.jpg' => 'different');
my $ma = $manifest->($a);
is($ma->{pages}, 2, 'counts images, excluding non-image metadata');
is($ma->{bytes}, 9, 'streams exact image byte count');
is($manifest->($b)->{digest}, $ma->{digest}, 'renamed/reordered/repacked identical images match');
isnt($manifest->($c)->{digest}, $ma->{digest}, 'same cover with different inside page does not match');
my $d = archive('d', '1.jpg' => 'A', '2.jpg' => 'A', '3.jpg' => 'B');
my $e = archive('e', '1.jpg' => 'A', '2.jpg' => 'B', '3.jpg' => 'B');
isnt($manifest->($d)->{digest}, $manifest->($e)->{digest}, 'image multiplicity is preserved');
for my $case (
    [$a, {bytes => 4}, qr/byte limit/],
    [$a, {entries => 1}, qr/entry limit/],
    [$a, {seconds => -1}, qr/time limit/],
    [archive('empty', 'info.txt' => 'metadata'), {}, qr/No image pages/],
    [archive('zero', '1.jpg' => ''), {}, qr/Empty image/],
    ["$dir/remote.cbw", {}, qr/manual review/],
) {
    eval { $manifest->($case->[0], $case->[1]) };
    like($@, $case->[2], 'unsupported or bounded work fails closed');
}
my $path_mock = Test::MockModule->new('LANraragi::Utils::Path');
my %paths = (a => $a, b => $b, c => $c);
$path_mock->redefine(get_archive_path => sub { $paths{$_[1]} });
my %cache;
my $same = LANraragi::Model::Dedup::ContentVerification::verify_pair(undef, 'a', 'b', \%cache);
is($same->{state}, 'same_images', 'batch produces an exact image-content flag');
my $different = LANraragi::Model::Dedup::ContentVerification::verify_pair(undef, 'a', 'c', \%cache);
is($different->{state}, 'different_images', 'cover-only similarity cannot prove full image equality');
is(scalar keys %cache, 3, 'shared archive manifests reused within the bounded batch');
ok(!exists $same->{suggested_delete} && !exists $same->{status}, 'verification does not prescribe deletion or replace human labels');
done_testing();
