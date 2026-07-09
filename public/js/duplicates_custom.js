/**
 * Cover Duplicate Operations (fork /duplicates_custom)
 *
 * Uses the cover-only API endpoints backed by LRR_COVER_DUPLICATE_PAIRS.
 */
import * as LRR from "./mod/common.js";
import I18N from "i18n";

const Duplicates = {};

const DUPES_THRESHOLD_LS_KEY = "lrr.duplicates.threshold";
const DUPES_THRESHOLD_DEFAULT = 22;
const DUPES_THRESHOLD_MIN = 12;
const DUPES_THRESHOLD_MAX = 25;
const REVIEW_BATCH_SIZE = 24;
const TOP_UP_THRESHOLD = 6;

const STATUS_LABELS = {
    new: I18N.DuplicatesNew,
    same_cover: I18N.DuplicatesSameCover,
    variant: I18N.DuplicatesVariant,
    not_duplicate: I18N.DuplicatesNotDuplicate,
    needs_review: I18N.DuplicatesNeedsReview,
    resolved: I18N.DuplicatesResolved,
};

function loadStoredThreshold() {
    try {
        const v = parseInt(window.localStorage.getItem(DUPES_THRESHOLD_LS_KEY), 10);
        if (Number.isFinite(v) && v >= DUPES_THRESHOLD_MIN && v <= DUPES_THRESHOLD_MAX) {
            return v;
        }
    } catch { /* ignore */ }
    return DUPES_THRESHOLD_DEFAULT;
}

function saveStoredThreshold(v) {
    try { window.localStorage.setItem(DUPES_THRESHOLD_LS_KEY, String(v)); } catch { /* ignore */ }
}

function htmlText(value) {
    return $("<div></div>").text(value || "").html();
}

function pairMember(pair) {
    return `${pair.id_a}|${pair.id_b}`;
}

function archiveTitle(archive) {
    return archive.title || archive.name || archive.arcid || "";
}

function formatSize(bytes) {
    const sizeBytes = bytes || 0;
    if (sizeBytes >= 1073741824) {
        return `${(sizeBytes / 1073741824).toFixed(2)} GB`;
    }
    return `${(sizeBytes / 1048576).toFixed(1)} MB`;
}

function numericValue(value) {
    const numeric = Number(value || 0);
    return Number.isFinite(numeric) ? numeric : 0;
}

function optionalNumber(value) {
    if (value === undefined || value === null || value === "") return undefined;
    const numeric = Number(value);
    return Number.isFinite(numeric) ? numeric : undefined;
}

function timestampValue(value) {
    if (!value) return 0;
    const raw = String(value).trim();
    if (/^\d+$/.test(raw)) {
        const numeric = Number(raw);
        if (Number.isFinite(numeric) && numeric > 0) {
            return numeric > 9999999999 ? Math.floor(numeric / 1000) : numeric;
        }
    }
    const parsed = Date.parse(raw);
    return Number.isFinite(parsed) ? Math.floor(parsed / 1000) : 0;
}

function formatDate(value) {
    if (!value) return "";
    const ts = timestampValue(value);
    if (ts > 0) {
        return new Date(ts * 1000).toISOString().slice(0, 10);
    }
    return String(value).trim();
}

function isKoreanLanguage(language) {
    const normalized = String(language || "").trim().toLowerCase();
    return ["ko", "kor", "ko-kr", "korean"].includes(normalized);
}

function resolutionScore(archive) {
    const pixels = numericValue(archive.cover_pixels);
    if (pixels > 0) return pixels;
    return numericValue(archive.cover_width) * numericValue(archive.cover_height);
}

function formatResolution(archive) {
    const width = numericValue(archive.cover_width);
    const height = numericValue(archive.cover_height);
    if (width > 0 && height > 0) return `${width}x${height}`;
    return I18N.DuplicatesUnknown;
}

function compareArchiveSignals(archive, otherArchive) {
    const date = timestampValue(archive.date_added);
    const otherDate = timestampValue(otherArchive.date_added);
    const korean = isKoreanLanguage(archive.language);
    const otherKorean = isKoreanLanguage(otherArchive.language);

    return {
        pages: numericValue(archive.pagecount) > numericValue(otherArchive.pagecount),
        size: numericValue(archive.arcsize) > numericValue(otherArchive.arcsize),
        tags: numericValue(archive.tag_count) > numericValue(otherArchive.tag_count),
        language: korean && !otherKorean,
        resolution: resolutionScore(archive) > resolutionScore(otherArchive),
        recent: date > 0 && otherDate > 0 && date > otherDate,
    };
}

function buildResolutionChips(archive, otherArchive) {
    const signals = compareArchiveSignals(archive, otherArchive);
    const language = archive.language || I18N.DuplicatesUnknown;
    return [
        { kind: "pages", label: I18N.DuplicatesPages, value: String(numericValue(archive.pagecount)), highlighted: signals.pages },
        { kind: "size", label: I18N.DuplicatesSize, value: formatSize(numericValue(archive.arcsize)), highlighted: signals.size },
        { kind: "tags", label: I18N.DuplicatesTags, value: String(numericValue(archive.tag_count)), highlighted: signals.tags },
        { kind: "language", label: "KR", value: isKoreanLanguage(language) ? I18N.DuplicatesKorean : language, highlighted: signals.language },
        { kind: "resolution", label: I18N.DuplicatesResolution, value: formatResolution(archive), highlighted: signals.resolution },
        { kind: "recent", label: I18N.DuplicatesDate, value: formatDate(archive.date_added) || I18N.DuplicatesUnknown, highlighted: signals.recent },
    ];
}

function thumbnailUrl(arcid) {
    return new LRR.ApiURL(`/api/archives/${encodeURIComponent(arcid)}/thumbnail`);
}

function readerUrl(arcid) {
    return new LRR.ApiURL(`/reader?id=${encodeURIComponent(arcid)}`);
}

function pairIncludesArchive(pair, archiveId) {
    return pair.id_a === archiveId || pair.id_b === archiveId;
}

function sideLabel(side) {
    return side === "a" ? I18N.DuplicatesLeft : I18N.DuplicatesRight;
}

function oppositeSide(side) {
    return side === "a" ? "b" : "a";
}

Duplicates.state = {
    limit: REVIEW_BATCH_SIZE,
    threshold: loadStoredThreshold(),
    status: "new",
    total: 0,
    pairs: [],
    activeIndex: 0,
    reviewedCount: 0,
    reviewedPairs: new Set(),
    activePairRenderedAt: 0,
    loadingMore: false,
};

Duplicates._poller = null;

Duplicates.updateReviewMetrics = function () {
    $("#dupes-review-count").text(I18N.DuplicatesReviewed(Duplicates.state.reviewedCount));
    const queueTotal = Duplicates.state.total || Duplicates.state.pairs.length;
    $("#dupes-queue-count").text(`${Duplicates.state.pairs.length}/${queueTotal}`);
};

Duplicates.refreshStats = function () {
    fetch(new LRR.ApiURL("/api/duplicates/cover/stats"))
        .then((r) => r.json())
        .then((s) => {
            const coverHashed  = s.archives_with_coverhashes || 0;
            const coverPending = s.archives_cover_pending    || 0;
            const coverErrored = s.archives_cover_errored    || 0;
            const total        = s.archives_total            || 0;
            const deckSize     = s.deck_size || 0;
            const deckTarget   = s.deck_target || 100;
            const lastScan     = s.last_scan_ts ? new Date(s.last_scan_ts * 1000).toLocaleString() : "never";
            const sweepDone    = s.cover_sweep_done ? " - sweep complete" : "";

            let emptyReason = "";
            if (deckSize === 0 && coverHashed === 0) {
                emptyReason = " - no cover hashes; click Find";
            } else if (deckSize === 0 && coverPending > 0) {
                emptyReason = " - pending cover compute jobs";
            } else if (deckSize === 0 && coverHashed === total) {
                emptyReason = " - no candidates under threshold";
            }

            $("#dupes-stats").text(
                `deck: ${deckSize}/${deckTarget} - covers: ${coverHashed}/${total} (pending ${coverPending}, errored ${coverErrored}) - last scan: ${lastScan}${sweepDone}${emptyReason}`,
            );

            const anyPending = coverPending > 0;
            if (anyPending && Duplicates._poller === null) {
                Duplicates._poller = setInterval(Duplicates.refreshStats, 10000);
            } else if (!anyPending && Duplicates._poller !== null) {
                clearInterval(Duplicates._poller);
                Duplicates._poller = null;
            }
        })
        .catch(() => {
            $("#dupes-stats").text("stats unavailable");
        });
};

Duplicates.buildPairsURL = function (limit = Duplicates.state.limit) {
    return new LRR.ApiURL("/api/duplicates/cover/pairs") +
        `?threshold=${encodeURIComponent(Duplicates.state.threshold)}` +
        `&limit=${encodeURIComponent(limit)}` +
        `&status=${encodeURIComponent(Duplicates.state.status)}`;
};

Duplicates.fetchPairs = function (limit = Duplicates.state.limit) {
    return fetch(Duplicates.buildPairsURL(limit)).then((r) => r.json());
};

Duplicates.loadPairs = function () {
    $("#dupes-list").html(`<div class="dupes-loading"><i class="fas fa-spinner fa-spin"></i> ${I18N.DuplicatesLoadingPairs}</div>`);
    $("#dupes-queue-list").empty();
    return Duplicates.fetchPairs(Duplicates.state.limit)
        .then((data) => {
            Duplicates.state.total = data.filtered_total !== undefined ? data.filtered_total : (data.total || 0);
            Duplicates.state.pairs = data.pairs || [];
            Duplicates.state.activeIndex = 0;
            Duplicates.state.reviewedPairs = new Set();
            Duplicates.state.activePairRenderedAt = 0;
            Duplicates.renderActivePair();
            Duplicates.renderQueueRail();
            Duplicates.updateReviewMetrics();
        })
        .catch(() => {
            $("#dupes-list").html(`<div class="dupes-empty-state">${I18N.DuplicatesFailedLoadPairs}</div>`);
            Duplicates.renderQueueRail();
            Duplicates.updateReviewMetrics();
        });
};

Duplicates.loadMorePairs = function () {
    if (Duplicates.state.loadingMore) return Promise.resolve();
    Duplicates.state.loadingMore = true;

    return Duplicates.fetchPairs(Duplicates.state.limit)
        .then((data) => {
            Duplicates.state.total = data.filtered_total !== undefined ? data.filtered_total : (data.total || 0);
            const known = new Set(Duplicates.state.pairs.map(pairMember));
            const incoming = (data.pairs || []).filter((pair) => {
                const member = pairMember(pair);
                return !known.has(member) && !Duplicates.state.reviewedPairs.has(member);
            });

            if (incoming.length) {
                Duplicates.state.pairs.push(...incoming);
                if (Duplicates.state.pairs.length === incoming.length) {
                    Duplicates.state.activeIndex = 0;
                    Duplicates.renderActivePair();
                }
                Duplicates.renderQueueRail();
                Duplicates.updateReviewMetrics();
            }
        })
        .catch(() => { /* top-up is opportunistic */ })
        .finally(() => {
            Duplicates.state.loadingMore = false;
        });
};

Duplicates.emptyReason = function () {
    const statsText = $("#dupes-stats").text();
    if (statsText.includes("pending cover compute")) {
        return "Cover hash computation is still in progress. Run Find Cover to queue missing hashes.";
    }
    if (statsText.includes("no cover hashes")) {
        return "No cover hashes yet. Click Find Cover to start.";
    }
    if (Duplicates.state.status !== "new") {
        return `No pairs with status "${STATUS_LABELS[Duplicates.state.status] || Duplicates.state.status}".`;
    }
    return "No cover pairs found at this threshold. Try a higher threshold or click Find Cover.";
};

Duplicates.renderResolutionChips = function (archive, otherArchive) {
    return buildResolutionChips(archive, otherArchive)
        .map((chip) => {
            const classes = `dupe-resolution-chip chip-${chip.kind}${chip.highlighted ? " is-highlighted" : ""}`;
            const title = `${chip.label}: ${chip.value}`;
            return `
                <span class="${classes}" title="${htmlText(title)}">
                    <span class="dupe-chip-label">${htmlText(chip.label)}</span>
                    <span class="dupe-chip-value">${htmlText(chip.value)}</span>
                </span>
            `;
        })
        .join("");
};

Duplicates.renderSide = function (side, archive, otherArchive) {
    const sideName = sideLabel(side);
    const otherName = sideLabel(oppositeSide(side));
    const archiveId = archive.arcid || "";
    const otherArchiveId = otherArchive.arcid || "";
    const title = archiveTitle(archive);
    return `
        <section class="dupe-side dupe-side-${side}">
            <div class="dupe-side-label">${sideName}</div>
            <a class="dupe-image-frame" href="${readerUrl(archiveId)}">
                <img class="dupe-thumb" src="${thumbnailUrl(archiveId)}" alt="${LRR.encodeHTML(title)}" loading="eager" />
            </a>
            <div class="dupe-title">${htmlText(title)}</div>
            <div class="dupe-resolution-chips">${Duplicates.renderResolutionChips(archive, otherArchive)}</div>
            <div class="dupe-side-actions">
                <button class="stdbtn dupe-action" type="button" data-action="keep-side" data-side="${side}" data-delete-arcid="${otherArchiveId}">
                    ${I18N.DuplicatesKeep(sideName)}
                </button>
                <button class="stdbtn dupe-action dupe-delete-action" type="button" data-action="delete-side" data-side="${side}" data-delete-arcid="${archiveId}">
                    ${I18N.DuplicatesDelete(sideName)}
                </button>
            </div>
            <div class="dupe-side-action-note dupe-immediate-delete-note">${I18N.DuplicatesImmediateDelete(sideName, otherName)}</div>
        </section>
    `;
};

Duplicates.renderActionRail = function (pair) {
    const member = pairMember(pair);
    return `
        <div class="dupe-action-rail">
            <button class="stdbtn dupe-action" type="button" data-action="mark-status" data-pair="${member}" data-status="same_cover">${I18N.DuplicatesSameCover}</button>
            <button class="stdbtn dupe-action" type="button" data-action="mark-status" data-pair="${member}" data-status="variant">${I18N.DuplicatesVariant}</button>
            <button class="stdbtn dupe-action" type="button" data-action="mark-status" data-pair="${member}" data-status="not_duplicate">${I18N.DuplicatesNotDuplicate}</button>
            <button class="stdbtn dupe-action" type="button" data-action="mark-status" data-pair="${member}" data-status="needs_review">${I18N.DuplicatesNeedsReview}</button>
        </div>
    `;
};

Duplicates.renderReasonChips = function (pair) {
    const status = pair.status || "new";
    const chips = [];
    if (pair.cover_hamming !== undefined) chips.push(`pHash ${Number(pair.cover_hamming).toFixed(0)}`);
    if (pair.score !== undefined) chips.push(`score ${Number(pair.score).toFixed(0)}`);
    if (status !== "new") chips.push(STATUS_LABELS[status] || status);

    return chips
        .map((chip) => `<span class="dupe-reason-chip">${htmlText(chip)}</span>`)
        .join("");
};

Duplicates.renderActivePair = function () {
    if (Duplicates.state.activeIndex >= Duplicates.state.pairs.length) {
        Duplicates.state.activeIndex = Math.max(0, Duplicates.state.pairs.length - 1);
    }

    const pair = Duplicates.state.pairs[Duplicates.state.activeIndex];
    if (!pair) {
        $("#dupes-list").html(`<div class="dupes-empty-state">${Duplicates.emptyReason()}</div>`);
        Duplicates.updateReviewMetrics();
        return;
    }

    const status = pair.status || "new";
    const statusLabel = STATUS_LABELS[status] || status;
    const hamming = pair.cover_hamming !== undefined ? pair.cover_hamming : pair.score;
    Duplicates.state.activePairRenderedAt = Date.now();

    $("#dupes-list").html(`
        <article class="dupe-focus-card" data-pair="${pairMember(pair)}">
            <header class="dupe-focus-header">
                <span class="dupe-score"><span class="dupe-pass-badge">COVER</span> hamming ${Number(hamming || 0).toFixed(0)}</span>
                <span class="dupe-status-badge status-${status}">${statusLabel}</span>
            </header>
            <div class="dupe-compare-grid">
                ${Duplicates.renderSide("a", pair.a || {}, pair.b || {})}
                ${Duplicates.renderActionRail(pair)}
                ${Duplicates.renderSide("b", pair.b || {}, pair.a || {})}
            </div>
            <div class="dupe-reason-chips">${Duplicates.renderReasonChips(pair)}</div>
        </article>
    `);
    Duplicates.updateReviewMetrics();

    if (Duplicates.state.pairs.length <= TOP_UP_THRESHOLD) {
        Duplicates.loadMorePairs();
    }
};

Duplicates.renderQueueRail = function () {
    const $queue = $("#dupes-queue-list").empty();
    if (!Duplicates.state.pairs.length) {
        $queue.html(`<div class="dupes-empty-state">${I18N.DuplicatesQueueEmpty}</div>`);
        Duplicates.updateReviewMetrics();
        return;
    }

    Duplicates.state.pairs.forEach((pair, idx) => {
        const activeClass = idx === Duplicates.state.activeIndex ? " is-active" : "";
        const archiveA = pair.a || {};
        const archiveB = pair.b || {};
        const titleA = archiveTitle(archiveA);
        const titleB = archiveTitle(archiveB);
        const hamming = pair.cover_hamming !== undefined ? pair.cover_hamming : pair.score;
        $queue.append(`
            <button class="dupe-queue-item${activeClass}" type="button" data-idx="${idx}">
                <span class="dupe-queue-thumbs">
                    <img src="${thumbnailUrl(archiveA.arcid || "")}" alt="${LRR.encodeHTML(titleA)}" loading="lazy" />
                    <img src="${thumbnailUrl(archiveB.arcid || "")}" alt="${LRR.encodeHTML(titleB)}" loading="lazy" />
                </span>
                <span class="dupe-queue-copy">
                    <span class="dupe-queue-title">${htmlText(titleA || titleB)}</span>
                    <span class="dupe-queue-meta">hamming ${Number(hamming || 0).toFixed(0)}</span>
                </span>
            </button>
        `);
    });
    Duplicates.updateReviewMetrics();
};

Duplicates.setActiveIndex = function (idx) {
    if (!Duplicates.state.pairs.length) return;
    Duplicates.state.activeIndex = Math.max(0, Math.min(idx, Duplicates.state.pairs.length - 1));
    Duplicates.renderActivePair();
    Duplicates.renderQueueRail();
};

Duplicates.fetchJSON = function (url, init) {
    return fetch(url, init).then((r) => {
        return r.json().then((json) => {
            if (!r.ok || json.error) {
                throw new Error(json.error || `HTTP ${r.status}`);
            }
            return json;
        });
    });
};

Duplicates.deleteArchive = function (arcid) {
    return Duplicates.fetchJSON(
        new LRR.ApiURL(`/api/archives/${encodeURIComponent(arcid)}`),
        { method: "DELETE" },
    );
};

Duplicates.dismissPair = function (pair) {
    return Duplicates.fetchJSON(new LRR.ApiURL("/api/duplicates/cover/pairs"), {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pair }),
    });
};

Duplicates.archiveReviewSnapshot = function (archive = {}) {
    const coverWidth = optionalNumber(archive.cover_width);
    const coverHeight = optionalNumber(archive.cover_height);
    const coverPixels = optionalNumber(archive.cover_pixels);
    const snapshot = {
        arcid: archive.arcid || "",
        title: archive.title || "",
        name: archive.name || "",
        tags: archive.tags || "",
        pagecount: optionalNumber(archive.pagecount),
        arcsize: optionalNumber(archive.arcsize),
        tag_count: optionalNumber(archive.tag_count),
        language: archive.language || "",
        date_added: archive.date_added || "",
        cover_width: coverWidth,
        cover_height: coverHeight,
        cover_pixels: coverPixels !== undefined ? coverPixels : (
            coverWidth !== undefined && coverHeight !== undefined ? coverWidth * coverHeight : undefined
        ),
    };

    Object.keys(snapshot).forEach((key) => {
        if (snapshot[key] === undefined) delete snapshot[key];
    });
    return snapshot;
};

Duplicates.reviewContext = function (inputMethod) {
    const renderedAt = Duplicates.state.activePairRenderedAt || Date.now();
    return {
        input_method: inputMethod || "button",
        threshold: Duplicates.state.threshold,
        status_filter: Duplicates.state.status,
        queue_index: Duplicates.state.activeIndex,
        queue_length: Duplicates.state.pairs.length,
        dwell_ms: Math.max(0, Date.now() - renderedAt),
    };
};

Duplicates.visibleSnapshot = function (pair) {
    const score = optionalNumber(pair.score);
    const coverHamming = optionalNumber(pair.cover_hamming);
    const snapshot = {
        id_a: pair.id_a,
        id_b: pair.id_b,
        score,
        cover_hamming: coverHamming !== undefined ? coverHamming : score,
        pass: pair.pass || "cover",
        status: pair.status || "new",
        a: Duplicates.archiveReviewSnapshot(pair.a || {}),
        b: Duplicates.archiveReviewSnapshot(pair.b || {}),
    };

    Object.keys(snapshot).forEach((key) => {
        if (snapshot[key] === undefined) delete snapshot[key];
    });
    return snapshot;
};

Duplicates.reviewLogPayload = function (pair, inputMethod) {
    return {
        context: Duplicates.reviewContext(inputMethod),
        visible_snapshot: Duplicates.visibleSnapshot(pair),
    };
};

Duplicates.updateStatus = function (pair, status, reviewLogPayload = {}) {
    return Duplicates.fetchJSON(
        new LRR.ApiURL("/api/duplicates/cover/status"),
        {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ pair, status, ...reviewLogPayload }),
        },
    );
};

Duplicates.rebuildCover = function () {
    const url = new LRR.ApiURL("/api/duplicates/cover/rebuild");
    return Duplicates.fetchJSON(url, { method: "POST" });
};

Duplicates.refreshDeck = function () {
    return Duplicates.fetchJSON(
        new LRR.ApiURL("/api/duplicates/cover/refresh"),
        { method: "POST" },
    );
};

Duplicates.advanceAfterReviewAction = function ({ pair, archiveId = null }) {
    const member = pairMember(pair);
    Duplicates.state.reviewedPairs.add(member);
    Duplicates.state.reviewedCount += 1;

    if (archiveId) {
        Duplicates.state.pairs = Duplicates.state.pairs.filter((candidate) => !pairIncludesArchive(candidate, archiveId));
    } else {
        Duplicates.state.pairs = Duplicates.state.pairs.filter((candidate) => pairMember(candidate) !== member);
    }

    if (Duplicates.state.activeIndex >= Duplicates.state.pairs.length) {
        Duplicates.state.activeIndex = Math.max(0, Duplicates.state.pairs.length - 1);
    }

    Duplicates.renderActivePair();
    Duplicates.renderQueueRail();
    Duplicates.refreshStats();

    if (Duplicates.state.pairs.length <= TOP_UP_THRESHOLD) {
        Duplicates.loadMorePairs();
    }
};

Duplicates.performReviewAction = function ({ pair, action, archiveId = null, errorTitle }) {
    const $card = $("#dupes-list .dupe-focus-card");
    $card.addClass("is-busy");

    return action()
        .then(() => {
            $card.addClass("is-exiting");
            setTimeout(() => {
                Duplicates.advanceAfterReviewAction({ pair, archiveId });
            }, 160);
        })
        .catch((err) => {
            $card.removeClass("is-busy is-exiting");
            LRR.showPopUp({ title: errorTitle, text: String(err), icon: "error" });
        });
};

// Keyboard navigation
Duplicates.focusCard = function (idx) {
    Duplicates.setActiveIndex(idx);
};

Duplicates.focusNext = function () {
    Duplicates.setActiveIndex(Duplicates.state.activeIndex + 1);
};

Duplicates.focusPrevious = function () {
    Duplicates.setActiveIndex(Duplicates.state.activeIndex - 1);
};

Duplicates.getActivePair = function () {
    return Duplicates.state.pairs[Duplicates.state.activeIndex] || null;
};

Duplicates.getFocusedPair = function () {
    const pair = Duplicates.getActivePair();
    return pair ? pairMember(pair) : null;
};

Duplicates.applyStatusToActivePair = function (status, inputMethod = "keyboard") {
    const pair = Duplicates.getActivePair();
    if (!pair) return;
    const member = pairMember(pair);
    Duplicates.performReviewAction({
        pair,
        action: () => Duplicates.updateStatus(member, status, Duplicates.reviewLogPayload(pair, inputMethod)),
        errorTitle: I18N.DuplicatesStatusFailed,
    });
};

$(function () {
    const initial = Duplicates.state.threshold;
    $("#threshold-slider").val(initial);
    $("#threshold-value").text(initial);
    $("#preset-select").val(String(initial));

    Duplicates.refreshStats();
    Duplicates.loadPairs();

    $("#return").on("click", function () {
        window.location.href = new LRR.ApiURL("/");
    });

    $("#threshold-slider").on("input", function () {
        Duplicates.state.threshold = parseInt(this.value, 10);
        $("#threshold-value").text(this.value);
    });
    $("#threshold-slider").on("change", function () {
        saveStoredThreshold(Duplicates.state.threshold);
        $("#preset-select").val(String(Duplicates.state.threshold));
        Duplicates.loadPairs();
        Duplicates.refreshStats();
    });

    $("#preset-select").on("change", function () {
        const v = parseInt(this.value, 10) || DUPES_THRESHOLD_DEFAULT;
        Duplicates.state.threshold = v;
        saveStoredThreshold(v);
        $("#threshold-slider").val(v);
        $("#threshold-value").text(v);
        Duplicates.loadPairs();
        Duplicates.refreshStats();
    });

    $("#status-select").on("change", function () {
        Duplicates.state.status = this.value;
        Duplicates.loadPairs();
    });

    $("#run-refresh").on("click", function () {
        const $btn = $(this).prop("disabled", true);
        Duplicates.refreshDeck()
            .then(() => Duplicates.rebuildCover())
            .then(() => {
                setTimeout(() => {
                    Duplicates.refreshStats();
                    Duplicates.loadPairs();
                    $btn.prop("disabled", false);
                }, 2000);
            })
            .catch((err) => {
                $btn.prop("disabled", false);
                LRR.showPopUp({ title: I18N.DuplicatesRefreshFailed, text: String(err), icon: "error" });
            });
    });

    $("#run-find-cover").on("click", function () {
        const $btn = $(this).prop("disabled", true);
        Duplicates.rebuildCover()
            .then(() => {
                setTimeout(() => {
                    Duplicates.refreshStats();
                    Duplicates.loadPairs();
                    $btn.prop("disabled", false);
                }, 2000);
            })
            .catch((err) => {
                $btn.prop("disabled", false);
                LRR.showPopUp({ title: I18N.DuplicatesQueueFailed, text: String(err), icon: "error" });
            });
    });

    $("#dupes-active-stage").on("click", ".dupe-action", function () {
        const $button = $(this);
        const pair = Duplicates.getActivePair();
        if (!pair) return;

        const actionType = $button.attr("data-action");
        if (actionType === "mark-status") {
            const status = $button.attr("data-status");
            Duplicates.performReviewAction({
                pair,
                action: () => Duplicates.updateStatus(pairMember(pair), status, Duplicates.reviewLogPayload(pair, "button")),
                errorTitle: I18N.DuplicatesStatusFailed,
            });
            return;
        }

        const archiveId = $button.attr("data-delete-arcid");
        if (!archiveId) {
            LRR.showPopUp({ title: I18N.DuplicatesArchiveMissing, text: I18N.DuplicatesArchiveMissingDetail, icon: "error" });
            return;
        }
        Duplicates.performReviewAction({
            pair,
            archiveId,
            action: () => Duplicates.deleteArchive(archiveId),
            errorTitle: I18N.DuplicatesDeleteFailed,
        });
    });

    $("#dupes-queue-list").on("click", ".dupe-queue-item", function () {
        Duplicates.focusCard(parseInt($(this).attr("data-idx"), 10));
    });

    $(document).on("keydown", function (e) {
        if ($(e.target).is("input, textarea, select")) return;

        if (e.key === "n" || e.key === "N") {
            e.preventDefault();
            Duplicates.focusNext();
            return;
        }
        if (e.key === "p" || e.key === "P") {
            e.preventDefault();
            Duplicates.focusPrevious();
            return;
        }

        const statusMap = {
            s: "same_cover",
            S: "same_cover",
            v: "variant",
            V: "variant",
            x: "not_duplicate",
            X: "not_duplicate",
            r: "needs_review",
            R: "needs_review",
        };
        const status = statusMap[e.key];
        if (status) {
            e.preventDefault();
            Duplicates.applyStatusToActivePair(status);
        }
    });
});
