/**
 * Duplicate Operations
 */
import * as LRR from "./mod/common.js";

const Duplicates = {};

const DUPES_THRESHOLD_LS_KEY = "lrr.duplicates.threshold";
const DUPES_THRESHOLD_DEFAULT = 22;
const DUPES_THRESHOLD_MIN = 12;
const DUPES_THRESHOLD_MAX = 25;

function loadStoredThreshold() {
    try {
        const v = parseInt(window.localStorage.getItem(DUPES_THRESHOLD_LS_KEY), 10);
        if (Number.isFinite(v) && v >= DUPES_THRESHOLD_MIN && v <= DUPES_THRESHOLD_MAX) {
            return v;
        }
    } catch {
        // localStorage may be disabled (private mode); fall through to default.
    }
    return DUPES_THRESHOLD_DEFAULT;
}

function saveStoredThreshold(v) {
    try {
        window.localStorage.setItem(DUPES_THRESHOLD_LS_KEY, String(v));
    } catch {
        // Ignore — non-fatal.
    }
}

Duplicates.state = {
    limit: 100,
    threshold: loadStoredThreshold(),
    relation: "",
    total: 0,
};

Duplicates._poller = null;
Duplicates.lastCursorThreshold = null;

Duplicates.deckIsStale = function () {
    return Duplicates.lastCursorThreshold !== null
        && Duplicates.lastCursorThreshold !== Duplicates.state.threshold;
};

Duplicates.refreshStats = function () {
    fetch(new LRR.ApiURL("/api/duplicates/stats"))
        .then((r) => r.json())
        .then((s) => {
            const pending = s.archives_pending || 0;
            const hashed = s.archives_with_hashes || 0;
            const total = s.archives_total || 0;
            const deckSize = s.deck_size || 0;
            const deckTarget = s.deck_target || 100;
            Duplicates.lastCursorThreshold =
                (s.cursor_threshold !== null && s.cursor_threshold !== undefined)
                    ? s.cursor_threshold + 0
                    : null;
            const stale = Duplicates.deckIsStale();
            const sweepDone = s.sweep_done ? " · sweep complete" : "";
            const deckThr = Duplicates.lastCursorThreshold !== null
                ? ` (≤${Duplicates.lastCursorThreshold})`
                : "";
            const staleLabel = stale ? " · stale, click Find to rebuild" : "";
            const lastScan = s.last_scan_ts ? new Date(s.last_scan_ts * 1000).toLocaleString() : "never";
            const coverHashed  = s.archives_with_coverhashes || 0;
            const coverPending = s.archives_cover_pending    || 0;
            const leadHashed = s.archives_with_leadhashes || 0;
            const leadPending = s.archives_lead_pending || 0;
            const lastRelationScan = s.last_relation_scan_ts ? new Date(s.last_relation_scan_ts * 1000).toLocaleString() : "never";
            $("#dupes-stats").text(
                `deck: ${deckSize}/${deckTarget}${deckThr}${sweepDone}${staleLabel} · hashed: ${hashed}/${total} · pending: ${pending} · covers: ${coverHashed}/${total} (pending ${coverPending}) · leads: ${leadHashed}/${total} (pending ${leadPending}) · last relation scan: ${lastRelationScan} · last scan: ${lastScan}`,
            );
            // Find stays enabled while the deck threshold is stale: clicking
            // it triggers a server-side rebuild. Only block when the deck is
            // full AND already matches the slider's threshold.
            $("#run-find").prop("disabled", leadPending > 0);
            // Auto-poll while either backfill is in flight; stop once both reach 0.
            const anyPending = pending > 0 || coverPending > 0 || leadPending > 0;
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

// Shared helper: trigger a server-side rebuild when the slider/preset has
// drifted from the deck's current threshold, then refresh stats and pairs
// once the Minion job has had a moment to land.
Duplicates.rebuildDeckIfStale = function () {
    if (!Duplicates.deckIsStale()) return;
    Duplicates.queueFind()
        .then(() => {
            setTimeout(() => {
                Duplicates.refreshStats();
                Duplicates.loadPairs();
            }, 1500);
        })
        .catch((err) => {
            LRR.showPopUp({ title: "Could not rebuild deck", text: String(err), icon: "error" });
        });
};

Duplicates.loadPairs = function () {
    const url =
        new LRR.ApiURL("/api/duplicates/pairs") +
        `?max_score=${encodeURIComponent(Duplicates.state.threshold)}` +
        `&limit=${Duplicates.state.limit}` +
        (Duplicates.state.relation ? `&relation=${encodeURIComponent(Duplicates.state.relation)}` : "");

    $("#dupes-list").html("<div class=\"dupes-loading\"><i class=\"fas fa-spinner fa-spin\"></i> Loading pairs…</div>");
    fetch(url)
        .then((r) => r.json())
        .then((data) => {
            Duplicates.state.total = data.filtered_total !== undefined ? data.filtered_total : (data.total || 0);
            Duplicates.renderPairs(data.pairs || []);
        })
        .catch(() => {
            $("#dupes-list").text("failed to load pairs");
        });
};

Duplicates.renderPairs = function (pairs) {
    const $list = $("#dupes-list").empty();
    if (!pairs.length) {
        $list.text("No pairs at this threshold.");
        return;
    }
    pairs.forEach((p) => {
        const $card = $(`<div class="dupe-pair-card"></div>`);
        const isCover = p.pass === "cover";
        const hasRelation = !!p.relation;
        const passBadge = isCover ? `<span class="dupe-pass-badge" title="Found by the cover-only pass">COVER</span> ` : "";
        const relationBadge = hasRelation
            ? `<span class="dupe-relation-badge">${LRR.encodeHTML(p.relation.replace(/_/g, " "))}</span> `
            : "";
        let scoreLabel = `score ${p.score.toFixed(1)} · pcount Δ ${p.page_count_delta}`;
        if (hasRelation) {
            scoreLabel = `${relationBadge}confidence ${Math.round((p.confidence || 0) * 100)}% · lead ${p.lead_hamming} · title ${Math.round((p.title_score || 0) * 100)}%`;
        } else if (isCover) {
            scoreLabel = `${passBadge}cover hamming ${p.score.toFixed(0)} · pcount Δ ${p.page_count_delta}`;
        }
        $card.append(`<div class="dupe-score">${scoreLabel}</div>`);
        if ((p.risk_flags || []).length) {
            const flags = (p.risk_flags || []).map((flag) => LRR.encodeHTML(flag.replace(/_/g, " "))).join(" · ");
            $card.append(`<div class="dupe-risk">${flags}</div>`);
        }

        const renderSide = (side, archive) => {
            const isDelete = archive.arcid === p.suggested_delete;
            const isKeep = archive.arcid === p.suggested_keep;
            const roleClass = isDelete ? " dupe-suggest-delete" : isKeep ? " dupe-suggest-keep" : "";
            const $side = $(`<div class="dupe-side${roleClass}"></div>`);
            if (isDelete || isKeep) {
                $side.append(`<div class="dupe-side-role">${isDelete ? "Suggested delete" : "Suggested keep"}</div>`);
            }
            $side.append(
                `<a href="${new LRR.ApiURL("/reader?id=" + encodeURIComponent(archive.arcid))}">` +
                    `<img class="dupe-thumb" src="${new LRR.ApiURL("/api/archives/" + encodeURIComponent(archive.arcid) + "/thumbnail")}" alt="${LRR.encodeHTML(archive.title || "")}" />` +
                    `</a>`,
            );
            $side.append(`<div class="dupe-title">${$(`<div></div>`).text(archive.title || archive.name).html()}</div>`);
            const sizeBytes = archive.arcsize || 0;
            const sizeMB = sizeBytes >= 1073741824
                ? (sizeBytes / 1073741824).toFixed(2) + " GB"
                : (sizeBytes / 1048576).toFixed(1) + " MB";
            const tagsLbl = (archive.tag_count || 0) + " tags";
            const metaParts = [`${archive.pagecount}p`, sizeMB];
            if (archive.language) metaParts.push(archive.language);
            if (archive.date_added) {
                const ts = parseInt(archive.date_added, 10);
                metaParts.push(Number.isFinite(ts) && ts > 0
                    ? new Date(ts * 1000).toISOString().slice(0, 10)
                    : archive.date_added);
            }
            metaParts.push(tagsLbl);
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
        if (hasRelation) {
            $mid.append(`<div class="dupe-perpage">${LRR.encodeHTML(p.suggested_action || "review")}</div>`);
            $mid.append(`<div class="dupe-perpage">page ratio ${Math.round((p.page_ratio || 0) * 100)}%</div>`);
        } else {
            $mid.append(`<div class="dupe-perpage">[${(p.per_page || []).join(", ")}]</div>`);
        }
        $mid.append(
            `<button class="stdbtn dupe-dismiss" data-pair="${p.id_a}|${p.id_b}">Not a duplicate</button>`,
        );
        $row.append($mid);
        $row.append(renderSide("b", p.b));
        $card.append($row);
        $list.append($card);
    });
};

// Wrapper that surfaces both network failures and JSON-level error fields.
// Without this, a 5xx with a JSON {error: "..."} body silently looks identical
// to success because fetch resolves on any HTTP status.
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
    return Duplicates.fetchJSON(new LRR.ApiURL("/api/duplicates/pairs"), {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pair }),
    });
};

Duplicates.queueFind = function () {
    return Duplicates.fetchJSON(
        new LRR.ApiURL("/api/minion/find_relation_duplicates/queue?args=[]"),
        { method: "POST" },
    );
};

Duplicates.queueBackfill = function () {
    return Duplicates.fetchJSON(
        new LRR.ApiURL("/api/minion/backfill_dedup_signals/queue?args=[]"),
        { method: "POST" },
    );
};

Duplicates.queueCoverBackfill = function () {
    return Duplicates.fetchJSON(
        new LRR.ApiURL("/api/minion/backfill_coverhashes/queue?args=[]"),
        { method: "POST" },
    );
};

// Cover pass uses raw Hamming distance (0..64) on a single hash, not the
// pcount-weighted score. The slider's threshold (12..25) lives in the same
// numeric range as plausible Hamming caps, so we reuse it as the cover cap.
// 12 ≈ near-identical covers, 25 ≈ visually similar; higher floods.
Duplicates.queueFindCover = function () {
    const args = JSON.stringify([Duplicates.state.threshold]);
    return Duplicates.fetchJSON(
        new LRR.ApiURL("/api/minion/find_cover_duplicates/queue?args=" + encodeURIComponent(args)),
        { method: "POST" },
    );
};

Duplicates.refreshDeck = function () {
    return Duplicates.fetchJSON(
        new LRR.ApiURL("/api/duplicates/refresh"),
        { method: "POST" },
    );
};

$(function () {
    // Sync the slider/dropdown/label to the persisted threshold the page
    // started with — the template's hardcoded `value` would otherwise
    // override it on every reload.
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
        Duplicates.rebuildDeckIfStale();
    });

    $("#preset-select").on("change", function () {
        const v = parseInt(this.value, 10) || DUPES_THRESHOLD_DEFAULT;
        Duplicates.state.threshold = v;
        saveStoredThreshold(v);
        $("#threshold-slider").val(v);
        $("#threshold-value").text(v);
        Duplicates.loadPairs();
        Duplicates.refreshStats();
        Duplicates.rebuildDeckIfStale();
    });

    $("#relation-select").on("change", function () {
        Duplicates.state.relation = this.value;
        Duplicates.loadPairs();
    });

    $("#run-find").on("click", function () {
        Duplicates.queueFind()
            .then(() => {
                setTimeout(() => {
                    Duplicates.refreshStats();
                    Duplicates.loadPairs();
                }, 1500);
            })
            .catch((err) => {
                LRR.showPopUp({ title: "Could not queue match", text: String(err), icon: "error" });
            });
    });

    // Refresh deck: drop pairs that are already dismissed or that point at
    // deleted archives, then queue a find to top the deck back up to 100.
    $("#run-refresh").on("click", function () {
        const $btn = $(this).prop("disabled", true);
        Duplicates.refreshDeck()
            .then((res) => {
                const cleaned = res.total_removed || 0;
                return Duplicates.queueFind().then(() => cleaned);
            })
            .then(() => {
                // Stats refresh below makes the cleanup visible (deck size
                // drops, then climbs back up after the find job lands), so
                // there's no toast/popup here. The page doesn't load the
                // react-toastify bundle either.
                setTimeout(() => {
                    Duplicates.refreshStats();
                    Duplicates.loadPairs();
                    $btn.prop("disabled", false);
                }, 1500);
            })
            .catch((err) => {
                $btn.prop("disabled", false);
                LRR.showPopUp({ title: "Refresh failed", text: String(err), icon: "error" });
            });
    });

    $("#run-backfill").on("click", function () {
        Duplicates.queueBackfill()
            .then(() => {
                LRR.showPopUp({
                    title: "Backfill queued",
                    text: "Lead-page dedup signals will be computed for archives missing them.",
                    icon: "info",
                });
            })
            .catch((err) => {
                LRR.showPopUp({ title: "Could not queue backfill", text: String(err), icon: "error" });
            });
    });

    // Cover pass: queues backfill (no-op for archives already coverhashed)
    // and the matcher in one shot. Backfill runs first by enqueue order;
    // matcher only stores pairs over archives whose coverhash_v matches the
    // configured cover_algo_version, so it self-skips archives still pending.
    $("#run-find-cover").on("click", function () {
        Duplicates.queueCoverBackfill()
            .then(() => Duplicates.queueFindCover())
            .then(() => {
                setTimeout(() => {
                    Duplicates.refreshStats();
                    Duplicates.loadPairs();
                }, 1500);
            })
            .catch((err) => {
                LRR.showPopUp({ title: "Could not queue cover pass", text: String(err), icon: "error" });
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

});
