import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
    BENCHMARK_SCHEMA_VERSION,
    buildReaderUrl,
    counterbalancedOrder,
    isExpectedPageMove,
    loadBenchmarkConfig,
    publicVisibleState,
    redactMessages,
    subtractAttributionSnapshots,
    summarize,
} from "../../tools/browser/reader-performance-benchmark.mjs";

const benchmarkUrl = new URL("../../tools/browser/reader-performance-benchmark.mjs", import.meta.url);

function testEnvironment(overrides = {}) {
    return {
        LRR_BENCH_ARCHIVE_ID: "fixture-archive",
        LRR_BENCH_ARCHIVE_READONLY_CONFIRMED: "true",
        LRR_BENCH_TARGETS_JSON: JSON.stringify([
            { label: "control", baseUrl: "http://127.0.0.1:3101", revision: "abcdef0" },
            { label: "candidate", baseUrl: "http://127.0.0.1:3102", revision: "abcdef1" },
        ]),
        LRR_BENCH_CHROME_PATH: process.execPath,
        ...overrides,
    };
}

test("benchmark configuration is target-driven and progress writes are opt-in", () => {
    const config = loadBenchmarkConfig(testEnvironment());

    assert.deepEqual(config.profiles, ["off"]);
    assert.equal(config.startupSamples, 30);
    assert.equal(config.traversalRuns, 5);
    assert.equal(config.maxTransitions, 35);
    assert.equal(config.attribution, false);
    assert.equal(config.predecodeCount, null);
    assert.equal(config.targets.length, 2);

    assert.throws(
        () => loadBenchmarkConfig(testEnvironment({ LRR_BENCH_PROGRESS_PROFILES: "off,on" })),
        /requires LRR_BENCH_ALLOW_PROGRESS_WRITES=true/,
    );
    assert.throws(
        () => loadBenchmarkConfig(testEnvironment({
            LRR_BENCH_PROGRESS_PROFILES: "off,on",
            LRR_BENCH_ALLOW_PROGRESS_WRITES: "true",
        })),
        /requires LRR_BENCH_ISOLATED_STATE=true/,
    );
    assert.deepEqual(loadBenchmarkConfig(testEnvironment({
        LRR_BENCH_PROGRESS_PROFILES: "off,on",
        LRR_BENCH_ALLOW_PROGRESS_WRITES: "true",
        LRR_BENCH_ISOLATED_STATE: "true",
    })).profiles, ["off", "on"]);
});

test("predecode diagnostics are opt-in and allow zero without changing the default", () => {
    assert.equal(loadBenchmarkConfig(testEnvironment({ LRR_BENCH_PREDECODE_COUNT: "0" })).predecodeCount, 0);
    assert.equal(loadBenchmarkConfig(testEnvironment({ LRR_BENCH_PREDECODE_COUNT: "2" })).predecodeCount, 2);
    assert.throws(
        () => loadBenchmarkConfig(testEnvironment({ LRR_BENCH_PREDECODE_COUNT: "-1" })),
        /must be an integer/,
    );
});

test("optional image attribution is explicit and snapshot-based", () => {
    const config = loadBenchmarkConfig(testEnvironment({ LRR_BENCH_ATTRIBUTION: "true" }));
    assert.equal(config.attribution, true);
    assert.deepEqual(
        subtractAttributionSnapshots(
            { imageConstructions: 4, decodeCalls: 2, decodeTotalMs: 10.5 },
            { imageConstructions: 9, decodeCalls: 6, decodeTotalMs: 31.25, sourceGroups: [] },
        ),
        { imageConstructions: 5, decodeCalls: 4, decodeTotalMs: 20.75 },
    );
    assert.equal(subtractAttributionSnapshots(null, { decodeCalls: 1 }), null);
});

test("target validation preserves base paths and rejects unsafe inputs", () => {
    const config = loadBenchmarkConfig(testEnvironment({
        LRR_BENCH_TARGETS_JSON: JSON.stringify([
            { label: "control", baseUrl: "https://example.test/lrr", revision: "abcdef0" },
            { label: "candidate", baseUrl: "https://example.test/candidate", revision: "abcdef1" },
        ]),
    }));
    assert.equal(config.targets[0].baseUrl, "https://example.test/lrr");

    assert.throws(() => loadBenchmarkConfig(testEnvironment({
        LRR_BENCH_STARTUP_SAMPLES: "5foo",
    })), /must be an integer/);
    assert.throws(() => loadBenchmarkConfig(testEnvironment({
        LRR_BENCH_TARGETS_JSON: JSON.stringify([
            { label: "control", baseUrl: "file:///tmp/control" },
            { label: "candidate", baseUrl: "https://example.test" },
        ]),
    })), /credential-free HTTP\(S\)/);
});

test("reader URL preserves a configured base path", () => {
    const url = new URL(buildReaderUrl(
        { baseUrl: "https://example.test/lrr" },
        "archive-fixture",
        "sample-1",
    ));

    assert.equal(url.pathname, "/lrr/reader");
    assert.equal(url.searchParams.get("id"), "archive-fixture");
    assert.equal(url.searchParams.get("benchmark"), "sample-1");
});

test("public state and errors redact target URLs and archive identifiers", () => {
    const state = publicVisibleState({
        page: "3",
        maxPage: "70",
        busy: "false",
        sourceSignature: "private",
        images: [{
            id: "img",
            source: "https://example.test/lrr/page/archive-fixture",
            complete: true,
            naturalWidth: 100,
            naturalHeight: 200,
        }],
    });
    assert.deepEqual(state.images[0].sourceKind, "https");
    assert.equal(JSON.stringify(state).includes("example.test"), false);

    const messages = redactMessages(
        ["failed https://example.test/lrr/page/archive-fixture"],
        {
            archiveId: "archive-fixture",
            targets: [{ label: "control", baseUrl: "https://example.test/lrr" }],
        },
    );
    assert.deepEqual(messages, ["failed [control]/page/[archive]"]);
});

test("target scheduling counterbalances collection order", () => {
    const targets = [{ label: "A" }, { label: "B" }];
    const schedule = [0, 1].flatMap((round) => counterbalancedOrder(targets, round).map((target) => target.label));

    assert.deepEqual(schedule, ["A", "B", "B", "A"]);
});

test("summary contract reports p50 and p95 from raw values", () => {
    assert.equal(BENCHMARK_SCHEMA_VERSION, 3);
    assert.deepEqual(summarize([5, 1, 2, 4, 3]), { n: 5, p50: 3, p95: 5, max: 5 });
    assert.deepEqual(summarize([]), { n: 0, p50: null, p95: null, max: null });
});

test("page movement follows configured reading direction", () => {
    assert.equal(isExpectedPageMove(1, 3, "increasing"), true);
    assert.equal(isExpectedPageMove(3, 1, "decreasing"), true);
    assert.equal(isExpectedPageMove(3, 1, "increasing"), false);
    assert.equal(isExpectedPageMove(3, 1, "any"), true);
});

test("tracked benchmark source has no private target or fixed archive and emits raw resource evidence", async () => {
    const source = await readFile(benchmarkUrl, "utf8");

    assert.doesNotMatch(source, /maia\.local|lidlesseye|\blibra\b|\/Users\/sangeun/i);
    assert.doesNotMatch(source, /[a-f0-9]{40}/i);
    assert.match(source, /LRR_BENCH_TARGETS_JSON/);
    assert.match(source, /LRR_BENCH_ARCHIVE_ID/);
    assert.match(source, /counterbalancedOrder/);
    assert.match(source, /startupSamples/);
    assert.match(source, /warmRuns/);
    assert.match(source, /Network\.loadingFinished/);
    assert.match(source, /PerformanceObserver/);
    assert.match(source, /Performance\.getMetrics/);
    assert.match(source, /failedResources/);
    assert.match(source, /blankFrames/);
    assert.match(source, /staleCommits/);
    assert.match(source, /archiveFingerprint/);
    assert.match(source, /schemaVersion/);
    assert.match(source, /publicVisibleState/);
    assert.match(source, /firstVisibleAt/);
    assert.match(source, /pendingFrame/);
    assert.match(source, /new URL\("reader", `\$\{target\.baseUrl\}\/`\)/);
    assert.match(source, /LRR_BENCH_ARCHIVE_READONLY_CONFIRMED/);
    assert.match(source, /LRR_BENCH_ATTRIBUTION/);
    assert.match(source, /LRR_BENCH_PREDECODE_COUNT/);
    assert.match(source, /decodeOnDetached/);
    assert.match(source, /new Proxy\(NativeImage/);
    assert.match(source, /sourceOrdinal/);
    assert.match(source, /sourceKind/);
    assert.doesNotMatch(source, /sourceGroups:[\s\S]{0,100}currentSrc/);
    assert.match(source, /subtractAttributionSnapshots/);
});
