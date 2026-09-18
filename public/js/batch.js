/**
 * Batch Operations
 */
import * as LRR from "lrr-common";
import * as Server from "lrr-server";
import I18N from "i18n";
import { createBatchSession } from "lrr-batch-session";
import { createBatchArchiveLoader, validBatchSelection } from "lrr-batch-archive-loader";

const Batch = {};

Batch.session = null;
Batch.reloadTimer = null;
Batch.treatedArchives = 0;
Batch.totalArchives = 0;
Batch.currentOperation = "";
Batch.currentPlugin = "";

Batch.appendLog = function (message) {
    document.getElementById("log-container").append(document.createTextNode(String(message ?? "")));
};

Batch.initializeAll = function () {
    // bind events to DOM
    $(document).on("change.batch-operation", "#batch-operation", Batch.selectOperation);
    $(document).on("change.plugin", "#plugin", Batch.showOverride);
    $(document).on("click.override", "#override", Batch.showOverride);
    $(document).on("click.check-uncheck", "#check-uncheck", Batch.checkAll);
    $(document).on("click.start-batch", "#start-batch", Batch.startBatchCheck);
    $(document).on("click.restart-job", "#restart-job", Batch.restartBatchUI);
    $(document).on("click.cancel-job", "#cancel-job", Batch.cancelBatch);
    $(document).on("click.server-config", "#server-config", () => LRR.openInNewTab(new LRR.ApiURL("/config")));
    $(document).on("click.plugin-config", "#plugin-config", () => LRR.openInNewTab(new LRR.ApiURL("/config/plugins")));
    $(document).on("click.return", "#return", () => { window.location.href = new LRR.ApiURL("/"); });
    $(document).on("click.batch-reset-selection", "#batch-reset-selection", Batch.loadAllArchives);

    Batch.selectOperation();
    Batch.showOverride();


    // If a selected subset of archives is present, load only those archives.
    // Otherwise load the full archive list.
    try {
        const ids = validBatchSelection(JSON.parse(localStorage.getItem("msmSelection")));
        if (ids.length) {
            Batch.loadSelectionOnly(ids);
            return;
        }
    } catch {
        // Storage may be unavailable or hold an invalid selection.
    }

    Batch.loadAllArchives();
};

/**
 * Show the matching rows depending on the selected operation.
 */
Batch.selectOperation = function () {
    Batch.currentOperation = $("#batch-operation").val();

    $(".operation").hide();
    $(`.${Batch.currentOperation}-operation`).show();
};

/**
 * Show the matching override arguments for the selected plugin.
 */
Batch.showOverride = function () {
    Batch.currentPlugin = $("#plugin").val();

    const cooldown = $(`#${Batch.currentPlugin}-timeout`).html();
    $("#cooldown").html(cooldown);
    $("#timeout").val(cooldown);

    $(".arg-override").hide();

    if ($("#override")[0].checked) { $(`.${Batch.currentPlugin}-arg`).show(); }
};

function renderArchiveList(archives, checked) {
    const fragment = document.createDocumentFragment();
    // Keep the API's order within the checked and unchecked groups.
    for (const archive of archives.filter((row) => checked.has(row.arcid))
        .concat(archives.filter((row) => !checked.has(row.arcid)))) {
        const row = document.createElement("li");
        const input = document.createElement("input");
        input.type = "checkbox";
        input.name = "archive";
        input.className = "archive";
        input.id = archive.arcid;
        input.checked = checked.has(archive.arcid);
        const label = document.createElement("label");
        label.htmlFor = archive.arcid;
        label.textContent = String(archive.title ?? "") + (archive.isnew === "true" ? " 🆕" : "");
        row.append(input, label);
        fragment.append(row);
    }
    document.getElementById("archivelist").replaceChildren(fragment);
    $("#no-archives-msg").toggle(archives.length === 0);
    $("#start-batch").prop("disabled", archives.length === 0);
}

const archiveLoader = createBatchArchiveLoader({
    request: (url, options) => Server.callAPISilent(url, "GET", options),
    publish: renderArchiveList,
    failed: (error) => LRR.showErrorToast(I18N.ArchiveListLoadFailure, error),
    complete: () => {
        $("#arclist-container, #check-uncheck").show();
        $("#loading-placeholder").hide();
    },
});

function beginArchiveLoad() {
    $("#archivelist").empty();
    $("#no-archives-msg").show();
    $("#arclist-container").hide();
    $("#loading-placeholder").show();
    $("#start-batch").prop("disabled", true);
}

Batch.loadSelectionOnly = function (ids) {
    beginArchiveLoad();
    $("#msm-banner-count").text(I18N.BatchSelectionBanner(ids.length));
    $("#msm-banner").show();
    return archiveLoader.load(ids);
};

Batch.loadAllArchives = function () {
    beginArchiveLoad();
    $("#msm-banner").hide();
    try {
        localStorage.removeItem("msmSelection");
    } catch {
        // Loading the library remains available when storage is disabled.
    }
    return archiveLoader.load();
};

/**
 * Pop up a confirm dialog if operation is destructive.
 */
Batch.startBatchCheck = function () {
    if (!document.querySelector("input[name=archive]:checked")) {
        LRR.toast({ heading: I18N.BatchNoSelection, icon: "warning" });
        return;
    }
    if (Batch.currentOperation === "delete") {
        LRR.showPopUp({
            text: I18N.ConfirmArchivesDeletion,
            icon: "warning",
            showCancelButton: true,
            focusConfirm: true,
            allowEnterKey: true,
            confirmButtonText: I18N.ConfirmYes,
            reverseButtons: true,
            confirmButtonColor: "#d33",
        }).then((result) => {
            if (result.isConfirmed) {
                Batch.startBatch();
            }
        });
    } else {
        Batch.startBatch();
    }
};

/**
 * Get the titles who have been checked in the batch tagging list, and update their tags.
 * This crafts a JSON list to send to the batch tagging websocket service.
 */
Batch.startBatch = function () {
    const arcs = Array.from(document.querySelectorAll("input[name=archive]:checked")).map((item) => item.id);
    if (!arcs.length) return;
    Batch.session?.dispose();
    clearTimeout(Batch.reloadTimer);
    $(".tag-options").hide();

    $("#log-container").html(I18N.BatchOperationStart + "\n************\n");
    $("#cancel-job").show();
    $("#restart-job").hide();
    $(".job-status").show();

    let args = [];

    // Reset counts
    Batch.treatedArchives = 0;
    Batch.totalArchives = arcs.length;
    $("#arcs").html(0);
    $("#totalarcs").html(arcs.length);
    $(".bar").attr("style", "width: 0%;");

    // Only add values into the override argument array if the checkbox is on
    const arginputs = $(`.${Batch.currentPlugin}-argvalue`);
    if ($("#override")[0].checked) {
        args = Array.from(arginputs).map((item) => {
            // Checkbox inputs are handled by looking at the checked prop instead of the value.
            if (item.type !== "checkbox") {
                return item.value;
            } else {
                return item.checked ? 1 : 0;
            }
        });
    }

    // Initialize websocket connection
    const timeout = (Batch.currentOperation === "plugin") ? $("#timeout").val() : 0;
    const commandBase = {
        operation: Batch.currentOperation,
        plugin: Batch.currentPlugin,
        category: $("#category").val(),
        args,
    };

    const wsProto = document.location.protocol === "https:" ? "wss://" : "ws://";
    const socketPath = new LRR.ApiURL("/batch/socket");
    const socket = new WebSocket(`${wsProto + window.location.host}${socketPath}`);
    const session = createBatchSession({
        socket, archives: arcs, command: commandBase, cooldown: timeout,
        onResult: (result) => Batch.updateBatchStatus(result),
        onWait: (seconds) => Batch.appendLog(`${I18N.BatchSleeping(seconds)}\n`),
        onError: Batch.batchError,
        onClose: (event) => {
            if (Batch.session === session) Batch.endBatch(event);
        },
    });
    Batch.session = session;
};

/**
 * On websocket message, update the UI to show the archive currently being treated
 * @param {*} msg The validated response for the current archive
 */
Batch.updateBatchStatus = function (msg) {

    if (msg.success === 0) {
        Batch.appendLog(I18N.BatchOperationError(msg.id, msg.message));
    } else {
        switch (Batch.currentOperation) {
            case "plugin":
                Batch.appendLog(I18N.BatchSuccessPlugin(msg.id, Batch.currentPlugin, msg.tags));
                break;
            case "delete":
                Batch.appendLog(I18N.BatchSuccessDelete(msg.id, msg.filename));
                break;
            case "tagrules":
                Batch.appendLog(I18N.BatchSuccessTagRul(msg.id, msg.tags));
                break;
            case "addcat":
                // Append the message at the end of this log,
                // as it can contain the warning about the ID already being in the category
                Batch.appendLog(I18N.BatchSuccessCategr(msg.id, msg.category, msg.message));
                break;
            case "clearnew": {
                Batch.appendLog(I18N.BatchSuccessClrNew(msg.id));
                // Remove last character from matching row
                const t = $(`#${msg.id}`).next().text().replace("🆕", "");
                $(`#${msg.id}`).next().text(t);
                break;
            }
            default:
                Batch.appendLog(I18N.BatchUnknownOperat(Batch.currentOperation, msg.message));
                break;
        }

        Batch.appendLog("\n\n");

        // Uncheck ID in list
        const checkbox = document.getElementById(msg.id);
        if (checkbox) checkbox.checked = false;

        if (msg.title !== undefined && msg.title !== "") {
            Batch.appendLog(I18N.BatchChangedTitle(msg.title));
            Batch.appendLog("\n");
        }
    }

    // Update counts
    Batch.treatedArchives += 1;

    const percentage = Batch.treatedArchives / Batch.totalArchives;
    $(".bar").attr("style", `width: ${percentage * 100}%;`);
    $("#arcs").html(Batch.treatedArchives);

    Batch.scrollLogs();
};

/**
 * Handle websocket errors.
 */
Batch.batchError = function () {
    Batch.appendLog("************\n" + I18N.BatchOperationFailed + "\n");
    Batch.scrollLogs();

    LRR.toast({
        heading: I18N.BatchFailHeader,
        text: I18N.BatchFailBody,
        icon: "error",
        hideAfter: false,
    });
};

/**
 * Handle WS connection close events.
 * @param {*} event The closing event
 */
Batch.endBatch = function (event) {
    let status = "info";

    if (event.code === 1001) { status = "warning"; }

    Batch.appendLog(`************\n${event.reason}(code ${event.code})\n`);
    Batch.scrollLogs();

    LRR.toast({
        heading: I18N.BatchOperationEnd,
        icon: status,
    });

    // Delete the search cache after a finished session
    Server.callAPI("/api/search/cache", "DELETE", null, I18N.ErrorDeletingCache, null);

    $("#cancel-job").hide();

    if (Batch.currentOperation === "delete") {
        Batch.appendLog(I18N.BatchReloadingPage + "\n");
        Batch.reloadTimer = setTimeout(() => { window.location.reload(); }, 5000);
    } else {
        $("#restart-job").show();
    }
};

Batch.checkAll = function () {
    const checkboxes = [...document.querySelectorAll("#archivelist input.archive")];
    const shouldCheck = checkboxes.some((checkbox) => !checkbox.checked);
    checkboxes.forEach((checkbox) => { checkbox.checked = shouldCheck; });
};

Batch.scrollLogs = function () {
    $("#log-container").scrollTop($("#log-container").prop("scrollHeight"));
};

Batch.cancelBatch = function () {
    Batch.appendLog(I18N.BatchCancelling + "\n");
    Batch.session?.cancel();
};

Batch.restartBatchUI = function () {
    clearTimeout(Batch.reloadTimer);
    Batch.session?.dispose();
    Batch.session = null;
    $(".tag-options").show();
    $(".job-status").hide();
};

jQuery(() => {
    Batch.initializeAll();
});
