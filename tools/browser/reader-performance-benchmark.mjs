import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { chromium } from "playwright-core";

export const BENCHMARK_SCHEMA_VERSION = 3;

function integer(value, fallback, name, minimum = 1) {
    const raw = String(value ?? fallback);
    if (!/^\d+$/.test(raw)) {
        throw new Error(`${name} must be an integer >= ${minimum}`);
    }
    const parsed = Number(raw);
    if (!Number.isSafeInteger(parsed) || parsed < minimum) {
        throw new Error(`${name} must be an integer >= ${minimum}`);
    }
    return parsed;
}

function boolean(value, fallback = false) {
    if (value === undefined) return fallback;
    return /^(1|true|yes|on)$/i.test(value);
}

function parseTargets(raw) {
    if (!raw) {
        throw new Error("LRR_BENCH_TARGETS_JSON is required");
    }
    const targets = JSON.parse(raw);
    if (!Array.isArray(targets) || targets.length < 2) {
        throw new Error("LRR_BENCH_TARGETS_JSON must contain at least two targets");
    }
    const labels = new Set();
    for (const target of targets) {
        if (!target || typeof target.label !== "string" || typeof target.baseUrl !== "string") {
            throw new Error("Each benchmark target needs string label and baseUrl fields");
        }
        if (!/^[A-Za-z0-9._-]{1,64}$/.test(target.label)) {
            throw new Error(`Unsafe benchmark target label: ${target.label}`);
        }
        if (labels.has(target.label)) {
            throw new Error(`Duplicate benchmark target label: ${target.label}`);
        }
        labels.add(target.label);
        const url = new URL(target.baseUrl);
        if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
            throw new Error(`Benchmark target ${target.label} must use credential-free HTTP(S)`);
        }
        if (target.revision !== undefined && target.revision !== null && !/^[0-9a-f]{7,64}$/i.test(target.revision)) {
            throw new Error(`Benchmark target ${target.label} has an invalid revision`);
        }
        if (target.imageDigest !== undefined && target.imageDigest !== null
            && !/^(?:sha256:)?[0-9a-f]{64}$/i.test(target.imageDigest)) {
            throw new Error(`Benchmark target ${target.label} has an invalid imageDigest`);
        }
    }
    return targets.map((target) => ({
        label: target.label,
        baseUrl: target.baseUrl.replace(/\/$/, ""),
        revision: target.revision ?? null,
        imageDigest: target.imageDigest ?? null,
    }));
}

function chromeCandidates(env) {
    return [
        env.LRR_BENCH_CHROME_PATH,
        env.CHROME_PATH,
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/usr/bin/google-chrome",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
    ].filter(Boolean);
}

export function loadBenchmarkConfig(env = process.env) {
    if (!env.LRR_BENCH_ARCHIVE_ID) {
        throw new Error("LRR_BENCH_ARCHIVE_ID is required");
    }
    if (!boolean(env.LRR_BENCH_ARCHIVE_READONLY_CONFIRMED)) {
        throw new Error("LRR_BENCH_ARCHIVE_READONLY_CONFIRMED=true is required before opening Reader targets");
    }
    const profiles = (env.LRR_BENCH_PROGRESS_PROFILES ?? "off")
        .split(",")
        .map((profile) => profile.trim().toLowerCase())
        .filter(Boolean);
    if (profiles.some((profile) => !["off", "on"].includes(profile))) {
        throw new Error("LRR_BENCH_PROGRESS_PROFILES accepts only off,on");
    }
    if (profiles.includes("on") && !boolean(env.LRR_BENCH_ALLOW_PROGRESS_WRITES)) {
        throw new Error("Progress-on profiling requires LRR_BENCH_ALLOW_PROGRESS_WRITES=true");
    }
    if (profiles.includes("on") && !boolean(env.LRR_BENCH_ISOLATED_STATE)) {
        throw new Error("Progress-on profiling requires LRR_BENCH_ISOLATED_STATE=true");
    }
    const candidates = chromeCandidates(env);
    const executablePath = candidates.find((candidate) => existsSync(candidate));
    if (!executablePath) {
        throw new Error("Chrome/Chromium was not found; set LRR_BENCH_CHROME_PATH");
    }
    const mangaMode = boolean(env.LRR_BENCH_MANGA_MODE, false);
    const expectedPageDirection = env.LRR_BENCH_EXPECTED_PAGE_DIRECTION ?? (mangaMode ? "decreasing" : "increasing");
    if (!["increasing", "decreasing", "any"].includes(expectedPageDirection)) {
        throw new Error("LRR_BENCH_EXPECTED_PAGE_DIRECTION accepts increasing,decreasing,any");
    }
    return {
        targets: parseTargets(env.LRR_BENCH_TARGETS_JSON),
        archiveId: env.LRR_BENCH_ARCHIVE_ID,
        archiveReadOnlyConfirmed: true,
        executablePath,
        profiles,
        startupSamples: integer(env.LRR_BENCH_STARTUP_SAMPLES, "30", "LRR_BENCH_STARTUP_SAMPLES"),
        traversalRuns: integer(env.LRR_BENCH_TRAVERSAL_RUNS, "5", "LRR_BENCH_TRAVERSAL_RUNS"),
        maxTransitions: integer(env.LRR_BENCH_MAX_TRANSITIONS, "35", "LRR_BENCH_MAX_TRANSITIONS"),
        viewport: {
            width: integer(env.LRR_BENCH_VIEWPORT_WIDTH, "1440", "LRR_BENCH_VIEWPORT_WIDTH"),
            height: integer(env.LRR_BENCH_VIEWPORT_HEIGHT, "900", "LRR_BENCH_VIEWPORT_HEIGHT"),
        },
        doublePage: boolean(env.LRR_BENCH_DOUBLE_PAGE, true),
        mangaMode,
        infiniteScroll: boolean(env.LRR_BENCH_INFINITE_SCROLL, false),
        preloadCount: integer(env.LRR_BENCH_PRELOAD_COUNT, "5", "LRR_BENCH_PRELOAD_COUNT", 0),
        predecodeCount: env.LRR_BENCH_PREDECODE_COUNT === undefined
            ? null
            : integer(env.LRR_BENCH_PREDECODE_COUNT, "0", "LRR_BENCH_PREDECODE_COUNT", 0),
        navigationKey: env.LRR_BENCH_NAVIGATION_KEY ?? "ArrowRight",
        expectedPageDirection,
        trackBlankFrames: boolean(env.LRR_BENCH_TRACK_BLANK_FRAMES),
        attribution: boolean(env.LRR_BENCH_ATTRIBUTION),
        includeTargetUrls: boolean(env.LRR_BENCH_INCLUDE_TARGET_URLS),
        headless: boolean(env.LRR_BENCH_HEADLESS, true),
    };
}

export function counterbalancedOrder(targets, round) {
    return round % 2 === 0 ? [...targets] : [...targets].reverse();
}

export function percentile(values, quantile) {
    if (values.length === 0) return null;
    const ordered = [...values].sort((left, right) => left - right);
    const index = Math.min(ordered.length - 1, Math.ceil(ordered.length * quantile) - 1);
    return ordered[index];
}

export function summarize(values) {
    if (values.length === 0) return { n: 0, p50: null, p95: null, max: null };
    return {
        n: values.length,
        p50: +percentile(values, 0.50).toFixed(1),
        p95: +percentile(values, 0.95).toFixed(1),
        max: +Math.max(...values).toFixed(1),
    };
}

function sanitizedConfig(config) {
    return {
        archiveFingerprint: createHash("sha256").update(config.archiveId).digest("hex").slice(0, 16),
        archiveReadOnlyConfirmed: config.archiveReadOnlyConfirmed,
        targets: config.targets.map((target) => ({
            label: target.label,
            revision: target.revision,
            imageDigest: target.imageDigest,
            ...(config.includeTargetUrls ? { baseUrl: target.baseUrl } : {}),
        })),
        profiles: config.profiles,
        startupSamples: config.startupSamples,
        traversalRuns: config.traversalRuns,
        maxTransitions: config.maxTransitions,
        viewport: config.viewport,
        doublePage: config.doublePage,
        mangaMode: config.mangaMode,
        infiniteScroll: config.infiniteScroll,
        preloadCount: config.preloadCount,
        predecodeCount: config.predecodeCount,
        navigationKey: config.navigationKey,
        expectedPageDirection: config.expectedPageDirection,
        trackBlankFrames: config.trackBlankFrames,
        attribution: config.attribution,
        headless: config.headless,
        schedule: "counterbalanced-forward-reverse",
    };
}

async function createContext(browser, config, profile) {
    const context = await browser.newContext({
        viewport: config.viewport,
        deviceScaleFactor: 1,
    });
    const preferences = {
        doublePage: config.doublePage,
        mangaMode: config.mangaMode,
        infiniteScroll: config.infiniteScroll,
        preloadCount: config.preloadCount,
        predecodeCount: config.predecodeCount,
        ignoreProgress: profile === "off",
        trackBlankFrames: config.trackBlankFrames,
        attribution: config.attribution,
    };
    await context.addInitScript((settings) => {
        localStorage.doublePageMode = String(settings.doublePage);
        localStorage.mangaMode = String(settings.mangaMode);
        localStorage.infiniteScroll = String(settings.infiniteScroll);
        localStorage.preloadCount = String(settings.preloadCount);
        if (settings.predecodeCount === null) {
            localStorage.removeItem("readerPredecodeCount");
        } else {
            localStorage.readerPredecodeCount = String(settings.predecodeCount);
        }
        localStorage.ignoreProgress = String(settings.ignoreProgress);
        window.__lrrBench = {
            longTasks: [],
            blankFrames: settings.trackBlankFrames ? 0 : null,
            blankObserverStarted: false,
            firstVisibleAt: null,
            attribution: settings.attribution ? {
                imageConstructions: 0,
                constructedLoads: 0,
                constructedLoadConnected: 0,
                constructedLoadDetached: 0,
                constructedErrors: 0,
                decodeCalls: 0,
                decodeOnConnected: 0,
                decodeOnDetached: 0,
                decodeResolved: 0,
                decodeRejected: 0,
                decodeTotalMs: 0,
            } : null,
        };
        if (settings.attribution) {
            const counters = window.__lrrBench.attribution;
            const NativeImage = window.Image;
            const sourceGroups = new Map();
            const constructedImages = [];
            const groupFor = (image) => {
                const source = image.currentSrc || image.src;
                if (!source) return null;
                if (!sourceGroups.has(source)) {
                    sourceGroups.set(source, {
                        sourceOrdinal: sourceGroups.size + 1,
                        sourceKind: source.startsWith("blob:") ? "blob"
                            : source.startsWith("https:") ? "https"
                                : source.startsWith("http:") ? "http"
                                    : source.startsWith("data:") ? "data" : "other",
                        constructedLoads: 0,
                        constructedLoadConnected: 0,
                        constructedLoadDetached: 0,
                        decodeCalls: 0,
                        decodeOnConnected: 0,
                        decodeOnDetached: 0,
                        decodeResolved: 0,
                        decodeRejected: 0,
                        decodeTotalMs: 0,
                    });
                }
                return sourceGroups.get(source);
            };
            window.Image = new Proxy(NativeImage, {
                construct(target, argumentsList) {
                    const image = Reflect.construct(target, argumentsList);
                    counters.imageConstructions += 1;
                    constructedImages.push(image);
                    image.addEventListener("load", () => {
                        const connectionKey = image.isConnected ? "constructedLoadConnected" : "constructedLoadDetached";
                        counters.constructedLoads += 1;
                        counters[connectionKey] += 1;
                        const group = groupFor(image);
                        if (group) {
                            group.constructedLoads += 1;
                            group[connectionKey] += 1;
                        }
                    });
                    image.addEventListener("error", () => {
                        counters.constructedErrors += 1;
                    });
                    return image;
                },
            });

            const nativeDecode = HTMLImageElement.prototype.decode;
            if (typeof nativeDecode === "function") {
                HTMLImageElement.prototype.decode = function benchmarkDecode() {
                    const group = groupFor(this);
                    const connectionKey = this.isConnected ? "decodeOnConnected" : "decodeOnDetached";
                    counters.decodeCalls += 1;
                    counters[connectionKey] += 1;
                    if (group) {
                        group.decodeCalls += 1;
                        group[connectionKey] += 1;
                    }
                    const started = performance.now();
                    try {
                        return nativeDecode.call(this).then(
                            (value) => {
                                const elapsed = performance.now() - started;
                                counters.decodeResolved += 1;
                                counters.decodeTotalMs += elapsed;
                                if (group) {
                                    group.decodeResolved += 1;
                                    group.decodeTotalMs += elapsed;
                                }
                                return value;
                            },
                            (error) => {
                                const elapsed = performance.now() - started;
                                counters.decodeRejected += 1;
                                counters.decodeTotalMs += elapsed;
                                if (group) {
                                    group.decodeRejected += 1;
                                    group.decodeTotalMs += elapsed;
                                }
                                throw error;
                            },
                        );
                    } catch (error) {
                        const elapsed = performance.now() - started;
                        counters.decodeRejected += 1;
                        counters.decodeTotalMs += elapsed;
                        if (group) {
                            group.decodeRejected += 1;
                            group.decodeTotalMs += elapsed;
                        }
                        throw error;
                    }
                };
            }
            window.__lrrBench.snapshotAttribution = () => {
                const groups = new Map([...sourceGroups].map(([source, group]) => [source, {
                    ...group,
                    constructors: 0,
                    constructedConnected: 0,
                    constructedDetached: 0,
                    domImages: 0,
                    visibleDomImages: 0,
                }]));
                const snapshotGroupFor = (image) => {
                    const group = groupFor(image);
                    if (!group) return null;
                    if (!groups.has(image.currentSrc || image.src)) {
                        groups.set(image.currentSrc || image.src, {
                            ...group,
                            constructors: 0,
                            constructedConnected: 0,
                            constructedDetached: 0,
                            domImages: 0,
                            visibleDomImages: 0,
                        });
                    }
                    return groups.get(image.currentSrc || image.src);
                };
                for (const image of constructedImages) {
                    const group = snapshotGroupFor(image);
                    if (!group) continue;
                    group.constructors += 1;
                    group[image.isConnected ? "constructedConnected" : "constructedDetached"] += 1;
                }
                for (const image of document.querySelectorAll("img")) {
                    const source = image.currentSrc || image.src;
                    const visible = image.getClientRects().length > 0;
                    if (!visible && !sourceGroups.has(source)) continue;
                    const group = snapshotGroupFor(image);
                    if (!group) continue;
                    group.domImages += 1;
                    if (visible) group.visibleDomImages += 1;
                }
                return {
                    ...counters,
                    sourceGroups: [...groups.values()].sort((left, right) => left.sourceOrdinal - right.sourceOrdinal),
                };
            };
        }
        try {
            const observer = new PerformanceObserver((list) => {
                for (const entry of list.getEntries()) {
                    window.__lrrBench.longTasks.push({ startTime: entry.startTime, duration: entry.duration });
                }
            });
            observer.observe({ type: "longtask", buffered: true });
        } catch {
            window.__lrrBench.longTasks = null;
        }
    }, preferences);
    return context;
}

async function attachDiagnostics(context, page) {
    const consoleErrors = [];
    const pageErrors = [];
    const failedResources = [];
    const network = { encodedBytes: 0, imageEncodedBytes: 0, completedRequests: 0 };
    const requestTypes = new Map();
    page.on("console", (message) => {
        if (message.type() === "error") consoleErrors.push(message.text());
    });
    page.on("pageerror", (error) => pageErrors.push(error.message));
    const cdp = await context.newCDPSession(page);
    await cdp.send("Network.enable");
    await cdp.send("Performance.enable");
    cdp.on("Network.responseReceived", (event) => {
        requestTypes.set(event.requestId, event.type);
    });
    cdp.on("Network.loadingFinished", (event) => {
        network.encodedBytes += event.encodedDataLength ?? 0;
        network.completedRequests += 1;
        if (requestTypes.get(event.requestId) === "Image") {
            network.imageEncodedBytes += event.encodedDataLength ?? 0;
        }
    });
    cdp.on("Network.loadingFailed", (event) => {
        if (!event.canceled) failedResources.push(event.errorText);
    });
    return { cdp, consoleErrors, pageErrors, failedResources, network };
}

async function performanceMetrics(cdp) {
    try {
        const { metrics } = await cdp.send("Performance.getMetrics");
        const wanted = new Set(["JSHeapUsedSize", "JSHeapTotalSize", "Nodes", "Documents", "LayoutCount", "RecalcStyleCount"]);
        return Object.fromEntries(metrics.filter((metric) => wanted.has(metric.name)).map((metric) => [metric.name, metric.value]));
    } catch {
        return null;
    }
}

async function visibleState(page) {
    return page.evaluate(() => {
        const images = [document.querySelector("#img"), document.querySelector("#img_doublepage")]
            .filter(Boolean)
            .filter((image) => image.getClientRects().length > 0 && image.currentSrc)
            .map((image) => ({
                id: image.id,
                source: image.currentSrc,
                complete: image.complete,
                naturalWidth: image.naturalWidth,
                naturalHeight: image.naturalHeight,
            }));
        return {
            page: document.querySelector(".current-page")?.textContent?.trim() ?? null,
            maxPage: document.querySelector(".max-page")?.textContent?.trim() ?? null,
            busy: document.querySelector("#i3")?.getAttribute("aria-busy") ?? null,
            images,
            sourceSignature: images.map((image) => `${image.id}:${image.source}`).join("|"),
        };
    });
}

function sourceKind(source) {
    if (source.startsWith("blob:")) return "blob";
    if (source.startsWith("http:")) return "http";
    if (source.startsWith("https:")) return "https";
    if (source.startsWith("data:")) return "data";
    return source ? "other" : "empty";
}

export function publicVisibleState(state) {
    return {
        page: state.page,
        maxPage: state.maxPage,
        busy: state.busy,
        images: state.images.map((image) => ({
            id: image.id,
            sourceKind: sourceKind(image.source),
            complete: image.complete,
            naturalWidth: image.naturalWidth,
            naturalHeight: image.naturalHeight,
        })),
    };
}

export function redactMessages(messages, config) {
    return messages.map((message) => {
        let redacted = String(message).split(config.archiveId).join("[archive]");
        for (const target of config.targets) {
            redacted = redacted.split(target.baseUrl).join(`[${target.label}]`);
        }
        return redacted;
    });
}

export function isExpectedPageMove(previousPage, currentPage, direction) {
    if (!Number.isFinite(previousPage) || !Number.isFinite(currentPage)) return false;
    if (direction === "any") return currentPage !== previousPage;
    if (direction === "decreasing") return currentPage < previousPage;
    return currentPage > previousPage;
}

function isTerminalPage(state, direction) {
    const current = Number.parseInt(state.page, 10);
    const maximum = Number.parseInt(state.maxPage, 10);
    if (!Number.isFinite(current) || !Number.isFinite(maximum)) return false;
    if (direction === "decreasing") return current <= 1;
    if (direction === "increasing") return current >= maximum - 1;
    return false;
}

async function waitForVisibleReader(page, previous = null) {
    await page.waitForFunction((oldState) => {
        const images = [document.querySelector("#img"), document.querySelector("#img_doublepage")]
            .filter(Boolean)
            .filter((image) => image.getClientRects().length > 0 && image.currentSrc);
        const pageText = document.querySelector(".current-page")?.textContent?.trim();
        const signature = images.map((image) => `${image.id}:${image.currentSrc}`).join("|");
        const ready = document.querySelector("#i3")?.getAttribute("aria-busy") !== "true"
            && images.length > 0
            && images.every((image) => image.currentSrc && image.complete && image.naturalWidth > 0);
        if (!ready) return false;
        if (!oldState) {
            if (window.__lrrBench && window.__lrrBench.firstVisibleAt === null) {
                window.__lrrBench.firstVisibleAt = performance.now();
            }
            return true;
        }
        return pageText !== oldState.page && signature !== oldState.sourceSignature;
    }, previous, { timeout: 30000 });
    await page.evaluate(() => {
        const bench = window.__lrrBench;
        const reader = document.querySelector("#i3");
        if (!bench || bench.blankFrames === null || bench.blankObserverStarted || !reader) return;
        bench.blankObserverStarted = true;
        let pendingFrame = false;
        const inspectBlank = () => {
            pendingFrame = false;
            if (reader.getAttribute("aria-busy") === "true") return;
            const visible = [document.querySelector("#img"), document.querySelector("#img_doublepage")]
                .filter(Boolean)
                .filter((image) => image.getClientRects().length > 0 && image.currentSrc);
            if (visible.length === 0) bench.blankFrames += 1;
        };
        new MutationObserver(() => {
            if (pendingFrame) return;
            pendingFrame = true;
            requestAnimationFrame(inspectBlank);
        }).observe(reader, { subtree: true, attributes: true, childList: true });
    });
    return visibleState(page);
}

export function buildReaderUrl(target, archiveId, token) {
    const url = new URL("reader", `${target.baseUrl}/`);
    url.searchParams.set("id", archiveId);
    url.searchParams.set("p", "1");
    url.searchParams.set("benchmark", token);
    return url.toString();
}

async function pageEvidence(page) {
    return page.evaluate(() => {
        const navigation = performance.getEntriesByType("navigation")[0];
        const readerModule = performance.getEntriesByType("resource")
            .find((entry) => /\/js\/reader\.js(?:\?|$)/.test(entry.name));
        const longTasks = window.__lrrBench?.longTasks ?? null;
        return {
            dclMs: navigation?.domContentLoadedEventEnd ?? null,
            firstVisibleMs: window.__lrrBench?.firstVisibleAt ?? null,
            moduleStartMs: readerModule?.startTime ?? null,
            longTasks: longTasks === null ? null : {
                count: longTasks.length,
                totalMs: longTasks.reduce((sum, task) => sum + task.duration, 0),
                raw: longTasks,
            },
            blankFrames: window.__lrrBench?.blankFrames ?? null,
            attribution: window.__lrrBench?.snapshotAttribution?.() ?? null,
        };
    });
}

export function subtractAttributionSnapshots(before, after) {
    if (!before || !after) return null;
    return Object.fromEntries(Object.entries(after)
        .filter(([, value]) => Number.isFinite(value))
        .map(([key, value]) => [key, value - (before[key] ?? 0)]));
}

async function attributionSnapshot(page) {
    return page.evaluate(() => {
        return window.__lrrBench?.snapshotAttribution?.() ?? null;
    });
}

async function startupSample(browser, config, target, profile, sample) {
    const context = await createContext(browser, config, profile);
    const page = await context.newPage();
    const diagnostics = await attachDiagnostics(context, page);
    await diagnostics.cdp.send("Network.setCacheDisabled", { cacheDisabled: true });
    try {
        await page.goto(buildReaderUrl(target, config.archiveId, `${profile}-startup-${sample}`), {
            waitUntil: "domcontentloaded",
            timeout: 30000,
        });
        let state;
        try {
            state = await waitForVisibleReader(page);
        } catch (error) {
            const diagnostic = publicVisibleState(await visibleState(page));
            throw new Error(`Startup readiness failed for ${target.label}/${profile} sample ${sample}: ${JSON.stringify({
                diagnostic,
                consoleErrors: redactMessages(diagnostics.consoleErrors, config),
                pageErrors: redactMessages(diagnostics.pageErrors, config),
                failedResources: redactMessages(diagnostics.failedResources, config),
            })}`, { cause: error });
        }
        return {
            sample,
            ...await pageEvidence(page),
            state: publicVisibleState(state),
            network: diagnostics.network,
            metrics: await performanceMetrics(diagnostics.cdp),
            consoleErrors: redactMessages(diagnostics.consoleErrors, config),
            pageErrors: redactMessages(diagnostics.pageErrors, config),
            failedResources: redactMessages(diagnostics.failedResources, config),
        };
    } finally {
        await context.close();
    }
}

async function traverse(page, diagnostics, config, collect) {
    const turns = [];
    let staleCommits = 0;
    for (let transition = 0; transition < config.maxTransitions; transition += 1) {
        const before = await visibleState(page);
        if (isTerminalPage(before, config.expectedPageDirection)) break;
        const previousPage = Number.parseInt(before.page, 10);
        const started = performance.now();
        await page.keyboard.press(config.navigationKey);
        const after = await waitForVisibleReader(page, before);
        const elapsedMs = performance.now() - started;
        const currentPage = Number.parseInt(after.page, 10);
        if (!isExpectedPageMove(previousPage, currentPage, config.expectedPageDirection)) staleCommits += 1;
        if (collect) {
            turns.push({
                transition: transition + 1,
                elapsedMs,
                fromPage: before.page,
                toPage: after.page,
                visibleImages: publicVisibleState(after).images,
            });
        }
    }
    return {
        turns,
        staleCommits,
        finalState: publicVisibleState(await visibleState(page)),
        network: diagnostics.network,
        consoleErrors: redactMessages(diagnostics.consoleErrors, config),
        pageErrors: redactMessages(diagnostics.pageErrors, config),
        failedResources: redactMessages(diagnostics.failedResources, config),
    };
}

async function warmRun(browser, config, target, profile, run) {
    const context = await createContext(browser, config, profile);
    try {
        const warmup = await context.newPage();
        const warmupDiagnostics = await attachDiagnostics(context, warmup);
        await warmupDiagnostics.cdp.send("Network.setCacheDisabled", { cacheDisabled: false });
        await warmup.goto(buildReaderUrl(target, config.archiveId, `${profile}-warmup-${run}`), {
            waitUntil: "domcontentloaded",
            timeout: 30000,
        });
        await waitForVisibleReader(warmup);
        await traverse(warmup, warmupDiagnostics, config, false);
        await warmup.close();

        const measured = await context.newPage();
        const diagnostics = await attachDiagnostics(context, measured);
        await diagnostics.cdp.send("Network.setCacheDisabled", { cacheDisabled: false });
        await measured.goto(buildReaderUrl(target, config.archiveId, `${profile}-measured-${run}`), {
            waitUntil: "domcontentloaded",
            timeout: 30000,
        });
        await waitForVisibleReader(measured);
        const metricsBefore = await performanceMetrics(diagnostics.cdp);
        const attributionBefore = await attributionSnapshot(measured);
        const result = await traverse(measured, diagnostics, config, true);
        const metricsAfter = await performanceMetrics(diagnostics.cdp);
        const attributionAfter = await attributionSnapshot(measured);
        const evidence = await pageEvidence(measured);
        const elapsed = result.turns.map((turn) => turn.elapsedMs);
        return {
            run,
            mutatesProgress: profile === "on",
            ...result,
            totalMs: elapsed.reduce((sum, value) => sum + value, 0),
            turnSummary: summarize(elapsed),
            longTasks: evidence.longTasks,
            blankFrames: evidence.blankFrames,
            attribution: {
                before: attributionBefore,
                after: attributionAfter,
                traversal: subtractAttributionSnapshots(attributionBefore, attributionAfter),
            },
            metricsBefore,
            metricsAfter,
        };
    } finally {
        await context.close();
    }
}

function profileResult() {
    return { startupSamples: [], warmRuns: [], summary: null };
}

function sumObserved(values) {
    const observed = values.filter(Number.isFinite);
    return observed.length === 0 ? null : observed.reduce((sum, value) => sum + value, 0);
}

function finalizeProfile(result) {
    const startup = result.startupSamples;
    const runs = result.warmRuns;
    const turns = runs.flatMap((run) => run.turns.map((turn) => turn.elapsedMs));
    result.summary = {
        startup: {
            dclMs: summarize(startup.map((sample) => sample.dclMs).filter(Number.isFinite)),
            firstVisibleMs: summarize(startup.map((sample) => sample.firstVisibleMs).filter(Number.isFinite)),
            moduleStartMs: summarize(startup.map((sample) => sample.moduleStartMs).filter(Number.isFinite)),
        },
        warm: {
            turnsMs: summarize(turns),
            totalPerRunMs: summarize(runs.map((run) => run.totalMs)),
        },
        errors: {
            console: startup.reduce((sum, sample) => sum + sample.consoleErrors.length, 0)
                + runs.reduce((sum, run) => sum + run.consoleErrors.length, 0),
            page: startup.reduce((sum, sample) => sum + sample.pageErrors.length, 0)
                + runs.reduce((sum, run) => sum + run.pageErrors.length, 0),
            failedResources: startup.reduce((sum, sample) => sum + sample.failedResources.length, 0)
                + runs.reduce((sum, run) => sum + run.failedResources.length, 0),
            blankFrames: sumObserved([
                ...startup.map((sample) => sample.blankFrames),
                ...runs.map((run) => run.blankFrames),
            ]),
            staleCommits: runs.reduce((sum, run) => sum + run.staleCommits, 0),
        },
    };
}

export async function runBenchmark(config) {
    const browser = await chromium.launch({
        executablePath: config.executablePath,
        headless: config.headless,
        args: ["--disable-background-networking", "--no-sandbox"],
    });
    try {
        const output = {
            schemaVersion: BENCHMARK_SCHEMA_VERSION,
            generatedAt: new Date().toISOString(),
            browserVersion: await browser.version(),
            config: sanitizedConfig(config),
            results: Object.fromEntries(config.targets.map((target) => [
                target.label,
                Object.fromEntries(config.profiles.map((profile) => [profile, profileResult()])),
            ])),
        };
        for (const profile of config.profiles) {
            for (let sample = 0; sample < config.startupSamples; sample += 1) {
                for (const target of counterbalancedOrder(config.targets, sample)) {
                    process.stderr.write(`benchmark startup ${profile} ${sample + 1}/${config.startupSamples} ${target.label}\n`);
                    output.results[target.label][profile].startupSamples.push(
                        await startupSample(browser, config, target, profile, sample + 1),
                    );
                }
            }
            for (let run = 0; run < config.traversalRuns; run += 1) {
                for (const target of counterbalancedOrder(config.targets, run)) {
                    process.stderr.write(`benchmark warm ${profile} ${run + 1}/${config.traversalRuns} ${target.label}\n`);
                    output.results[target.label][profile].warmRuns.push(
                        await warmRun(browser, config, target, profile, run + 1),
                    );
                }
            }
        }
        for (const target of config.targets) {
            for (const profile of config.profiles) {
                finalizeProfile(output.results[target.label][profile]);
            }
        }
        return output;
    } finally {
        await browser.close();
    }
}

async function main() {
    const config = loadBenchmarkConfig();
    const output = await runBenchmark(config);
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main().catch((error) => {
        console.error(error.stack || error.message);
        process.exitCode = 1;
    });
}
