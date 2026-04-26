"use strict";

const Duplicates = {};

Duplicates.state = {
    offset: 0,
    limit: 100,
    threshold: 25,
    total: 0,
};

Duplicates._poller = null;

Duplicates.refreshStats = function () {
    fetch(new LRR.apiURL("/api/duplicates/stats"))
        .then((r) => r.json())
        .then((s) => {
            const pending = s.archives_pending || 0;
            const hashed = s.archives_with_hashes || 0;
            const total = s.archives_total || 0;
            const lastScan = s.last_scan_ts ? new Date(s.last_scan_ts * 1000).toLocaleString() : "never";
            $("#dupes-stats").text(
                `pairs: ${s.total_pairs} · hashed: ${hashed}/${total} · pending: ${pending} · last scan: ${lastScan}`,
            );
            // Auto-poll while a backfill is in flight; stop once pending reaches 0.
            if (pending > 0 && Duplicates._poller === null) {
                Duplicates._poller = setInterval(Duplicates.refreshStats, 10000);
            } else if (pending === 0 && Duplicates._poller !== null) {
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
        new LRR.apiURL("/api/duplicates/pairs") +
        `?max_score=${encodeURIComponent(Duplicates.state.threshold)}` +
        `&offset=${Duplicates.state.offset}&limit=${Duplicates.state.limit}`;

    fetch(url)
        .then((r) => r.json())
        .then((data) => {
            Duplicates.state.total = data.total || 0;
            Duplicates.renderPairs(data.pairs || []);
            $("#dupes-page-info").text(
                `${Duplicates.state.offset + 1}-${Duplicates.state.offset + (data.pairs || []).length} of ${data.total || 0}`,
            );
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
        $card.append(`<div class="dupe-score">score ${p.score.toFixed(1)} · pcount Δ ${p.page_count_delta}</div>`);

        const renderSide = (side, archive) => {
            const $side = $(`<div class="dupe-side"></div>`);
            $side.append(
                `<a href="${new LRR.apiURL("/reader?id=" + encodeURIComponent(archive.arcid))}">` +
                    `<img class="dupe-thumb" src="${new LRR.apiURL("/api/archives/" + encodeURIComponent(archive.arcid) + "/thumbnail")}" alt="${LRR.encodeHTML(archive.title || "")}" />` +
                    `</a>`,
            );
            $side.append(`<div class="dupe-title">${$(`<div></div>`).text(archive.title || archive.name).html()}</div>`);
            const sizeBytes = archive.arcsize || 0;
            const sizeMB = sizeBytes >= 1073741824
                ? (sizeBytes / 1073741824).toFixed(2) + " GB"
                : (sizeBytes / 1048576).toFixed(1) + " MB";
            const tagsLbl = (archive.tag_count || 0) + " tags";
            const metaParts = [`${archive.pagecount}p`, sizeMB];
            if (archive.language)   metaParts.push(archive.language);
            if (archive.date_added) metaParts.push(archive.date_added);
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
        $mid.append(`<div class="dupe-perpage">[${(p.per_page || []).join(", ")}]</div>`);
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
        new LRR.apiURL("/api/archives/" + encodeURIComponent(arcid)),
        { method: "DELETE" },
    );
};

Duplicates.dismissPair = function (pair) {
    return Duplicates.fetchJSON(new LRR.apiURL("/api/duplicates/pairs"), {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pair }),
    });
};

Duplicates.queueFind = function () {
    return Duplicates.fetchJSON(
        new LRR.apiURL("/api/minion/find_duplicate_pairs/queue?args=[]"),
        { method: "POST" },
    );
};

Duplicates.queueBackfill = function () {
    return Duplicates.fetchJSON(
        new LRR.apiURL("/api/minion/backfill_pagehashes/queue?args=[]"),
        { method: "POST" },
    );
};

$(function () {
    Duplicates.refreshStats();
    Duplicates.loadPairs();

    $("#threshold-slider").on("input", function () {
        Duplicates.state.threshold = parseInt(this.value, 10);
        $("#threshold-value").text(this.value);
    });
    $("#threshold-slider").on("change", function () {
        Duplicates.state.offset = 0;
        Duplicates.loadPairs();
    });

    $("#preset-select").on("change", function () {
        const presets = { strict: 12, medium: 25, loose: 40, very_loose: 55 };
        const v = presets[this.value] || 25;
        Duplicates.state.threshold = v;
        $("#threshold-slider").val(v);
        $("#threshold-value").text(v);
        Duplicates.state.offset = 0;
        Duplicates.loadPairs();
    });

    $("#run-find").on("click", function () {
        Duplicates.queueFind()
            .then(() => {
                LRR.showPopUp({
                    title: "Match queued",
                    text: "Pair index will rebuild. Refresh stats periodically.",
                    icon: "info",
                });
            })
            .catch((err) => {
                LRR.showPopUp({ title: "Could not queue match", text: String(err), icon: "error" });
            });
    });

    $("#run-backfill").on("click", function () {
        Duplicates.queueBackfill()
            .then(() => {
                LRR.showPopUp({
                    title: "Backfill queued",
                    text: "Page hashes will be computed for archives missing them.",
                    icon: "info",
                });
            })
            .catch((err) => {
                LRR.showPopUp({ title: "Could not queue backfill", text: String(err), icon: "error" });
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

    $("#dupes-prev").on("click", function () {
        if (Duplicates.state.offset >= Duplicates.state.limit) {
            Duplicates.state.offset -= Duplicates.state.limit;
            Duplicates.loadPairs();
        }
    });
    $("#dupes-next").on("click", function () {
        if (Duplicates.state.offset + Duplicates.state.limit < Duplicates.state.total) {
            Duplicates.state.offset += Duplicates.state.limit;
            Duplicates.loadPairs();
        }
    });
});
