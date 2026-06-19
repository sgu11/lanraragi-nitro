use strict;
use warnings;
use v5.36;
use Test::More;
use Cwd qw(getcwd);
use Mojo::JSON qw(decode_json encode_json);

my $cwd = getcwd();
require "$cwd/tests/mocks.pl";
setup_redis_mock();

use_ok('LANraragi::Model::Dedup::ReviewLog');

package ReviewLogTestData {
    our %hash;
    our @events;
    our $seq = 0;
    our @incr_seen;
    our @rpush_seen;
    our @lrange_seen;
    our @llen_seen;
}

package ReviewLogRedis {
    sub new { bless {}, shift }
    sub hget {
        my ($self, $key, $field) = @_;
        return $ReviewLogTestData::hash{$key}{$field};
    }
    sub hmget {
        my $self = shift;
        my $cb = ref($_[-1]) eq 'CODE' ? pop @_ : undef;
        my ($key, @fields) = @_;
        my @values = map { $ReviewLogTestData::hash{$key}{$_} // '' } @fields;
        $cb->(\@values, undef) if $cb;
        return \@values;
    }
    sub incr {
        my ($self, $key) = @_;
        push @ReviewLogTestData::incr_seen, $key;
        $ReviewLogTestData::seq++;
        return $ReviewLogTestData::seq;
    }
    sub rpush {
        my ($self, $key, $value) = @_;
        push @ReviewLogTestData::rpush_seen, [$key, $value];
        push @ReviewLogTestData::events, $value;
        return scalar @ReviewLogTestData::events;
    }
    sub lrange {
        my ($self, $key, $start, $stop) = @_;
        push @ReviewLogTestData::lrange_seen, [$key, $start, $stop];
        return () unless @ReviewLogTestData::events;
        $stop = $#ReviewLogTestData::events if $stop < 0 || $stop > $#ReviewLogTestData::events;
        return () if $start > $#ReviewLogTestData::events;
        return @ReviewLogTestData::events[$start .. $stop];
    }
    sub llen {
        my ($self, $key) = @_;
        push @ReviewLogTestData::llen_seen, $key;
        return scalar @ReviewLogTestData::events;
    }
    sub wait_all_responses { 1 }
    sub quit { 1 }
}

package main;

sub reset_state {
    %ReviewLogTestData::hash = ();
    @ReviewLogTestData::events = ();
    $ReviewLogTestData::seq = 0;
    @ReviewLogTestData::incr_seen = ();
    @ReviewLogTestData::rpush_seen = ();
    @ReviewLogTestData::lrange_seen = ();
    @ReviewLogTestData::llen_seen = ();
}

note("canonical pair validation");
{
    is(
        LANraragi::Model::Dedup::ReviewLog::canonical_pair(('b' x 40) . '|' . ('a' x 40)),
        ('a' x 40) . '|' . ('b' x 40),
        "canonical_pair sorts pair members"
    );
    is(
        LANraragi::Model::Dedup::ReviewLog::canonical_pair('bad'),
        undef,
        "canonical_pair rejects malformed members"
    );
    is(
        LANraragi::Model::Dedup::ReviewLog::canonical_pair(('B' x 40) . '|' . ('a' x 40)),
        ('a' x 40) . '|' . ('b' x 40),
        "canonical_pair accepts uppercase hex and lowercases sorted members"
    );
    is(
        LANraragi::Model::Dedup::ReviewLog::canonical_pair(('a' x 40) . '|' . ('a' x 40)),
        undef,
        "canonical_pair rejects self-pairs"
    );
    is(
        LANraragi::Model::Dedup::ReviewLog::canonical_pair(('A' x 40) . '|' . ('a' x 40)),
        undef,
        "canonical_pair rejects self-pairs after lowercasing"
    );
}

note("records review decision with snapshots and pair features");
reset_state();
{
    my $redis = ReviewLogRedis->new;
    my $redis_cfg = ReviewLogRedis->new;
    my $id_a = 'a' x 40;
    my $id_b = 'b' x 40;
    my $pair = "$id_a|$id_b";

    $ReviewLogTestData::hash{'LRR_COVER_DUPLICATE_PAIR_META'}{$pair} = encode_json({
        pass => 'cover',
        cover_hamming => 4,
        cover_algo_version => 2,
        status => 'new',
    });
    $ReviewLogTestData::hash{$id_a}{title} = 'Alpha Korean';
    $ReviewLogTestData::hash{$id_a}{name} = 'alpha.cbz';
    $ReviewLogTestData::hash{$id_a}{tags} = 'artist:a, language:korean, source:gallery_source.la/galleries/123.html';
    $ReviewLogTestData::hash{$id_a}{pagecount} = '100';
    $ReviewLogTestData::hash{$id_a}{arcsize} = '200000000';
    $ReviewLogTestData::hash{$id_a}{coverhash} = 'aaaaaaaaaaaaaaaa';
    $ReviewLogTestData::hash{$id_a}{coverhash_v} = '2';
    $ReviewLogTestData::hash{$id_a}{cover_fp} = encode_json({ w => 1000, h => 1500 });
    $ReviewLogTestData::hash{$id_a}{cover_fp_v} = '3';

    $ReviewLogTestData::hash{$id_b}{title} = 'Alpha English';
    $ReviewLogTestData::hash{$id_b}{name} = 'alpha-en.cbz';
    $ReviewLogTestData::hash{$id_b}{tags} = 'artist:a, language:english, source:gallery_source.la/galleries/123.html';
    $ReviewLogTestData::hash{$id_b}{pagecount} = '98';
    $ReviewLogTestData::hash{$id_b}{arcsize} = '120000000';
    $ReviewLogTestData::hash{$id_b}{coverhash} = 'aaaaaaaabaaaaaaa';
    $ReviewLogTestData::hash{$id_b}{coverhash_v} = '2';
    $ReviewLogTestData::hash{$id_b}{cover_fp} = encode_json({ w => 800, h => 1200 });
    $ReviewLogTestData::hash{$id_b}{cover_fp_v} = '3';

    my $event = LANraragi::Model::Dedup::ReviewLog::record_cover_decision(
        $redis_cfg,
        $redis,
        {
            pair => $pair,
            action_type => 'mark_status',
            label => 'same_cover',
            previous_status => 'new',
            new_status => 'same_cover',
            context => {
                input_method => 'keyboard',
                threshold => 22,
                status_filter => 'new',
                queue_index => 0,
                queue_length => 24,
                dwell_ms => 1500,
                reader_opened_a => 1,
                reader_opened_b => 0,
            },
        }
    );

    is(scalar @ReviewLogTestData::events, 1, "one event appended");
    is($event->{event_id}, 'cover-review-1', "event id includes sequence");
    is($event->{pair}, $pair, "pair stored");
    is($event->{label}, 'same_cover', "label stored");
    is($event->{candidate}{cover_hamming}, 4, "candidate cover hamming captured");
    is($event->{archives}{a}{language}, 'korean', "archive A snapshot captured");
    is($event->{archives}{b}{cover_pixels}, 960000, "archive B cover pixels captured");
    ok($event->{features}{same_source}, "same source derived");
    cmp_ok($event->{features}{pagecount_ratio}, '>', 0.9, "pagecount ratio derived");
    is($event->{context}{reader_opened_b}, 0, "false context booleans are preserved");
    is_deeply(\@ReviewLogTestData::incr_seen, ['LRR_COVER_DUPLICATE_REVIEW_EVENT_SEQ'], "sequence key used for incr");
    is($ReviewLogTestData::rpush_seen[0][0], 'LRR_COVER_DUPLICATE_REVIEW_EVENTS', "events key used for rpush");

    my $decoded = decode_json($ReviewLogTestData::events[0]);
    is($decoded->{event_id}, 'cover-review-1', "stored JSON decodes");
}

note("sanitizes caller-provided context and visible snapshots");
reset_state();
{
    my $redis = ReviewLogRedis->new;
    my $redis_cfg = ReviewLogRedis->new;
    my $id_a = 'c' x 40;
    my $id_b = 'd' x 40;
    my $pair = "$id_a|$id_b";
    my $long = 'x' x 300;

    $ReviewLogTestData::hash{'LRR_COVER_DUPLICATE_PAIR_META'}{$pair} = encode_json({
        pass => 'cover',
        cover_hamming => 7,
        cover_algo_version => 2,
        status => 'new',
    });

    my $event = LANraragi::Model::Dedup::ReviewLog::record_cover_decision(
        $redis_cfg,
        $redis,
        {
            pair => $pair,
            action_type => 'mark_status',
            label => 'same_cover',
            context => {
                input_method => "keyboard-$long",
                threshold => '22',
                status_filter => "new-$long",
                queue_index => 'not numeric',
                queue_length => 24,
                dwell_ms => 1500,
                reader_opened_a => 2,
                reader_opened_b => [],
                nested => { should => 'drop' },
            },
            visible_snapshot => {
                id_a => 'wrong-a',
                id_b => 'wrong-b',
                score => '7',
                cover_hamming => 7,
                pass => "cover-$long",
                status => "new-$long",
                unexpected => 'drop me',
                a => {
                    arcid => 'wrong-archive-a',
                    title => "Visible A $long",
                    name => "visible-a.cbz-$long",
                    tags => "artist:a, language:ko-KR, source:gallery_source.la/galleries/999.html, $long",
                    pagecount => '10',
                    arcsize => '200000',
                    tag_count => '3',
                    language => 'ko-KR',
                    date_added => "2026-06-19-$long",
                    cover_width => '100',
                    cover_height => '200',
                    cover_pixels => '123456789',
                    coverhash => 'drop',
                },
                b => {
                    arcid => 'wrong-archive-b',
                    title => 'Visible B',
                    name => 'visible-b.cbz',
                    tags => 'artist:a, language:english, source:gallery_source.la/galleries/999.html',
                    pagecount => '8',
                    arcsize => '120000',
                    tag_count => '3',
                    language => 'english',
                    date_added => '2026-06-19',
                    cover_width => '80',
                    cover_height => '120',
                    cover_pixels => '9600',
                    extra => 'drop',
                },
            },
        }
    );

    ok(!exists $event->{context}{nested}, "context drops unexpected fields");
    is(length($event->{context}{input_method}), 80, "context strings are bounded");
    is($event->{context}{threshold}, 22, "context numeric fields are normalized");
    ok(!exists $event->{context}{queue_index}, "invalid numeric context fields are omitted");
    is($event->{context}{reader_opened_a}, 1, "true booleans normalize to 1");
    ok(!exists $event->{context}{reader_opened_b}, "non-scalar booleans are omitted");

    is($event->{visible_snapshot}{id_a}, $id_a, "visible snapshot id_a forced to canonical member");
    is($event->{visible_snapshot}{a}{arcid}, $id_a, "visible snapshot archive A arcid forced to canonical member");
    is($event->{visible_snapshot}{b}{arcid}, $id_b, "visible snapshot archive B arcid forced to canonical member");
    ok(!exists $event->{visible_snapshot}{unexpected}, "visible snapshot drops unexpected top-level fields");
    ok(!exists $event->{visible_snapshot}{a}{coverhash}, "visible archive brief drops unexpected fields");
    is(length($event->{visible_snapshot}{a}{title}), 256, "visible archive title is bounded");
    is($event->{archives}{a}{arcid}, $id_a, "visible fallback archive A arcid forced to canonical member");
    is($event->{archives}{b}{arcid}, $id_b, "visible fallback archive B arcid forced to canonical member");
    ok($event->{features}{has_korean_side}, "ko-* languages count as Korean");
}

note("sanitizes top-level fields and maps reversed visible archives");
reset_state();
{
    my $redis = ReviewLogRedis->new;
    my $redis_cfg = ReviewLogRedis->new;
    my $id_a = '1' x 40;
    my $id_b = '2' x 40;
    my $pair = "$id_a|$id_b";
    my $submitted_pair = "$id_b|$id_a";
    my $long = 'z' x 300;

    $ReviewLogTestData::hash{'LRR_COVER_DUPLICATE_PAIR_META'}{$pair} = encode_json({
        pass => 'cover',
        cover_hamming => 9,
        cover_algo_version => 2,
        status => 'new',
    });

    my $event = LANraragi::Model::Dedup::ReviewLog::record_cover_decision(
        $redis_cfg,
        $redis,
        {
            pair => $submitted_pair,
            event_type => "event-$long",
            action_type => "action-$long",
            label => "label-$long",
            previous_status => [],
            new_status => "same_cover-$long",
            action_error => "error-$long",
            kept_archive_id => 'A' x 40,
            deleted_archive_id => 'not-an-id',
            visible_snapshot => {
                a => { arcid => $id_b, title => 'Visible B' },
                b => { arcid => $id_a, title => 'Visible A' },
            },
        }
    );

    is($event->{pair}, $pair, "reversed pair is stored canonically");
    is(length($event->{event_type}), 80, "event_type is bounded");
    is(length($event->{action_type}), 80, "action_type is bounded");
    is(length($event->{label}), 80, "label is bounded");
    ok(!defined $event->{previous_status}, "non-scalar previous status is omitted");
    is(length($event->{new_status}), 80, "new_status is bounded");
    is(length($event->{action_error}), 256, "action_error is bounded");
    is($event->{kept_archive_id}, 'a' x 40, "kept archive id is normalized");
    ok(!defined $event->{deleted_archive_id}, "invalid deleted archive id is omitted");
    is($event->{visible_snapshot}{a}{title}, 'Visible A', "visible archive A is mapped by arcid");
    is($event->{visible_snapshot}{b}{title}, 'Visible B', "visible archive B is mapped by arcid");
    is($event->{archives}{a}{title}, 'Visible A', "archive fallback A uses mapped visible archive");
    is($event->{archives}{b}{title}, 'Visible B', "archive fallback B uses mapped visible archive");
}

note("preserves JSON boolean context fields");
reset_state();
{
    my $redis = ReviewLogRedis->new;
    my $redis_cfg = ReviewLogRedis->new;
    my $id_a = 'e' x 40;
    my $id_b = 'f' x 40;
    my $pair = "$id_a|$id_b";
    my $context = decode_json('{"reader_opened_a": true, "reader_opened_b": false}');

    $ReviewLogTestData::hash{'LRR_COVER_DUPLICATE_PAIR_META'}{$pair} = encode_json({
        pass => 'cover',
        cover_hamming => 5,
        cover_algo_version => 2,
        status => 'new',
    });

    my $event = LANraragi::Model::Dedup::ReviewLog::record_cover_decision(
        $redis_cfg,
        $redis,
        {
            pair => $pair,
            action_type => 'mark_status',
            label => 'same_cover',
            action_success => 0,
            context => $context,
        }
    );

    ok($event->{context}{reader_opened_a}, "JSON true context remains truthy");
    ok(!$event->{context}{reader_opened_b}, "JSON false context remains falsey");
    like($ReviewLogTestData::events[-1], qr/"reader_opened_a":true/, "JSON true context serializes as true");
    like($ReviewLogTestData::events[-1], qr/"reader_opened_b":false/, "JSON false context serializes as false");
    like($ReviewLogTestData::events[-1], qr/"action_success":false/, "action_success serializes as JSON boolean");
}

note("exports event pages");
{
    my $redis_cfg = ReviewLogRedis->new;
    my $page = LANraragi::Model::Dedup::ReviewLog::review_events($redis_cfg, { offset => 0, limit => 10 });
    is($page->{total}, 1, "total count returned");
    is(scalar @{$page->{events}}, 1, "one event exported");
    is_deeply($ReviewLogTestData::lrange_seen[-1], ['LRR_COVER_DUPLICATE_REVIEW_EVENTS', 0, 9], "events key used for lrange");
    is($ReviewLogTestData::llen_seen[-1], 'LRR_COVER_DUPLICATE_REVIEW_EVENTS', "events key used for llen");
}

note("exports corrupt events with decode marker");
reset_state();
{
    my $redis_cfg = ReviewLogRedis->new;
    push @ReviewLogTestData::events, '{not-json' . ('x' x 2000);
    my $page = LANraragi::Model::Dedup::ReviewLog::review_events($redis_cfg, { offset => 0, limit => 10 });
    is($page->{events}[0]{decode_error}, 1, "corrupt event is marked as decode error");
    cmp_ok(length($page->{events}[0]{raw}), '<=', 1000, "corrupt raw event is bounded");
}

done_testing();
