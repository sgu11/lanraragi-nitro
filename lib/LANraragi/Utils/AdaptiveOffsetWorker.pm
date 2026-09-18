package LANraragi::Utils::AdaptiveOffsetWorker;

use v5.36;
use strict;
use warnings;
use Mojo::Base 'Mojolicious', -signatures;
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(decode_base64 encode_base64);
use Mojo::JSON qw(encode_json decode_json);
use IO::Select;
use POSIX qw(_exit WNOHANG);
use Time::HiRes qw(time);
use LANraragi::Utils::PageSideDetector;
use LANraragi::Utils::AdaptiveOffsetVote;

use constant MAX_IMAGE_BYTES => 8 * 1024 * 1024;
use constant MAX_BODY_BYTES => 48 * 1024 * 1024;
use constant MAX_PAGES => 12;
use constant MAX_PIXELS => 100_000_000;
use constant DETECT_TIMEOUT => 15;
has detection_timeout => DETECT_TIMEOUT;

sub _native_identity ($self) {
    require LANraragi::Utils::Vips;
    die "libvips_required\n" unless LANraragi::Utils::Vips::is_vips_loaded();
    require FFI::Platypus;
    require FFI::CheckLib;
    my $ffi = FFI::Platypus->new(api => 2, lib => FFI::CheckLib::find_lib(lib => ['vips', 'vips-42']));
    return $ffi->function('vips_version_string', [] => 'string')->call;
}

sub startup ($self) {
    my $native_version = $self->_native_identity;
    $self->max_request_size(MAX_BODY_BYTES);
    $self->log->level('warn');
    $self->hook(after_dispatch => sub ($c) { $c->res->headers->cache_control('no-store') });
    $self->routes->get('/health')->to(cb => sub ($c) {
        $c->render(json => {status => 'ready', schema_version => 1,
            algorithm_version => LANraragi::Utils::AdaptiveOffsetVote::ALGORITHM_VERSION,
            source_revision => $ENV{WORKER_SOURCE_REVISION} // 'development', libvips_version => $native_version});
    });
    $self->routes->post('/v1/pages')->to(cb => sub ($c) { $self->_request($c, 'pages') });
    $self->routes->post('/v1/vote')->to(cb => sub ($c) { $self->_request($c, 'vote') });
}

sub _only_keys ($hash, @keys) {
    die "invalid_object\n" unless ref($hash) eq 'HASH';
    my %allowed = map { $_ => 1 } @keys;
    die "unexpected_field\n" if grep { !$allowed{$_} } keys %$hash;
}

sub _uint ($value, $max) {
    return defined $value && !ref($value) && "$value" =~ /\A(?:0|[1-9][0-9]*)\z/ && $value <= $max;
}

sub _hash ($value) { return defined $value && !ref($value) && $value =~ /\A[0-9a-f]{64}\z/ }

sub _validate ($input, $kind, $binary = 0) {
    _only_keys($input, 'schema_version', 'content_revision', $kind eq 'pages' ? 'pages' : 'groups');
    die "invalid_schema\n" unless _uint($input->{schema_version}, 1) && $input->{schema_version} == 1;
    die "invalid_revision\n" unless _hash($input->{content_revision});
    if ($kind eq 'pages') {
        my $pages = $input->{pages};
        die "invalid_pages\n" unless ref($pages) eq 'ARRAY' && @$pages > 0 && @$pages <= MAX_PAGES;
        my %seen;
        for my $page (@$pages) {
            _only_keys($page, 'index', 'sha256', $binary ? 'bytes_count' : 'content');
            die "invalid_page_index\n" unless _uint($page->{index}, 1_000_000) && !$seen{$page->{index}}++;
            die "invalid_image_hash\n" unless _hash($page->{sha256});
            if ($binary) {
                die "invalid_image_length\n" unless _uint($page->{bytes_count}, MAX_IMAGE_BYTES) && $page->{bytes_count} > 0;
                next;
            }
            my $encoded = $page->{content};
            die "invalid_image_content\n" unless defined $encoded && !ref($encoded) && length($encoded)
              && length($encoded) <= 4 * int((MAX_IMAGE_BYTES + 2) / 3)
              && $encoded =~ /\A(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?\z/;
        }
    } else {
        my $groups = $input->{groups};
        die "invalid_groups\n" unless ref($groups) eq 'ARRAY' && @$groups > 0 && @$groups <= 32;
        my %ids;
        for my $group (@$groups) {
            _only_keys($group, qw(id observations));
            my $id = $group->{id};
            die "invalid_group_id\n" unless defined $id && !ref($id) && $id =~ /\A[A-Za-z0-9_-]{1,64}\z/ && !$ids{$id}++;
            my $observations = $group->{observations};
            die "invalid_observations\n" unless ref($observations) eq 'ARRAY' && @$observations <= MAX_PAGES;
            my %seen;
            for my $o (@$observations) {
                _only_keys($o, qw(index slot side strength sha256));
                die "invalid_observation_identity\n" unless _uint($o->{index}, 1_000_000)
                  && !$seen{$o->{index}}++ && _uint($o->{slot}, 1_000_000) && _hash($o->{sha256});
                die "invalid_side\n" unless defined $o->{side} && !ref($o->{side}) && $o->{side} =~ /\A(?:LEFT|RIGHT|UNKNOWN)\z/;
            }
        }
    }
}

sub _binary_input ($raw) {
    die "invalid_frame\n" unless length($raw) >= 8 && substr($raw, 0, 4) eq 'AOW1';
    my $size = unpack('N', substr($raw, 4, 4));
    die "invalid_metadata_length\n" unless $size > 0 && $size <= 65536 && length($raw) >= 8 + $size;
    my $metadata = substr($raw, 8, $size);
    my $input = decode_json($metadata);
    _validate($input, 'pages', 1);
    my $offset = 8 + $size;
    for my $page (@{$input->{pages}}) {
        my $length = $page->{bytes_count};
        die "truncated_image\n" if $offset + $length > length($raw);
        $page->{bytes} = substr($raw, $offset, $length);
        $offset += $length;
    }
    die "trailing_frame_data\n" unless $offset == length($raw);
    # The compact metadata binds the exact image hashes, lengths, indices and
    # content revision. Each image hash is independently checked after framing.
    return ($input, sha256_hex($metadata));
}

sub _request ($self, $c, $kind) {
    my $type = $c->req->headers->content_type // '';
    my $binary = $kind eq 'pages' && $type eq 'application/vnd.adaptive-offset.pages-v1';
    return $c->render(status => 415, json => {error => 'json_required'})
      unless $binary || $type =~ m{\Aapplication/json(?:;|\z)}i;
    my $raw = $c->req->body;
    # Votes never need the image-body limit.
    return $c->render(status => 413, json => {error => 'request_too_large'}) if $kind eq 'vote' && length($raw) > 65536;
    my ($input, $result, $request_hash);
    my $ok = eval {
        if ($binary) {
            ($input, $request_hash) = _binary_input($raw);
        } else {
            $input = decode_json($raw);
            _validate($input, $kind);
            $request_hash = sha256_hex($raw);
        }
        1;
    };
    return $c->render(status => 400, json => {error => 'invalid_request'}) unless $ok;
    $ok = eval {
        $result = $kind eq 'pages' ? $self->_bounded_pages($input->{pages})
          : [map { {id => $_->{id}, %{LANraragi::Utils::AdaptiveOffsetVote::aggregate($_->{observations})}} } @{$input->{groups}}];
        1;
    };
    unless ($ok) {
        my $error = "$@";
        my ($status, $code) = $error =~ /worker_timeout/ ? (504, 'worker_timeout')
          : $error =~ /(?:image_hash_mismatch|unsupported_image|image_dimensions|decode_failed)/ ? (422, 'image_unusable')
          : $error =~ /invalid_strength/ ? (400, 'invalid_request') : (503, 'worker_unavailable');
        $c->res->headers->header('Retry-After' => '1') if $status >= 500;
        return $c->render(status => $status, json => {error => $code});
    }
    return $c->render(json => {schema_version => 1,
        algorithm_version => LANraragi::Utils::AdaptiveOffsetVote::ALGORITHM_VERSION,
        content_revision => $input->{content_revision}, request_sha256 => $request_hash,
        ($kind eq 'pages' ? 'pages' : 'groups') => $result});
}

sub _bounded_pages ($self, $pages) {
    pipe(my $reader, my $writer) or die "worker_pipe\n";
    my $pid = fork();
    die "worker_fork\n" unless defined $pid;
    if (!$pid) {
        close $reader;
        # Never copy native decoder diagnostics or submitted content into logs.
        open STDERR, '>', '/dev/null';
        my $result = eval { {pages => $self->_detect_pages($pages)} };
        $result //= {error => "$@" =~ /(?:image_hash_mismatch|unsupported_image|image_dimensions|decode_failed)/ ? 'decode_failed' : 'worker_failed'};
        print {$writer} encode_json($result);
        close $writer;
        _exit(0);
    }
    close $writer;
    my $select = IO::Select->new($reader);
    my $deadline = time() + $self->detection_timeout;
    my $output = '';
    my $ok = eval {
        while (1) {
            my $remaining = $deadline - time();
            die "worker_timeout\n" if $remaining <= 0 || !$select->can_read($remaining);
            my $count = sysread($reader, my $buffer, 65536);
            die "worker_read\n" unless defined $count;
            last unless $count;
            $output .= $buffer;
            die "worker_output_limit\n" if length($output) > 262144;
        }
        1;
    };
    my $error = $@;
    close $reader;
    kill 'KILL', $pid unless $ok;
    waitpid($pid, 0);
    die $error unless $ok;
    die "worker_failed\n" if $? != 0;
    my $decoded = decode_json($output);
    die "$decoded->{error}\n" if $decoded->{error};
    return $decoded->{pages};
}

sub _detect_pages ($self, $pages) {
    require LANraragi::Utils::Vips;
    LANraragi::Utils::Vips::init('adaptive-offset-worker');
    my @result;
    for my $page (@$pages) {
        my $bytes = $page->{bytes} // decode_base64($page->{content});
        die "image_hash_mismatch\n" unless length($bytes) <= MAX_IMAGE_BYTES && sha256_hex($bytes) eq $page->{sha256};
        # Only raster loaders. Never dispatch PDF/SVG or file/URL inputs.
        die "unsupported_image\n" unless $bytes =~ /\A(?:\xff\xd8\xff|\x89PNG\r\n\x1a\n|GIF8[79]a|BM|II\x2a\x00|MM\x00\x2a)/
          || $bytes =~ /\ARIFF....WEBP/s || $bytes =~ /\A....ftyp(?:avif|avis|heic|mif1)/s;
        my $header = LANraragi::Utils::Vips::vips_image_new_from_buffer($bytes, length($bytes), '', undef);
        die "decode_failed\n" unless $header;
        my ($width, $height) = (LANraragi::Utils::Vips::width($header), LANraragi::Utils::Vips::height($header));
        LANraragi::Utils::Vips::unref_image($header);
        die "image_dimensions\n" unless $width > 0 && $height > 0 && $width * $height <= MAX_PIXELS;
        my $evidence = LANraragi::Utils::PageSideDetector::detect_page_side($bytes, $page->{index});
        die "decode_failed\n" if $evidence->{reason} =~ /\A(?:decode_failed|invalid_dimensions)\z/;
        push @result, {%$evidence, sha256 => $page->{sha256}, source_width => $width, source_height => $height};
    }
    return \@result;
}

1;
