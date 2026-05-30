package LANraragi::Model::Dedup;

use v5.36;
use strict;
use warnings;

use LANraragi::Utils::PHash qw(hamming_hex);
use LANraragi::Utils::String qw(clean_title trim);
use String::Similarity;

# Page-count-delta weight in the score formula. 20 means a 100% page-count
# mismatch contributes 20 to the score.
use constant PCOUNT_WEIGHT => 20;

my %STABLE_TAG_NS = map { $_ => 1 } qw(artist group parody character series language);

sub normalize_title_for_dedup {
    my ($title) = @_;
    $title = lc(trim($title // ''));
    $title =~ s/\.[a-z0-9]{2,5}\z//i;
    $title =~ s/\[[^\]]*\]//g;
    $title =~ s/\([Cc]\d+[^)]*\)//g;
    $title =~ s/\b(?:dl|digital|scan|scanned|korean|english|japanese|raw|translated)\b//ig;
    $title =~ s/\b(?:e[- ]?gallery source|gallery_source|gallery_source|gallery_source)\b[\w:\/.-]*//ig;
    $title =~ s/[_.,;:|+~!-]+/ /g;
    $title =~ s/\s+/ /g;
    return trim(clean_title($title));
}

sub work_key_for_dedup {
    my ($title) = @_;
    my $key = normalize_title_for_dedup($title);
    $key =~ s/\b(?:ch(?:apter)?|vol(?:ume)?|episode|ep)\s*\d+\b//ig;
    $key =~ s/\b\d+\z//;
    $key =~ s/\s+/ /g;
    return trim($key);
}

sub dedup_source_key_from_tags {
    my ($tags) = @_;
    $tags //= '';
    return "gallery_source:$1" if $tags =~ m{source:\s*https?://(?:gallery_source|gallery_source)\.org/g/(\d+)/}i;
    return "gallery_source:$1" if $tags =~ m{source:\s*(?:gallery_source|gallery_source)\.org/g/(\d+)/}i;
    return "gallery_source:$1" if $tags =~ m{source:\s*https?://gallery_source\.net/g/(\d+)}i;
    return "gallery_source:$1" if $tags =~ m{source:\s*gallery_source\.net/g/(\d+)}i;
    return "gallery_source:$1"  if $tags =~ m{source:\s*https?://gallery_source\.la/[^,]*?(\d+)\.html}i;
    return "gallery_source:$1"  if $tags =~ m{source:\s*gallery_source\.la/[^,]*?(\d+)\.html}i;
    return '';
}

sub dedup_language_from_tags {
    my ($tags) = @_;
    $tags //= '';
    return lc(trim($1)) if $tags =~ /(?:^|,)\s*language:\s*([^,]+)/i;
    return '';
}

sub dedup_stable_tags {
    my ($tags) = @_;
    $tags //= '';
    my @stable;
    for my $tag (split /,/, lc($tags)) {
        $tag = trim($tag);
        next unless $tag =~ /^([^:]+):(.+)$/;
        push @stable, $tag if $STABLE_TAG_NS{$1};
    }
    return sort @stable;
}

sub title_similarity_for_dedup {
    my ($a, $b) = @_;
    return 0 if !length($a // '') || !length($b // '');
    return similarity($a, $b) + 0;
}

sub quality_proxy {
    my ($archive) = @_;
    my $pagecount = ($archive->{pagecount} // $archive->{n} // 0) + 0;
    my $arcsize   = ($archive->{arcsize}   // 0) + 0;
    return 0 if $pagecount <= 0;
    return int($arcsize / $pagecount);
}

# Returns the list of zero-based page indices to sample for an archive of $n
# pages, asking for $k samples. Cell-center sampling: int(n*(i+0.5)/k), then
# clamped to [0, n-1] and deduplicated while preserving order. Returns
# fewer than $k entries when $n < $k.
sub pick_spaced {
    my ($n, $k) = @_;
    return () if $n <= 0 || $k <= 0;

    my @seen;
    my @out;
    for my $i (0 .. $k - 1) {
        my $pos = int($n * ($i + 0.5) / $k);
        $pos = 0      if $pos < 0;
        $pos = $n - 1 if $pos >= $n;
        next if $seen[$pos]++;
        push @out, $pos;
    }
    return @out;
}

# Scores a candidate pair. Each archive is a hashref:
#   { hashes => [ "<16-hex>" or "-", ... ], n => <page count> }
# Returns ($score, \@per_page_distances, $page_count_delta_abs).
# Slots where either side is sentinel "-" are skipped. If no valid slots
# remain, mean_hamming = 64 (treat as fully dissimilar).
sub score_pair {
    my ($a, $b) = @_;
    my $n_a = $a->{n};
    my $n_b = $b->{n};

    my $hashes_a = $a->{hashes} // [];
    my $hashes_b = $b->{hashes} // [];
    my $k = (@$hashes_a < @$hashes_b) ? scalar(@$hashes_a) : scalar(@$hashes_b);

    my @per_page;
    my $total = 0;
    my $valid = 0;
    for my $i (0 .. $k - 1) {
        my $ha = $hashes_a->[$i];
        my $hb = $hashes_b->[$i];
        next if !defined $ha || !defined $hb || $ha eq '-' || $hb eq '-';
        my $d = hamming_hex($ha, $hb);
        push @per_page, $d;
        $total += $d;
        $valid++;
    }

    return (64 + PCOUNT_WEIGHT, [], abs($n_a - $n_b)) if $valid == 0;
    my $mean_hamming = $total / $valid;
    my $max_n = ($n_a > $n_b) ? $n_a : $n_b;
    my $pcount_delta_abs = abs($n_a - $n_b);
    my $pcount_delta_frac = $max_n > 0 ? $pcount_delta_abs / $max_n : 0;

    my $score = $mean_hamming + PCOUNT_WEIGHT * $pcount_delta_frac;
    return ($score, \@per_page, $pcount_delta_abs);
}

use LANraragi::Utils::Path    qw(get_archive_path);
use LANraragi::Utils::Archive qw(get_filelist);
use LANraragi::Utils::PHash   qw(compute_phash_64);
use File::Temp qw(tempdir);
use File::Path qw();

# Indirection seams so tests can stub side effects without an archive on disk.
sub _get_archive_path { LANraragi::Utils::Path::get_archive_path(@_) }
# Force-refresh the pagefiles cache when computing pHashes. The cache stored in
# Redis can drift if an archive file was replaced without HDEL'ing pagefiles
# (we have observed cached lists pointing at filenames that no longer exist
# inside the archive); force=1 rewalks the archive and rewrites the cache.
sub _get_filelist     { my @list = LANraragi::Utils::Archive::get_filelist($_[0], $_[1], 1); return @list }
# extract_single_file returns content bytes, not a path; pHash needs a path.
# Use extract_single_file_to_file into a per-call tempdir. Returns
# ($file_path, $dir) so the caller can remove both — leaving the dir
# behind on a long-lived Minion worker leaks ~5 dirs per archive.
sub _extract_page {
    my ($archive, $page) = @_;
    my $dir = tempdir(CLEANUP => 0);
    my $file = LANraragi::Utils::Archive::extract_single_file_to_file($archive, $page, $dir);
    return ($file, $dir);
}
sub _unlink_temp {
    my ($file, $dir) = @_;
    unlink $file if $file && -e $file;
    File::Path::remove_tree($dir) if $dir && -d $dir;
}
sub _compute_phash    { LANraragi::Utils::PHash::compute_phash_64(@_) }

sub _valid_hash {
    my ($hash) = @_;
    return defined $hash && $hash =~ /\A[0-9a-f]{16}\z/i;
}

# Computes pHashes for $id and writes them to Redis. Idempotent.
# $config is { algo_version => N, pages_sampled => K }.
# Behavior:
#   - If pagehashes_v already equals algo_version, returns 0 (no work).
#   - On full success: writes pagehashes / pagehashes_v / pagehashes_n, clears pagehashes_err.
#   - On per-slot failure: that slot becomes "-".
#   - On total failure: writes pagehashes_err = "<algo>:<reason>" and returns -1.
sub compute_pagehashes_for_archive {
    my ($redis, $id, $config) = @_;
    my $algo = $config->{algo_version} // 1;
    my $k    = $config->{pages_sampled} // 5;

    my $existing_v = $redis->hget($id, "pagehashes_v");
    return 0 if defined $existing_v && $existing_v eq $algo;

    my $file = _get_archive_path($redis, $id);
    unless ($file && -e $file) {
        $redis->hset($id, "pagehashes_err", "$algo:archive_missing");
        return -1;
    }

    my @filelist = _get_filelist($file, $id);
    my $n = scalar @filelist;
    if ($n == 0) {
        $redis->hset($id, "pagehashes_err", "$algo:empty_archive");
        return -1;
    }

    my @positions = pick_spaced($n, $k);
    my @hashes;
    my $any_success = 0;
    for my $pos (@positions) {
        my $page = $filelist[$pos];
        my ($extracted, $extracted_dir);
        my $hash;
        eval {
            ($extracted, $extracted_dir) = _extract_page($file, $page);
            $hash = _compute_phash($extracted);
        };
        if ($@ || !$hash) {
            push @hashes, "-";
        } else {
            push @hashes, $hash;
            $any_success = 1;
        }
        _unlink_temp($extracted, $extracted_dir) if $extracted || $extracted_dir;
    }

    while (scalar(@hashes) < $k) {
        push @hashes, "-";
    }

    unless ($any_success) {
        $redis->hset($id, "pagehashes_err", "$algo:all_extractions_failed");
        return -1;
    }

    $redis->hmset($id, "pagehashes", join(' ', @hashes), "pagehashes_v", $algo, "pagehashes_n", $n);
    $redis->hdel($id, "pagehashes_err");
    return 1;
}

use Mojo::JSON qw(encode_json);

# ---------------------------------------------------------------------------
# Cover-only pass.
#
# The pcount-based sweep above never scores pairs that fall outside the page-
# count tolerance window — by design, since "same archive" implies similar
# page count. But a chapter release vs. the bound tankoubon, or any
# release/scan with a wildly different chapter split, has the same cover art
# and we still want them surfaced for review.
#
# This pass stores a single pHash of page 0 as `coverhash` per archive and
# does an O(N^2) sweep keyed only on cover similarity. Pairs land in the
# same LRR_DUPLICATE_PAIRS zset (so the existing UI surfaces them) with
# score = raw Hamming distance (0..64) and meta `pass => 'cover'` so the
# UI/API can differentiate from the pcount-based pass.
# ---------------------------------------------------------------------------

# Computes the cover pHash for $id and writes it to Redis. Idempotent.
# $config is { cover_algo_version => N }.
# Behavior mirrors compute_pagehashes_for_archive:
#   - skip if coverhash_v already matches
#   - on success: write coverhash / coverhash_v, clear coverhash_err
#   - on failure: write coverhash_err = "<algo>:<reason>", return -1
sub compute_coverhash_for_archive {
    my ($redis, $id, $config) = @_;
    my $algo = $config->{cover_algo_version} // 1;

    my $existing_v = $redis->hget($id, "coverhash_v");
    return 0 if defined $existing_v && $existing_v eq $algo;

    my $file = _get_archive_path($redis, $id);
    unless ($file && -e $file) {
        $redis->hset($id, "coverhash_err", "$algo:archive_missing");
        return -1;
    }

    my @filelist = _get_filelist($file, $id);
    my $n = scalar @filelist;
    if ($n == 0) {
        $redis->hset($id, "coverhash_err", "$algo:empty_archive");
        return -1;
    }

    my ($extracted, $extracted_dir);
    my $hash;
    eval {
        ($extracted, $extracted_dir) = _extract_page($file, $filelist[0]);
        $hash = _compute_phash($extracted);
    };
    my $err = $@;
    _unlink_temp($extracted, $extracted_dir) if $extracted || $extracted_dir;

    if ($err || !$hash) {
        $redis->hset($id, "coverhash_err", "$algo:extract_failed");
        return -1;
    }

    $redis->hmset($id, "coverhash", $hash, "coverhash_v", $algo);
    $redis->hdel($id, "coverhash_err");
    return 1;
}

sub lead_hamming {
    my ($a_hashes, $b_hashes) = @_;
    my $best;
    for my $ha (@{ $a_hashes // [] }) {
        next unless _valid_hash($ha);
        for my $hb (@{ $b_hashes // [] }) {
            next unless _valid_hash($hb);
            my $d = hamming_hex($ha, $hb);
            $best = $d if !defined($best) || $d < $best;
        }
    }
    return defined($best) ? $best : 65;
}

sub compute_leadhashes_for_archive {
    my ($redis, $id, $config) = @_;
    my $algo = $config->{lead_algo_version} // 2;
    my $k    = $config->{lead_pages_sampled} // 3;
    $k = 1 if $k <= 0;

    my $existing_v = $redis->hget($id, "lead_hashes_v");
    return 0 if defined $existing_v && $existing_v eq $algo;

    my $file = _get_archive_path($redis, $id);
    unless ($file && -e $file) {
        $redis->hset($id, "lead_hashes_err", "$algo:archive_missing");
        return -1;
    }

    my @filelist = _get_filelist($file, $id);
    if (!@filelist) {
        $redis->hset($id, "lead_hashes_err", "$algo:empty_archive");
        return -1;
    }

    my $last = $#filelist < $k - 1 ? $#filelist : $k - 1;
    my @hashes;
    for my $page (@filelist[0 .. $last]) {
        my ($extracted, $extracted_dir);
        my $hash;
        eval {
            ($extracted, $extracted_dir) = _extract_page($file, $page);
            $hash = _compute_phash($extracted);
        };
        push @hashes, (_valid_hash($hash) ? lc($hash) : "-");
        _unlink_temp($extracted, $extracted_dir) if $extracted || $extracted_dir;
    }

    my @valid = grep { _valid_hash($_) } @hashes;
    unless (@valid) {
        $redis->hset($id, "lead_hashes_err", "$algo:all_extractions_failed");
        return -1;
    }

    $redis->hmset($id, "lead_hashes", join(' ', @hashes), "lead_hashes_v", $algo, "lead_hashes_n", scalar(@valid));
    $redis->hdel($id, "lead_hashes_err");
    return 1;
}

# Pure matcher driver for the cover-only pass.
#
# %cover_data maps id -> "<16-hex>" cover hash.
#
# $config recognized keys:
#   cover_max_hamming   - inclusive cap on Hamming distance for storage
#                         (default 12)
#   candidate_pair_cap  - hard cap on comparisons per run before truncating
#                         (default 10_000_000)
#   cover_algo_version  - stamped into pair meta
#   cur_i, cur_j        - resume position in the upper-triangle sweep
#   target_pairs        - stop after this many *new* pairs are stored
#                         (0/undef = exhaust the sweep)
#
# Pairs already in LRR_DUPLICATE_PAIRS or LRR_DEDUP_DISMISSED are skipped —
# the pcount-based pass and this pass share the same store, and whoever
# scored a pair first wins. Cross-pass overlap is rare by construction
# (this pass only fires on pairs the pcount window excludes), so first-
# writer-wins keeps the integration simple.
#
# Returns: { stored, candidates, truncated, cur_i, cur_j, sweep_done }.
sub find_cover_duplicate_pairs_in_memory {
    my ($cover_data, $redis, $config) = @_;
    my $max_hamming  = $config->{cover_max_hamming}     // 12;
    my $cap          = $config->{candidate_pair_cap}    // 10_000_000;
    my $algo         = $config->{cover_algo_version}    // 1;
    my $start_i      = $config->{cur_i}                 // 0;
    my $start_j      = $config->{cur_j}                 // 0;
    my $target_pairs = $config->{target_pairs}          // 0;

    # Stable id order so cursor resumes mean what they meant last run.
    my @ids = sort keys %$cover_data;
    my $n_total = scalar @ids;

    $start_i = 0 if $start_i >= $n_total;

    my $stored          = 0;
    my $candidates_seen = 0;
    my $truncated       = 0;
    my $cur_i           = $n_total;
    my $cur_j           = 0;

    OUTER: for (my $i = $start_i; $i < $n_total; $i++) {
        my $hash_i = $cover_data->{$ids[$i]};
        my $j_begin = ($i == $start_i && $start_j > $i) ? $start_j : $i + 1;

        for (my $j = $j_begin; $j < $n_total; $j++) {
            if ($candidates_seen >= $cap) {
                $truncated = 1;
                $cur_i = $i; $cur_j = $j;
                last OUTER;
            }
            $candidates_seen++;

            my ($a, $b) = sort ($ids[$i], $ids[$j]);
            my $member = "$a|$b";
            next if $redis->sismember("LRR_DEDUP_DISMISSED", $member);
            next if defined $redis->zscore("LRR_DUPLICATE_PAIRS", $member);

            my $d = hamming_hex($hash_i, $cover_data->{$ids[$j]});
            next if $d > $max_hamming;

            $redis->zadd("LRR_DUPLICATE_PAIRS", $d, $member);
            $redis->hset("LRR_DUPLICATE_PAIR_META", $member,
                encode_json({
                    pass               => 'cover',
                    cover_hamming      => $d,
                    cover_algo_version => $algo,
                    ts                 => time(),
                }));
            $stored++;

            if ($target_pairs && $stored >= $target_pairs) {
                $cur_i = $i; $cur_j = $j + 1;
                last OUTER;
            }
        }
    }

    return {
        stored     => $stored,
        candidates => $candidates_seen,
        truncated  => $truncated,
        cur_i      => $cur_i,
        cur_j      => $cur_j,
        sweep_done => ($cur_i >= $n_total ? 1 : 0),
    };
}

# Pure matcher driver: takes pre-loaded %page_data instead of fetching from
# Redis, so the algorithm can be unit-tested without I/O. The Minion task
# wraps this with the Redis-side gather and cursor persistence.
#
# %page_data maps id -> { hashes => [...], n => N }.
#
# $config recognized keys:
#   loose_max_score, pcount_tolerance_pct, candidate_pair_cap, algo_version
#   cur_i, cur_j        - resume position in the sliding window (0,0 = start)
#   target_pairs        - stop after this many *new* pairs are stored
#                         (0 or undef = no cap, exhaust the sweep)
#
# Returns: { stored, candidates, truncated, cur_i, cur_j, sweep_done }.
# Caller persists cur_i/cur_j and resets to 0 when sweep_done is true.
sub find_duplicate_pairs_in_memory {
    my ($page_data, $redis, $config) = @_;
    my $loose_max    = $config->{loose_max_score}      // 40;
    my $tol_pct      = $config->{pcount_tolerance_pct} // 20;
    my $cap          = $config->{candidate_pair_cap}   // 10_000_000;
    my $algo         = $config->{algo_version}         // 1;
    my $start_i      = $config->{cur_i}                // 0;
    my $start_j      = $config->{cur_j}                // 0;
    my $target_pairs = $config->{target_pairs}         // 0;
    my $tolerance    = $tol_pct / 100.0;

    my @ids = sort { $page_data->{$a}{n} <=> $page_data->{$b}{n} } keys %$page_data;
    my $n_total = scalar @ids;

    # Stale cursor (e.g. archives deleted) — restart from beginning.
    $start_i = 0 if $start_i >= $n_total;

    my $stored          = 0;
    my $candidates_seen = 0;
    my $truncated       = 0;
    my $cur_i           = $n_total;   # default = sweep complete
    my $cur_j           = 0;

    OUTER: for (my $i = $start_i; $i < $n_total; $i++) {
        my $n_i = $page_data->{$ids[$i]}{n};
        my $upper_bound = $n_i * (1 + $tolerance);
        my $j_begin = ($i == $start_i && $start_j > $i) ? $start_j : $i + 1;

        for (my $j = $j_begin; $j < $n_total; $j++) {
            my $n_j = $page_data->{$ids[$j]}{n};
            last if $n_j > $upper_bound;

            if ($candidates_seen >= $cap) {
                $truncated = 1;
                $cur_i = $i; $cur_j = $j;
                last OUTER;
            }
            $candidates_seen++;

            my ($a, $b) = sort ($ids[$i], $ids[$j]);
            my $member = "$a|$b";
            next if $redis->sismember("LRR_DEDUP_DISMISSED", $member);
            next if defined $redis->zscore("LRR_DUPLICATE_PAIRS", $member);

            my ($score, $per_page, $pcount_delta) =
                score_pair($page_data->{$a}, $page_data->{$b});
            next if $score > $loose_max;

            $redis->zadd("LRR_DUPLICATE_PAIRS", $score, $member);
            $redis->hset("LRR_DUPLICATE_PAIR_META", $member,
                encode_json({
                    per_page     => $per_page,
                    pcount_delta => $pcount_delta,
                    algo_version => $algo,
                    ts           => time(),
                }));
            $stored++;

            if ($target_pairs && $stored >= $target_pairs) {
                $cur_i = $i; $cur_j = $j + 1;
                last OUTER;
            }
        }
    }

    return {
        stored     => $stored,
        candidates => $candidates_seen,
        truncated  => $truncated,
        cur_i      => $cur_i,
        cur_j      => $cur_j,
        sweep_done => ($cur_i >= $n_total ? 1 : 0),
    };
}

1;
