/**
 * Cover Duplicate Operations (fork /duplicates_custom)
 *
 * Uses the cover-only API endpoints backed by LRR_COVER_DUPLICATE_PAIRS.
 */
import * as LRR from "./mod/common.js";

const Duplicates = {};

const DUPES_THRESHOLD_LS_KEY = "lrr.duplicates.threshold";
const DUPES_THRESHOLD_DEFAULT = 22;
const DUPES_THRESHOLD_MIN = 12;
const DUPES_THRESHOLD_MAX = 25;

const STATUS_LABELS = {
    new: "New",
    same_cover: "Same Cover",
    variant: "Variant",
    not_duplicate: "Not Duplicate",
    needs_review: "Needs Review",
    resolved: "Resolved",
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

Duplicates.state = {
    limit: 100,
    threshold: loadStoredThreshold(),
    status: "new",
    total: 0,
};

Duplicates._poller = null;

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
            const sweepDone    = s.cover_sweep_done ? " · sweep complete" : "";

            let emptyReason = "";
            if (deckSize === 0 && coverHashed === 0) {
                emptyReason = " · no cover hashes — click Find";
            } else if (deckSize === 0 && coverPending > 0) {
                emptyReason = " · pending cover compute jobs";
            } else if (deckSize === 0 && coverHashed === total) {
                emptyReason = " · no candidates under threshold";
            }

            $("#dupes-stats").text(
                `deck: ${deckSize}/${deckTarget} · covers: ${coverHashed}/${total} (pending ${coverPending}, errored ${coverErrored}) · last scan: ${lastScan}${sweepDone}${emptyReason}`,
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

Duplicates.loadPairs = function () {
    const url =
        new LRR.ApiURL("/api/duplicates/cover/pairs") +
        `?threshold=${encodeURIComponent(Duplicates.state.threshold)}` +
        `&limit=${Duplicates.state.limit}` +
        `&status=${encodeURIComponent(Duplicates.state.status)}`;

    $("#dupes-list").html("<div class=\"dupes-loading\"><i class=\"fas fa-spinner fa-spin\"></i> Loading pairs…</div>");
    fetch(url)
        .then((r) => r.json())
        .then((data) => {
            Duplicates.state.total = data.filtered_total !== undefined ? data.filtered_total : (data.total || 0);
            Duplicates.renderPairs(data.pairs || []);
            Duplicates._focusIdx = -1;
        })
        .catch(() => {
            $("#dupes-list").text("failed to load pairs");
        });
};

Duplicates.renderPairs = function (pairs) {
    const $list = $("#dupes-list").empty();
    if (!pairs.length) {
        let reason;
        const statsText = $("#dupes-stats").text();
        if (statsText.includes("pending cover compute")) {
            reason = "Cover hash computation is still in progress. Run Find Cover to queue missing hashes.";
        } else if (statsText.includes("no cover hashes")) {
            reason = "No cover hashes yet. Click Find Cover to start.";
        } else if (Duplicates.state.status !== "new") {
            reason = `No pairs with status "${STATUS_LABELS[Duplicates.state.status] || Duplicates.state.status}".`;
        } else {
            reason = "No cover pairs found at this threshold. Try a higher threshold or click Find Cover.";
        }
        $list.html(`<div class="dupes-empty-state">${reason}</div>`);
        return;
    }
    pairs.forEach((p, idx) => {
        const status = p.status || "new";
        const statusLabel = STATUS_LABELS[status] || status;

        const $card = $(`<div class="dupe-pair-card" data-idx="${idx}"></div>`);

        // Header: score + status badge
        const $header = $(`<div class="dupe-card-header"></div>`);
        $header.append(`<span class="dupe-score"><span class="dupe-pass-badge">COVER</span> hamming ${(p.cover_hamming ?? p.score).toFixed(0)}</span>`);
        $header.append(`<span class="dupe-status-badge status-${status}">${statusLabel}</span>`);
        $card.append($header);

        // Reason chips
        const chips = [];
        if (p.cover_hamming !== undefined) chips.push(`pHash ${p.cover_hamming.toFixed(0)}`);
        if (status !== "new") chips.push(statusLabel);
        if (chips.length) {
            const $chips = $(`<div class="dupe-reason-chips"></div>`);
            chips.forEach((c) => $chips.append(`<span class="dupe-reason-chip">${c}</span>`));
            $card.append($chips);
        }

        // Status action buttons
        const $statusRow = $(`<div class="dupe-status-actions"></div>`);
        const pairMember = `${p.id_a}|${p.id_b}`;
        const actions = [
            ["same_cover", "Same Cover"],
            ["variant", "Variant"],
            ["not_duplicate", "Not Duplicate"],
        ];
        actions.forEach(([s, label]) => {
            $statusRow.append(
                `<button class="stdbtn" data-action="status" data-pair="${pairMember}" data-status="${s}">${label}</button>`,
            );
        });
        $card.append($statusRow);

        const renderSide = (side, archive) => {
            const $side = $(`<div class="dupe-side"></div>`);
            $side.append(
                `<a href="${new LRR.ApiURL("/reader?id=" + encodeURIComponent(archive.arcid))}">` +
                    `<img class="dupe-thumb" src="${new LRR.ApiURL("/api/archives/" + encodeURIComponent(archive.arcid) + "/thumbnail")}" alt="${LRR.encodeHTML(archive.title || "")}" loading="lazy" />` +
                    `</a>`,
            );
            $side.append(`<div class="dupe-title">${$(`<div></div>`).text(archive.title || archive.name).html()}</div>`);
            const sizeBytes = archive.arcsize || 0;
            const sizeMB = sizeBytes >= 1073741824
                ? (sizeBytes / 1073741824).toFixed(2) + " GB"
                : (sizeBytes / 1048576).toFixed(1) + " MB";
            const metaParts = [`${archive.pagecount}p`, sizeMB];
            if (archive.language) metaParts.push(archive.language);
            if (archive.date_added) {
                const ts = parseInt(archive.date_added, 10);
                metaParts.push(Number.isFinite(ts) && ts > 0
                    ? new Date(ts * 1000).toISOString().slice(0, 10)
                    : archive.date_added);
            }
            metaParts.push(`${archive.tag_count || 0} tags`);
            const $meta = $(`<div class="dupe-meta"></div>`).text(metaParts.join(" · "));
            $side.append($meta);
            $side.append(
                `<button class="stdbtn dupe-delete" data-arcid="${archive.arcid}" data-side="${side}">Delete this side</button>`,
            );
            return $side;
        };

        const $row = $(`<div class="dupe-row"></div>`);
        $row.append(renderSide("a", p.a));
        const $mid = $(`<div class="dupe-middle"></div>`);
        $mid.append(
            `<button class="stdbtn dupe-dismiss" data-pair="${pairMember}">Not a duplicate</button>`,
        );
        $row.append($mid);
        $row.append(renderSide("b", p.b));
        $card.append($row);
        $list.append($card);
    });
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
        new LRR.ApiURL("/api/archives/" + encodeURIComponent(arcid)),
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

Duplicates.updateStatus = function (pair, status) {
    return Duplicates.fetchJSON(
        new LRR.ApiURL("/api/duplicates/cover/status"),
        {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ pair, status }),
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

// Keyboard navigation
Duplicates._focusIdx = -1;
Duplicates.focusCard = function (idx) {
    Duplicates._focusIdx = idx;
    $(".dupe-pair-card").removeClass("focused");
    const $card = $(`.dupe-pair-card[data-idx="${idx}"]`);
    if ($card.length) {
        $card.addClass("focused");
        $card[0].scrollIntoView({ behavior: "smooth", block: "center" });
    }
};

Duplicates.focusNext = function () {
    const total = $(".dupe-pair-card").length;
    if (!total) return;
    const next = (Duplicates._focusIdx + 1) % total;
    Duplicates.focusCard(next);
};

Duplicates.getFocusedPair = function () {
    const $card = $(".dupe-pair-card.focused");
    if (!$card.length) return null;
    const $btn = $card.find(".dupe-dismiss");
    return $btn.data("pair") || null;
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
                LRR.showPopUp({ title: "Refresh failed", text: String(err), icon: "error" });
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
                LRR.showPopUp({ title: "Could not queue cover pass", text: String(err), icon: "error" });
            });
    });

    // Status action buttons
    $("#dupes-list").on("click", "[data-action='status']", function () {
        const pair   = $(this).data("pair");
        const status = $(this).data("status");
        Duplicates.updateStatus(pair, status)
            .then(() => Duplicates.loadPairs())
            .catch((err) => {
                LRR.showPopUp({ title: "Status update failed", text: String(err), icon: "error" });
            });
    });

    $("#dupes-list").on("click", ".dupe-delete", function () {
        const arcid = $(this).data("arcid");
        LRR.showPopUp({
            title: "Delete archive?",
            text: "This permanently deletes the archive file.",
            icon: "warning",
            showCancelButton: true,
        }).then((res) => {
            if (!res.isConfirmed) return;
            Duplicates.deleteArchive(arcid)
                .then(() => {
                    Duplicates.loadPairs();
                    Duplicates.refreshStats();
                })
                .catch((err) => {
                    LRR.showPopUp({ title: "Delete failed", text: String(err), icon: "error" });
                });
        });
    });

    $("#dupes-list").on("click", ".dupe-dismiss", function () {
        const pair = $(this).data("pair");
        Duplicates.dismissPair(pair)
            .then(() => {
                Duplicates.loadPairs();
                Duplicates.refreshStats();
            })
            .catch((err) => {
                LRR.showPopUp({ title: "Dismiss failed", text: String(err), icon: "error" });
            });
    });

    // Keyboard shortcuts
    $(document).on("keydown", function (e) {
        // Ignore when input/textarea is focused
        if ($(e.target).is("input, textarea, select")) return;

        // n = next pair
        if (e.key === "n" || e.key === "N") {
            e.preventDefault();
            Duplicates.focusNext();
            return;
        }

        // d = dismiss focused pair
        if (e.key === "d" || e.key === "D") {
            e.preventDefault();
            const pair = Duplicates.getFocusedPair();
            if (pair) {
                Duplicates.dismissPair(pair)
                    .then(() => {
                        Duplicates.loadPairs();
                        Duplicates.refreshStats();
                    })
                    .catch((err) => {
                        LRR.showPopUp({ title: "Dismiss failed", text: String(err), icon: "error" });
                    });
            }
            return;
        }

        // 1 = same_cover, 2 = variant, 3 = not_duplicate
        const statusMap = { "1": "same_cover", "2": "variant", "3": "not_duplicate" };
        const s = statusMap[e.key];
        if (s) {
            e.preventDefault();
            const pair = Duplicates.getFocusedPair();
            if (pair) {
                Duplicates.updateStatus(pair, s)
                    .then(() => Duplicates.loadPairs())
                    .catch((err) => {
                        LRR.showPopUp({ title: "Status update failed", text: String(err), icon: "error" });
                    });
            }
        }
    });

    // Click on card to focus it
    $("#dupes-list").on("click", ".dupe-pair-card", function () {
        const idx = parseInt($(this).data("idx"), 10);
        Duplicates.focusCard(idx);
    });
});
