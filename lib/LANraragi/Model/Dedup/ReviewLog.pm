package LANraragi::Model::Dedup::ReviewLog;

use v5.36;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
    canonical_pair
    record_cover_decision
    review_events
);

use Mojo::JSON qw(decode_json encode_json);
use POSIX qw(strftime);

use LANraragi::Model::Dedup ();
use LANraragi::Utils::PHash qw(hamming_hex);
use LANraragi::Utils::Redis qw(redis_decode);

use constant EVENTS_KEY     => 'LRR_COVER_DUPLICATE_REVIEW_EVENTS';
use constant SEQ_KEY        => 'LRR_COVER_DUPLICATE_REVIEW_EVENT_SEQ';
use constant PAIR_META_KEY  => 'LRR_COVER_DUPLICATE_PAIR_META';
use constant SCHEMA_VERSION => 1;

sub canonical_pair {
    my ($pair) = @_;
    return undef unless defined $pair && $pair =~ /\A([0-9a-f]{40})\|([0-9a-f]{40})\z/;
    my ($a, $b) = sort ($1, $2);
    return "$a|$b";
}

sub _split_pair {
    my ($pair) = @_;
    my $canonical = canonical_pair($pair);
    return unless defined $canonical;
    return split /\|/, $canonical, 2;
}

sub _now_iso8601 {
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
}

sub _json_hash {
    my ($json) = @_;
    my $decoded = eval { decode_json($json // '{}') } // {};
    return ref $decoded eq 'HASH' ? $decoded : {};
}

sub _num_or_zero {
    my ($value) = @_;
    return 0 unless defined $value && "$value" =~ /\A\d+(?:\.\d+)?\z/;
    return $value + 0;
}

sub _tag_list {
    my ($tags) = @_;
    return @$tags if ref $tags eq 'ARRAY';
    $tags //= '';
    return grep { /\S/ } map {
        my $tag = $_;
        $tag =~ s/^\s+|\s+$//g;
        $tag;
    } split /,/, "$tags";
}

sub _archive_snapshot {
    my ($redis, $id) = @_;
    my @fields = qw(
        title name tags pagecount arcsize
        coverhash coverhash_v cover_fp cover_fp_v
        lead_hashes lead_hashes_v lead_hashes_n
        pagehashes pagehashes_v pagehashes_n
    );
    my $reply = $redis->hmget($id, @fields) // [];
    my %h;
    for my $i (0 .. $#fields) {
        $h{$fields[$i]} = $reply->[$i] // '';
    }

    my $tags = redis_decode($h{tags} // '');
    my $cover_fp = _json_hash($h{cover_fp});
    my $cover_width = _num_or_zero($cover_fp->{w});
    my $cover_height = _num_or_zero($cover_fp->{h});
    my @tags = _tag_list($tags);

    my $language = LANraragi::Model::Dedup::dedup_language_from_tags($tags);
    my $date_added = '';
    for my $tag (@tags) {
        if ($tag =~ /^date_added:\s*(.+)$/i) {
            $date_added = $1;
            last;
        }
    }

    return {
        arcid => $id,
        title => redis_decode($h{title} // ''),
        name => redis_decode($h{name} // ''),
        pagecount => _num_or_zero($h{pagecount}),
        arcsize => _num_or_zero($h{arcsize}),
        tag_count => scalar @tags,
        language => $language,
        date_added => $date_added,
        cover_width => $cover_width,
        cover_height => $cover_height,
        cover_pixels => $cover_width * $cover_height,
        coverhash => $h{coverhash} || undef,
        coverhash_v => $h{coverhash_v} || undef,
        cover_fp_v => $h{cover_fp_v} || undef,
        lead_hashes_n => _num_or_zero($h{lead_hashes_n}),
        pagehashes_n => _num_or_zero($h{pagehashes_n}),
        _tags => $tags,
        _lead_hashes => [ grep { LANraragi::Model::Dedup::_valid_hash($_) } split /\s+/, ($h{lead_hashes} // '') ],
    };
}

sub _snapshot_has_data {
    my ($snapshot) = @_;
    return 1 if length($snapshot->{title} // '') || length($snapshot->{name} // '');
    return 1 if ($snapshot->{pagecount} // 0) > 0 || ($snapshot->{arcsize} // 0) > 0;
    return 1 if ($snapshot->{cover_pixels} // 0) > 0 || ($snapshot->{tag_count} // 0) > 0;
    return 0;
}

sub _with_visible_fallback {
    my ($server, $visible) = @_;
    return $server unless ref $visible eq 'HASH';
    return $server if _snapshot_has_data($server);

    my %merged = %$server;
    for my $field (qw(arcid title name pagecount arcsize tag_count language date_added cover_width cover_height cover_pixels)) {
        $merged{$field} = $visible->{$field} if defined $visible->{$field};
    }
    $merged{cover_pixels} = ($merged{cover_width} // 0) * ($merged{cover_height} // 0)
        if !defined($visible->{cover_pixels}) && defined($visible->{cover_width}) && defined($visible->{cover_height});
    $merged{_tags} = join(', ', _tag_list($visible->{tags})) if defined $visible->{tags};
    return \%merged;
}

sub _strip_private_snapshot_fields {
    my ($snapshot) = @_;
    my %copy = %$snapshot;
    delete $copy{_tags};
    delete $copy{_lead_hashes};
    return \%copy;
}

sub _ratio {
    my ($a, $b) = @_;
    return undef if !$a || !$b;
    my $min = $a < $b ? $a : $b;
    my $max = $a > $b ? $a : $b;
    return undef if $max <= 0;
    return $min / $max;
}

sub _stable_tag_jaccard_from_snapshots {
    my ($a, $b) = @_;
    my %a = map { $_ => 1 } LANraragi::Model::Dedup::dedup_stable_tags($a->{_tags} // '');
    my %b = map { $_ => 1 } LANraragi::Model::Dedup::dedup_stable_tags($b->{_tags} // '');
    my %union = (%a, %b);
    return undef unless %union;
    my $intersection = 0;
    $intersection++ for grep { $b{$_} } keys %a;
    return $intersection / scalar(keys %union);
}

sub _lead_hamming_from_snapshots {
    my ($a, $b) = @_;
    my $best;
    for my $ha (@{ $a->{_lead_hashes} // [] }) {
        for my $hb (@{ $b->{_lead_hashes} // [] }) {
            my $d = hamming_hex($ha, $hb);
            $best = $d if !defined($best) || $d < $best;
        }
    }
    return $best;
}

sub _pair_features {
    my ($a, $b) = @_;
    my $qa = LANraragi::Model::Dedup::quality_proxy($a);
    my $qb = LANraragi::Model::Dedup::quality_proxy($b);
    my $work_a = LANraragi::Model::Dedup::work_key_for_dedup($a->{title} || $a->{name});
    my $work_b = LANraragi::Model::Dedup::work_key_for_dedup($b->{title} || $b->{name});
    my $source_a = LANraragi::Model::Dedup::dedup_source_key_from_tags($a->{_tags} // '');
    my $source_b = LANraragi::Model::Dedup::dedup_source_key_from_tags($b->{_tags} // '');
    my $title_score = eval { LANraragi::Model::Dedup::title_similarity_for_dedup($work_a, $work_b) };

    return {
        pagecount_delta => abs(($a->{pagecount} // 0) - ($b->{pagecount} // 0)),
        pagecount_ratio => _ratio($a->{pagecount}, $b->{pagecount}),
        arcsize_ratio => _ratio($a->{arcsize}, $b->{arcsize}),
        quality_proxy_a => $qa,
        quality_proxy_b => $qb,
        quality_ratio => _ratio($qa, $qb),
        same_language => (length($a->{language} // '') && ($a->{language} // '') eq ($b->{language} // '')) ? 1 : 0,
        has_korean_side => (($a->{language} // '') =~ /\A(?:korean|ko)\z/i || ($b->{language} // '') =~ /\A(?:korean|ko)\z/i) ? 1 : 0,
        title_score => defined $title_score ? $title_score + 0 : undef,
        work_key_a => $work_a,
        work_key_b => $work_b,
        source_key_a => $source_a,
        source_key_b => $source_b,
        same_source => (length($source_a) && length($source_b) && $source_a eq $source_b) ? 1 : 0,
        stable_tag_jaccard => _stable_tag_jaccard_from_snapshots($a, $b),
        lead_hamming => _lead_hamming_from_snapshots($a, $b),
    };
}

sub _candidate_meta {
    my ($redis_cfg, $pair) = @_;
    my $meta = _json_hash($redis_cfg->hget(PAIR_META_KEY, $pair));
    return {
        pass => $meta->{pass} // 'cover',
        score => defined $meta->{cover_hamming} ? $meta->{cover_hamming} + 0 : undef,
        cover_hamming => defined $meta->{cover_hamming} ? $meta->{cover_hamming} + 0 : undef,
        cover_algo_version => $meta->{cover_algo_version},
        status => $meta->{status} // 'new',
        ts => $meta->{ts},
    };
}

sub record_cover_decision {
    my ($redis_cfg, $redis, $args) = @_;
    $args //= {};
    my $pair = canonical_pair($args->{pair});
    die "invalid duplicate review pair\n" unless defined $pair;
    my ($id_a, $id_b) = _split_pair($pair);

    my $seq = $redis_cfg->incr(SEQ_KEY);
    my $visible = ref $args->{visible_snapshot} eq 'HASH' ? $args->{visible_snapshot} : {};
    my $snap_a = _with_visible_fallback(_archive_snapshot($redis, $id_a), $visible->{a});
    my $snap_b = _with_visible_fallback(_archive_snapshot($redis, $id_b), $visible->{b});
    my $event = {
        schema_version => SCHEMA_VERSION,
        event_id => "cover-review-$seq",
        event_type => $args->{event_type} // 'duplicate_review_decision',
        created_at => _now_iso8601(),
        pair => $pair,
        id_a => $id_a,
        id_b => $id_b,
        action_type => $args->{action_type} // 'mark_status',
        label => $args->{label} // $args->{new_status} // '',
        previous_status => $args->{previous_status},
        new_status => $args->{new_status},
        action_success => exists $args->{action_success} ? ($args->{action_success} ? 1 : 0) : 1,
        action_error => $args->{action_error},
        kept_archive_id => $args->{kept_archive_id},
        deleted_archive_id => $args->{deleted_archive_id},
        context => $args->{context} // {},
        candidate => _candidate_meta($redis_cfg, $pair),
        archives => {
            a => _strip_private_snapshot_fields($snap_a),
            b => _strip_private_snapshot_fields($snap_b),
        },
        visible_snapshot => $visible,
        features => _pair_features($snap_a, $snap_b),
    };

    $redis_cfg->rpush(EVENTS_KEY, encode_json($event));
    return $event;
}

sub review_events {
    my ($redis_cfg, $opts) = @_;
    $opts //= {};
    my $offset = ($opts->{offset} // 0) + 0;
    my $limit = ($opts->{limit} // 1000) + 0;
    $offset = 0 if $offset < 0;
    $limit = 1 if $limit < 1;
    $limit = 1000 if $limit > 1000;
    my $stop = $offset + $limit - 1;
    my @raw = $redis_cfg->lrange(EVENTS_KEY, $offset, $stop);
    my @events = map { _json_hash($_) } @raw;
    return {
        events => \@events,
        offset => $offset,
        limit => $limit,
        total => $redis_cfg->llen(EVENTS_KEY) + 0,
    };
}

1;
