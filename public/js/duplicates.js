"use strict";

const Duplicates = {};

Duplicates.state = {
    offset: 0,
    limit: 50,
    threshold: 25,
    total: 0,
};

Duplicates.refreshStats = function () {
    fetch(LRR.apiURL("/api/duplicates/stats"))
        .then((r) => r.json())
        .then((s) => {
            const pending = s.archives_pending || 0;
            const hashed = s.archives_with_hashes || 0;
            const total = s.archives_total || 0;
            const lastScan = s.last_scan_ts ? new Date(s.last_scan_ts * 1000).toLocaleString() : "never";
            $("#dupes-stats").text(
                `pairs: ${s.total_pairs} · hashed: ${hashed}/${total} · pending: ${pending} · last scan: ${lastScan}`,
            );
        })
        .catch(() => {
            $("#dupes-stats").text("stats unavailable");
        });
};

Duplicates.loadPairs = function () {
    const url =
        LRR.apiURL("/api/duplicates/pairs") +
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
                `<a href="${LRR.apiURL("/reader?id=" + encodeURIComponent(archive.arcid))}">` +
                    `<img class="dupe-thumb" src="${LRR.apiURL("/api/archives/" + encodeURIComponent(archive.arcid) + "/thumbnail")}" alt="${archive.title}" />` +
                    `</a>`,
            );
            $side.append(`<div class="dupe-title">${$(`<div></div>`).text(archive.title || archive.name).html()}</div>`);
            $side.append(`<div class="dupe-meta">${archive.pagecount}p</div>`);
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

Duplicates.deleteArchive = function (arcid) {
    return fetch(LRR.apiURL("/api/archives/" + encodeURIComponent(arcid)), { method: "DELETE" })
        .then((r) => r.json());
};

Duplicates.dismissPair = function (pair) {
    return fetch(LRR.apiURL("/api/duplicates/pairs"), {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pair }),
    }).then((r) => r.json());
};

Duplicates.queueFind = function () {
    return fetch(LRR.apiURL("/api/minion/find_duplicate_pairs/queue"), { method: "POST" })
        .then((r) => r.json());
};

Duplicates.queueBackfill = function () {
    return fetch(LRR.apiURL("/api/minion/backfill_pagehashes/queue"), { method: "POST" })
        .then((r) => r.json());
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
        Duplicates.queueFind().then(() => {
            LRR.showPopUp({
                title: "Match queued",
                text: "Pair index will rebuild. Refresh stats periodically.",
                icon: "info",
            });
        });
    });

    $("#run-backfill").on("click", function () {
        Duplicates.queueBackfill().then(() => {
            LRR.showPopUp({
                title: "Backfill queued",
                text: "Page hashes will be computed for archives missing them.",
                icon: "info",
            });
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
            Duplicates.deleteArchive(arcid).then(() => {
                Duplicates.loadPairs();
                Duplicates.refreshStats();
            });
        });
    });

    $("#dupes-list").on("click", ".dupe-dismiss", function () {
        const pair = $(this).data("pair");
        Duplicates.dismissPair(pair).then(() => {
            Duplicates.loadPairs();
            Duplicates.refreshStats();
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
