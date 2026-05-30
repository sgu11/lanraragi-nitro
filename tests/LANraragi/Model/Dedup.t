use strict;
use warnings;
use v5.36;
use Test::More;
use Test::MockObject;

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

note("score_pair: all-sentinel slots return high score (64 + PCOUNT_WEIGHT)");
{
    my $a = { hashes => ["-", "-"], n => 100 };
    my $b = { hashes => ["-", "-"], n => 100 };
    my ($score, $per_page, $delta) = LANraragi::Model::Dedup::score_pair($a, $b);
    is($score, 64 + 20, "all-sentinel score = 64 + PCOUNT_WEIGHT");
    is_deeply($per_page, [], "no per-page distances for sentinel-only pair");
    is($delta, 0, "page count delta is 0");
}

note("compute_pagehashes_for_archive: writes pagehashes/_v/_n and clears _err");
{
    use Test::MockModule qw(strict);
    use Cwd qw(getcwd);

    my $cwd = getcwd();
    require "$cwd/tests/mocks.pl";
    setup_redis_mock();

    # Capture HSET / HDEL calls.
    my @writes;
    my $redis_mock = Test::MockObject->new();
    $redis_mock->mock('hset', sub { shift; push @writes, ['hset', @_]; 1 });
    $redis_mock->mock('hmset', sub { shift; push @writes, ['hmset', @_]; 1 });
    $redis_mock->mock('hdel', sub { shift; push @writes, ['hdel', @_]; 1 });
    $redis_mock->mock('hget', sub { undef });
    $redis_mock->mock('quit', sub { 1 });

    my $dedup_mod = Test::MockModule->new('LANraragi::Model::Dedup');
    $dedup_mod->redefine('_get_archive_path', sub { $0 });
    $dedup_mod->redefine('_get_filelist',     sub { ('p1.jpg','p2.jpg','p3.jpg','p4.jpg','p5.jpg','p6.jpg','p7.jpg','p8.jpg','p9.jpg','pA.jpg') });
    $dedup_mod->redefine('_extract_page',     sub { '/tmp/page_x.jpg' });
    $dedup_mod->redefine('_unlink_temp',      sub { 1 });
    $dedup_mod->redefine('_compute_phash',    sub { 'aaaaaaaaaaaaaaaa' });

    LANraragi::Model::Dedup::compute_pagehashes_for_archive($redis_mock, "abc123", { algo_version => 1, pages_sampled => 5 });

    my %seen;
    for my $write (grep { $_->[0] eq 'hset' } @writes) {
        $seen{ $write->[1] . "|" . $write->[2] } = $write->[3];
    }
    for my $write (grep { $_->[0] eq 'hmset' } @writes) {
        my ($op, $id, @fields) = @$write;
        while (@fields) {
            my ($field, $value) = splice @fields, 0, 2;
            $seen{"$id|$field"} = $value;
        }
    }
    is($seen{"abc123|pagehashes"},   "aaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaa aaaaaaaaaaaaaaaa", "writes 5 hashes");
    is($seen{"abc123|pagehashes_v"}, 1, "writes algo version");
    is($seen{"abc123|pagehashes_n"}, 10, "writes page count");

    my $hdel_seen = grep { $_->[0] eq 'hdel' && $_->[1] eq 'abc123' && $_->[2] eq 'pagehashes_err' } @writes;
    ok($hdel_seen, "clears pagehashes_err on success");
}

note("dedup title normalization and source extraction");
{
    is(
        LANraragi::Model::Dedup::normalize_title_for_dedup(
            "[Circle] My Manga Ch. 01 [Korean] [DL].cbz"
        ),
        "my manga ch 01",
        "normalizes bracket metadata, suffixes, extension, and spacing"
    );

    is(
        LANraragi::Model::Dedup::work_key_for_dedup("My Manga Chapter 12"),
        "my manga",
        "work key strips chapter suffix"
    );

    is(
        LANraragi::Model::Dedup::dedup_source_key_from_tags(
            "artist:a, source:https://gallery_source.org/g/3196863/25acc1dc92/, language:korean"
        ),
        "gallery_source:3196863",
        "extracts EH source id"
    );

    is(
        LANraragi::Model::Dedup::dedup_source_key_from_tags(
            "source:gallery_source.net/g/52249, language:english"
        ),
        "gallery_source:52249",
        "extracts gallery_source source id"
    );

    is(
        LANraragi::Model::Dedup::dedup_language_from_tags("artist:a, language: Korean"),
        "korean",
        "extracts normalized language tag"
    );

    is_deeply(
        [LANraragi::Model::Dedup::dedup_stable_tags("artist:a, temp:x, group:g, language:korean")],
        ["artist:a", "group:g", "language:korean"],
        "keeps only stable tag namespaces for scoring"
    );

    is(
        LANraragi::Model::Dedup::quality_proxy({ arcsize => 104857600, pagecount => 100 }),
        1048576,
        "quality proxy is bytes per page"
    );
}

done_testing();
