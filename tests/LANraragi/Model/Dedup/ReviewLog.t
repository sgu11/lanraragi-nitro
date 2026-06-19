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
        $ReviewLogTestData::seq++;
        return $ReviewLogTestData::seq;
    }
    sub rpush {
        my ($self, $key, $value) = @_;
        push @ReviewLogTestData::events, $value;
        return scalar @ReviewLogTestData::events;
    }
    sub lrange {
        my ($self, $key, $start, $stop) = @_;
        return () unless @ReviewLogTestData::events;
        $stop = $#ReviewLogTestData::events if $stop < 0 || $stop > $#ReviewLogTestData::events;
        return () if $start > $#ReviewLogTestData::events;
        return @ReviewLogTestData::events[$start .. $stop];
    }
    sub llen { scalar @ReviewLogTestData::events }
    sub wait_all_responses { 1 }
    sub quit { 1 }
}

package main;

sub reset_state {
    %ReviewLogTestData::hash = ();
    @ReviewLogTestData::events = ();
    $ReviewLogTestData::seq = 0;
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

    my $decoded = decode_json($ReviewLogTestData::events[0]);
    is($decoded->{event_id}, 'cover-review-1', "stored JSON decodes");
}

note("exports event pages");
{
    my $redis_cfg = ReviewLogRedis->new;
    my $page = LANraragi::Model::Dedup::ReviewLog::review_events($redis_cfg, { offset => 0, limit => 10 });
    is($page->{total}, 1, "total count returned");
    is(scalar @{$page->{events}}, 1, "one event exported");
}

done_testing();
