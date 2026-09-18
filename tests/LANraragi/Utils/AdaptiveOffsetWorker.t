use v5.36;
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64);
use Mojo::JSON qw(encode_json);
use LANraragi::Utils::AdaptiveOffsetWorker;
use LANraragi::Utils::AdaptiveOffsetClient;

{
    package TestWorker;
    use Mojo::Base 'LANraragi::Utils::AdaptiveOffsetWorker', -signatures;
    sub _native_identity ($self) { return 'fixture' }
    sub _detect_pages ($self, $pages) {
        die "decode_failed\n" if $pages->[0]{index} == 11;
        sleep 5 if $pages->[0]{index} == 10;
        return [map { {page_index => $_->{index}, sha256 => $_->{sha256}, side => 'LEFT', confidence => 0.8, reason => 'edge_complexity', source_width => 100, source_height => 200} } @$pages];
    }
}

my $app = TestWorker->new(detection_timeout => 0.2);
my $t = Test::Mojo->new($app);
my $revision = 'a' x 64;
my $hash = sha256_hex('raster');
my $input = {schema_version => 1, content_revision => $revision,
    pages => [{index => 0, sha256 => $hash, content => encode_base64('raster', '')}]};
$t->get_ok('/health')->status_is(200)->json_is('/algorithm_version', 'lrr-vips320-v1-vote1')->header_is('Cache-Control', 'no-store');
$t->post_ok('/v1/pages' => json => $input)->status_is(200)->json_is('/content_revision', $revision)
  ->json_is('/pages/0/sha256', $hash)->json_is('/pages/0/side', 'LEFT');
$t->post_ok('/v1/pages' => {'Content-Type' => 'text/plain'} => 'x')->status_is(415);
$t->post_ok('/v1/pages' => json => {%$input, path => '/etc/passwd'})->status_is(400);
$t->post_ok('/v1/pages' => json => {%$input, content_revision => 'stale'})->status_is(400);
$t->post_ok('/v1/pages' => json => {%$input, pages => [@{$input->{pages}}, @{$input->{pages}}]})->status_is(400);
for my $bad ('http://example.test/image', 'a===', '', '{}') {
    $t->post_ok('/v1/pages' => json => {%$input, pages => [{%{$input->{pages}[0]}, content => $bad}]})->status_is(400);
}
$t->post_ok('/v1/pages' => json => {%$input, pages => [{%{$input->{pages}[0]}, index => 11}]})->status_is(422)->json_is('/error', 'image_unusable');
$t->post_ok('/v1/pages' => json => {%$input, pages => [{%{$input->{pages}[0]}, index => 10}]})->status_is(504)->json_is('/error', 'worker_timeout');
$t->get_ok('/health')->status_is(200);

my $vote = {schema_version => 1, content_revision => $revision, groups => [{id => 'first', observations => [
    {index => 2, slot => 0, side => 'LEFT', strength => 0.8, sha256 => $hash},
    {index => 3, slot => 1, side => 'RIGHT', strength => 0.8, sha256 => $hash},
]}]};
$t->post_ok('/v1/vote' => json => $vote)->status_is(200)->json_is('/groups/0/side', 'LEFT')->json_is('/groups/0/evidence_indices', [2, 3]);
$vote->{groups}[0]{observations}[1]{strength} = 0.1;
$t->post_ok('/v1/vote' => json => $vote)->status_is(200)->json_is('/groups/0/side', 'UNKNOWN');
$vote->{groups}[0]{observations}[1]{strength} = 'NaN';
$t->post_ok('/v1/vote' => json => $vote)->status_is(400);
$vote->{groups}[0]{observations}[1]{strength} = 0.8;
$vote->{groups}[0]{observations}[1]{slot} = -1;
$t->post_ok('/v1/vote' => json => $vote)->status_is(400);
$t->get_ok('/v1/pages')->status_is(404);

my $metadata = encode_json({schema_version => 1, content_revision => $revision,
    pages => [{index => 0, sha256 => $hash, bytes_count => 6}]});
my $frame = 'AOW1' . pack('N', length($metadata)) . $metadata . 'raster';
my $media = {'Content-Type' => 'application/vnd.adaptive-offset.pages-v1'};
$t->post_ok('/v1/pages' => $media => $frame)->status_is(200)
  ->json_is('/request_sha256', sha256_hex($metadata))->json_is('/pages/0/sha256', $hash);
my ($parsed) = LANraragi::Utils::AdaptiveOffsetWorker::_binary_input($frame);
is($parsed->{pages}[0]{bytes}, 'raster', 'binary frame preserves exact image bytes');
for my $bad ('', 'AOW2' . substr($frame, 4), 'AOW1' . pack('N', 65537),
    substr($frame, 0, -1), $frame . 'extra') {
    $t->post_ok('/v1/pages' => $media => $bad)->status_is(400);
}
for my $length (0, -1, 8 * 1024 * 1024 + 1) {
    my $bad = encode_json({schema_version => 1, content_revision => $revision,
        pages => [{index => 0, sha256 => $hash, bytes_count => $length}]});
    $t->post_ok('/v1/pages' => $media => 'AOW1' . pack('N', length($bad)) . $bad)->status_is(400);
}
my $binary = "\0\xff\x80\n";
my $binary_meta = encode_json({schema_version => 1, content_revision => $revision,
    pages => [{index => 3, sha256 => sha256_hex($binary), bytes_count => length($binary)}]});
my ($binary_parsed) = LANraragi::Utils::AdaptiveOffsetWorker::_binary_input('AOW1' . pack('N', length($binary_meta)) . $binary_meta . $binary);
is($binary_parsed->{pages}[0]{bytes}, $binary, 'binary framing preserves NUL, high bytes and newline');
$t->post_ok('/v1/vote' => $media => $frame)->status_is(415);

my $client = LANraragi::Utils::AdaptiveOffsetClient->new($t->ua->server->url, $t->ua);
is($client->detect_pages([{index => 0, bytes => 'raster'}], $revision)->[0]{side}, 'LEFT', 'Perl client uses and validates worker pages');
$vote->{groups}[0]{observations}[1]{slot} = 1;
is($client->vote_groups($vote->{groups}, $revision)->[0]{side}, 'LEFT', 'Perl client uses worker voting');
eval { $client->detect_pages([{index => 11, bytes => 'raster'}], $revision) };
like($@, qr/worker_unavailable/, 'decode error is not a normal UNKNOWN or fallback');
ok(!exists $INC{'LANraragi/Model/Config.pm'}, 'worker/client never load application config or Redis');
done_testing;
