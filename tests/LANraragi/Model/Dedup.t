use strict;
use warnings;
use v5.36;
use Test::More;

use_ok('LANraragi::Model::Dedup');

note("pick_spaced: cell-center sampling at int(n*(i+0.5)/k)");
{
    is_deeply([LANraragi::Model::Dedup::pick_spaced(10, 5)],
              [1, 3, 5, 7, 9],
              "n=10, k=5 -> [1,3,5,7,9]");

    is_deeply([LANraragi::Model::Dedup::pick_spaced(20, 5)],
              [2, 6, 10, 14, 18],
              "n=20, k=5 -> [2,6,10,14,18]");

    is_deeply([LANraragi::Model::Dedup::pick_spaced(248, 5)],
              [24, 74, 124, 173, 223],
              "n=248, k=5 -> [24,74,124,173,223]");
}

note("pick_spaced: dedupes when n < k");
{
    is_deeply([LANraragi::Model::Dedup::pick_spaced(4, 5)],
              [0, 1, 2, 3],
              "n=4, k=5 -> [0,1,2,3] (deduped)");
    is_deeply([LANraragi::Model::Dedup::pick_spaced(1, 5)],
              [0],
              "n=1, k=5 -> [0]");
    is_deeply([LANraragi::Model::Dedup::pick_spaced(0, 5)],
              [],
              "n=0, k=5 -> [] (empty archive)");
}

note("score_pair: identical hashes, same page count -> score 0");
{
    my $a = { hashes => ["0000000000000000"], n => 100 };
    my $b = { hashes => ["0000000000000000"], n => 100 };
    my ($score, $per_page, $delta) = LANraragi::Model::Dedup::score_pair($a, $b);
    is($score, 0, "score is 0");
    is_deeply($per_page, [0], "per_page is [0]");
    is($delta, 0, "page count delta is 0");
}

note("score_pair: ignores sentinel slots");
{
    my $a = { hashes => ["ffffffffffffffff", "-"], n => 100 };
    my $b = { hashes => ["ffffffffffffffff", "0000000000000000"], n => 100 };
    my ($score, $per_page, $delta) = LANraragi::Model::Dedup::score_pair($a, $b);
    is($score, 0, "sentinel slot dropped, score from valid slot only");
    is_deeply($per_page, [0], "only one valid pair compared");
}

note("score_pair: page count delta contributes 20 * fraction");
{
    my $a = { hashes => ["0000000000000000"], n => 100 };
    my $b = { hashes => ["0000000000000000"], n => 80 };
    my ($score, undef, $delta) = LANraragi::Model::Dedup::score_pair($a, $b);
    is($delta, 20, "raw delta is 20");
    cmp_ok(abs($score - 4.0), "<", 0.01, "score = 0 + 20 * (20/100) = 4.0");
}

note("score_pair: aggregates Hamming distance across slots");
{
    my $a = { hashes => ["0000000000000000", "0000000000000000", "0000000000000000"], n => 50 };
    my $b = { hashes => ["0000000000000001", "0000000000000001", "0000000000000001"], n => 50 };
    my ($score, $per_page) = LANraragi::Model::Dedup::score_pair($a, $b);
    is_deeply($per_page, [1, 1, 1], "1 bit differs per slot");
    cmp_ok(abs($score - 1.0), "<", 0.01, "mean Hamming = 1, no pcount delta -> score 1");
}

done_testing();
