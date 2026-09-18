# Adaptive offset worker

An optional internal HTTP service for archive-local page-side detection.
Keep it on a trusted internal network; it is not a public authenticated API.

`PageSideDetector` contains the extracted pixel kernel. It loads neither app
configuration nor Redis. `AdaptiveOffsetVote` implements the preregistered
logical-slot vote: valid side, strength >= .25, at least two observations,
relative vote gap >= .25. Scores are not calibrated probabilities. The old
`PageSide` runtime remains in place until final adoption gates pass.

Protocol version 1 uses algorithm `lrr-vips320-v1-vote1`:

- `GET /health`: source revision, algorithm and native libvips version.
- `POST /v1/pages`: clients send `application/vnd.adaptive-offset.pages-v1`.
  Body: ASCII `AOW1`, a 4-byte unsigned big-endian metadata length, UTF-8 JSON
  `{schema_version,content_revision,pages:[{index,sha256,bytes_count}]}`, then the
  exact image bytes concatenated in metadata order. Metadata is at most 64 KiB.
  Lengths, trailing data, per-image SHA256 and indices are checked. The reply's
  `request_sha256` hashes the exact metadata bytes, binding all image identities,
  lengths and the content revision without hashing a second base64 copy.
  Returns page index/hash, side, confidence, reason and original dimensions.
  The initial JSON transport with `{index,sha256,content}` base64 entries remains
  accepted for compatibility; its request digest covers the entire JSON body.
- `POST /v1/vote`: `{schema_version,content_revision,groups:[{id,observations}]}`,
  each observation `{index,slot,side,strength,sha256}`. Returns groups with side,
  score/gap and evidence indices. The worker receives explicit logical slots;
  it neither acquires pages nor decides chapter/archive relationships.

Binary framing avoids measured base64/JSON validation and duplicate bulk digest
costs. Both clients use it directly; they do not retry with another transport.
The request schema and pixel/vote algorithm remain unchanged. Vote request
digests cover their exact small JSON body. JSON uses the installed Mojo native
backend rather than pure Perl serialization.

Clients validate algorithm, request/revision/image identities and completeness.
Error, timeout, invalid output and cancellation never become cached UNKNOWN or
a silent legacy fallback. Manual corrections and stale-result rejection remain
in the apps. The Perl transport is `AdaptiveOffsetClient`; the Kotlin transport
lives in the Server repository. Neither changes the reader by being installed.

Bounds: 12 pages, 8 MiB per image, 48 MiB request, 100 million source pixels,
32 vote groups of at most 12 observations, 64 KiB vote request, 1 MiB client
response. Larger batches must be split by acquisition callers. Only raster
magic is accepted; no paths, URLs, PDF, SVG, app DB or human eval labels.
Each image batch runs in a killable child with a 15s deadline; two prefork
workers bound concurrency. Failed image batches return 422, native process
failure 503, deadline 504. Responses use no-store. Submitted bytes and native
decoder diagnostics are not logged or persisted.

## Build and connect

Build from the repository root with a LANraragi image containing the required
Perl modules and native libvips dependencies:

```sh
docker build -f tools/adaptive-offset-worker/Dockerfile \
  --build-arg BASE_IMAGE=<lanraragi-image> \
  --build-arg SOURCE_REVISION=$(git rev-parse HEAD) \
  -t lanraragi-adaptive-offset-worker .
```

Run the worker on a dedicated internal network, listening on port 8766. It runs
as UID/GID 10001 and needs no archive, application database, or credential mounts.
Do not expose its port to the public internet. Configure the application's
`ADAPTIVE_OFFSET_WORKER_URL` with the internal service URL. Without this
setting, the application retains its built-in detector path.

Tests: `prove -l tests/LANraragi/Utils/AdaptiveOffsetWorker.t`.
`conformance.pl` accepts an external JSON fixture to compare extracted pixel
results against independently captured expectations.
