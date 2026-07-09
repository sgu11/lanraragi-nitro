/**
 * Fork grid bulk selection (active user path).
 *
 * Upstream MSM (multi-select mode) code stays in index.js / index templates for
 * merge compatibility — do NOT re-wire #msm-toggle, #msm-carousel-controls,
 * #msm-batch-ops, #msm-merge, #msm-clear, or #msm-select-page for the fork UX.
 * This module hides those controls and owns short-right-click selection instead.
 */
import * as LRR from "lrr-common";
import * as IndexTable from "lrr-index-table";
import I18N from "i18n";

const selectedArchives = new Set();
const LONG_CLICK_MS = 600;
let initialized = false;
let latestCatList = [];
let redrawQueued = false;
let mutationObserver = null;
let longClickTimer = null;
let rightClickTargetId = null;
let rightLongClickFired = false;

export function initialize(catList = []) {
    latestCatList = catList || [];
    if (initialized) return;
    initialized = true;

    injectStyles();
    injectBanner();
    hideSupersededControls();
    bindEvents();
    observeRenderedArchives();
    applySelectionHighlights();
}

export function buildContextMenu(id, catList = latestCatList) {
    if (!isSelectableId(id) || !has(id)) return null;

    const count = size();
    return {
        callback(key) {
            handleBulkAction(key, id, catList);
        },
        items: {
            batch: { name: I18N.MSMRunBatch || `Run Batch Operations (${count})`, icon: "fas fa-hammer" },
            addcat: { name: `${I18N.AddToCategory || "Add to Category"} (${count})`, icon: "fas fa-search-plus" },
            delete: { name: `${I18N.Delete || "Delete"} (${count})`, icon: "fas fa-trash-alt" },
            sep1: "---------",
            remove: { name: I18N.MSMRemoveFromSelection || "Remove from selection", icon: "fas fa-minus-square" },
            clear: { name: I18N.MSMClearSelection || "Clear selection", icon: "fas fa-eject" },
        },
    };
}

export function has(id) {
    return selectedArchives.has(id);
}

export function size() {
    return selectedArchives.size;
}

export function ids() {
    return Array.from(selectedArchives);
}

export function select(id) {
    if (!isSelectableId(id) || selectedArchives.has(id)) return;
    selectedArchives.add(id);
    syncSelectionState();
}

export function remove(id) {
    if (!selectedArchives.delete(id)) return;
    syncSelectionState();
}

export function clear() {
    if (selectedArchives.size === 0) return;
    selectedArchives.clear();
    localStorage.removeItem("msmSelection");
    syncSelectionState();
}

export function applySelectionHighlights() {
    document.querySelectorAll(".context-menu[id]").forEach((node) => {
        const { id } = node;
        if (!isSelectableId(id)) return;

        const isSelected = selectedArchives.has(id);
        node.classList.toggle("lrr-grid-selected", isSelected);
        node.closest("tr")?.classList.toggle("lrr-grid-selected", isSelected);
    });
    updateBanner();
}

function bindEvents() {
    document.addEventListener("pointerdown", handlePointerDown, true);
    document.addEventListener("pointerup", handlePointerUp, true);
    document.addEventListener("contextmenu", handleContextMenuCapture, true);
    ["pointercancel", "pointerleave", "dragstart"].forEach((type) => {
        document.addEventListener(type, clearLongClickTimer, true);
    });

    $(document).on("click.grid-selection-select-page", "#grid-selection-select-page", (event) => {
        event.preventDefault();
        selectCurrentPage();
    });

    $(document).on("click.grid-selection-clear", "#grid-selection-clear", (event) => {
        event.preventDefault();
        clear();
    });

    $(document).on("click.grid-selection-delete", "#grid-selection-delete", (event) => {
        event.preventDefault();
        confirmBulkDelete();
    });

    $(document).on("draw.dt.grid-selection", ".datatables", queueApplySelectionHighlights);
}

function handlePointerDown(event) {
    clearLongClickTimer();
    rightClickTargetId = null;
    rightLongClickFired = false;
    if (event.button !== 2) return;

    const trigger = getSelectableTrigger(event);
    if (!trigger) return;

    event.preventDefault();
    event.stopImmediatePropagation();
    rightClickTargetId = trigger.id;
    if (!selectedArchives.has(trigger.id)) return;

    longClickTimer = window.setTimeout(() => {
        longClickTimer = null;
        rightLongClickFired = true;
        openSelectionContextMenu(trigger, event);
    }, LONG_CLICK_MS);
}

function handlePointerUp(event) {
    if (event.button !== 2) return;

    event.preventDefault();
    event.stopImmediatePropagation();
    clearLongClickTimer();
    if (!rightClickTargetId || rightLongClickFired) return;

    const id = rightClickTargetId;
    rightClickTargetId = null;
    toggle(id);
}

function handleContextMenuCapture(event) {
    const trigger = getSelectableTrigger(event);
    if (!trigger) return;
    if (event.gridSelectionLongClick) return;

    event.preventDefault();
    event.stopImmediatePropagation();
}

function toggle(id) {
    if (selectedArchives.has(id)) remove(id);
    else select(id);
}

function getSelectableTrigger(event) {
    const trigger = getElementTarget(event.target)?.closest(".context-menu[id]");
    if (!trigger || !LRR.isUserLogged() || !isSelectableId(trigger.id)) return null;
    return trigger;
}

function clearLongClickTimer() {
    if (!longClickTimer) return;
    window.clearTimeout(longClickTimer);
    longClickTimer = null;
}

function openSelectionContextMenu(trigger, sourceEvent) {
    const menuEvent = new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: sourceEvent.clientX,
        clientY: sourceEvent.clientY,
        button: 2,
        buttons: 0,
        view: window,
    });
    menuEvent.gridSelectionLongClick = true;
    trigger.dispatchEvent(menuEvent);
}

function handleBulkAction(action, clickedId, catList) {
    if (selectedArchives.size === 0) return;

    switch (action) {
        case "batch":
            openBatchOnSelection();
            break;
        case "addcat":
            promptBulkAddToCategory(catList);
            break;
        case "delete":
            confirmBulkDelete();
            break;
        case "remove":
            if (clickedId) remove(clickedId);
            break;
        case "clear":
            clear();
            break;
        default:
            break;
    }
}

function selectCurrentPage() {
    IndexTable.getVisibleArchiveIds()
        .filter(isSelectableId)
        .forEach((id) => selectedArchives.add(id));
    syncSelectionState();
}

function openBatchOnSelection() {
    const ids = Array.from(selectedArchives).filter(isSelectableId);
    if (ids.length === 0) return;
    localStorage.setItem("msmSelection", JSON.stringify(ids));
    LRR.openInNewTab(new LRR.ApiURL("/batch"));
}

function confirmBulkDelete() {
    const count = selectedArchives.size;
    LRR.showPopUp({
        text: `Delete ${count} selected archive${count === 1 ? "" : "s"}? This cannot be undone.`,
        icon: "warning",
        showCancelButton: true,
        focusConfirm: false,
        confirmButtonText: I18N.ConfirmYes,
        reverseButtons: true,
        confirmButtonColor: "#d33",
    }).then((result) => {
        if (!result.isConfirmed) return;
        bulkDelete(Array.from(selectedArchives).filter(isSelectableId));
    });
}

async function bulkDelete(deleteIds) {
    const failures = [];
    for (const id of deleteIds) {
        try {
            await fetchJson(`/api/archives/${id}`, "DELETE");
            selectedArchives.delete(id);
        } catch (error) {
            failures.push({ id, error: error.message });
        }
    }

    syncSelectionState();
    IndexTable.reloadAfterArchiveMutation();

    const succeeded = deleteIds.length - failures.length;
    if (failures.length === 0) {
        LRR.toast({ heading: `Deleted ${succeeded} archive${succeeded === 1 ? "" : "s"}`, icon: "success" });
    } else {
        LRR.showPopUp({
            text: `Deleted ${succeeded} of ${deleteIds.length}. Failed: ${failures.map((failure) => failure.id).join(", ")}`,
            icon: "warning",
        });
    }
}

function promptBulkAddToCategory(catList) {
    const inputOptions = {};
    for (const category of catList) {
        inputOptions[category.id] = category.name;
    }

    if (Object.keys(inputOptions).length === 0) {
        LRR.toast({ heading: I18N.IndexNoCategories || "No categories available", icon: "warning" });
        return;
    }

    LRR.showPopUp({
        title: `Add ${selectedArchives.size} archive${selectedArchives.size === 1 ? "" : "s"} to category`,
        input: "select",
        inputOptions,
        inputPlaceholder: I18N.AddToCategory || "Add to Category",
        showCancelButton: true,
        confirmButtonText: I18N.ConfirmYes,
        reverseButtons: true,
    }).then((result) => {
        if (!result.isConfirmed || !result.value) return;
        bulkAddToCategory(Array.from(selectedArchives).filter(isSelectableId), result.value);
    });
}

async function bulkAddToCategory(addIds, categoryId) {
    const failures = [];
    for (const id of addIds) {
        try {
            await fetchJson(`/api/categories/${categoryId}/${id}`, "PUT");
        } catch (error) {
            failures.push({ id, error: error.message });
        }
    }

    clear();

    const succeeded = addIds.length - failures.length;
    if (failures.length === 0) {
        LRR.toast({ heading: `Added ${succeeded} archive${succeeded === 1 ? "" : "s"} to category`, icon: "success" });
    } else {
        LRR.showPopUp({
            text: `Added ${succeeded} of ${addIds.length}. Failed: ${failures.map((failure) => failure.id).join(", ")}`,
            icon: "warning",
        });
    }
}

async function fetchJson(endpoint, method) {
    const response = await fetch(new LRR.ApiURL(endpoint), { method });
    const data = await response.json();
    if (!response.ok || data.success === 0) {
        throw new Error(data.error || `HTTP ${response.status}`);
    }
    return data;
}

function isSelectableId(id) {
    return Boolean(id) && !id.startsWith("TANK_");
}

function syncSelectionState() {
    mirrorLegacySelection();
    applySelectionHighlights();
}

function mirrorLegacySelection() {
    if (window.Index?.selectedArchives instanceof Set) {
        window.Index.selectedArchives.clear();
        selectedArchives.forEach((id) => window.Index.selectedArchives.add(id));
    }
}

function queueApplySelectionHighlights() {
    if (redrawQueued) return;
    redrawQueued = true;
    window.requestAnimationFrame(() => {
        redrawQueued = false;
        applySelectionHighlights();
    });
}

function observeRenderedArchives() {
    if (mutationObserver) return;
    mutationObserver = new MutationObserver(handleArchiveMutations);

    const targets = Array.from(document.querySelectorAll(".datatables, #thumbs_container, #toppane"));
    if (targets.length === 0) targets.push(document.body);
    targets.forEach((target) => mutationObserver.observe(target, { childList: true, subtree: true }));
}

function handleArchiveMutations(records) {
    const hasArchiveMutation = records.some((record) => !isIgnoredMutation(record));
    if (hasArchiveMutation) queueApplySelectionHighlights();
}

function isIgnoredMutation(record) {
    const target = getElementTarget(record.target);
    if (isGridSelectionChrome(target)) return true;

    return Array.from(record.addedNodes)
        .concat(Array.from(record.removedNodes))
        .every((node) => isGridSelectionChrome(getElementTarget(node)));
}

function getElementTarget(node) {
    if (node instanceof Element) return node;
    return node.parentElement || null;
}

function isGridSelectionChrome(element) {
    if (!element) return false;
    return Boolean(element.closest("#grid-selection-banner") || element.closest("#grid-selection-style"));
}

function injectBanner() {
    if (document.getElementById("grid-selection-banner")) return;

    const banner = document.createElement("span");
    banner.id = "grid-selection-banner";
    banner.hidden = true;
    banner.innerHTML = `
        <span class="grid-selection-count">0 selected</span>
        <button type="button" id="grid-selection-select-page" class="grid-selection-btn">Select all</button>
        <button type="button" id="grid-selection-clear" class="grid-selection-btn">Clear</button>
        <button type="button" id="grid-selection-delete" class="grid-selection-btn">Delete</button>`;

    const anchor = document.querySelector(".thumbnail-options") || document.querySelector(".table-options");
    if (anchor) {
        anchor.appendChild(banner);
    } else {
        document.querySelector(".itg.datatables")?.before(banner);
    }
}

function updateBanner() {
    const banner = document.getElementById("grid-selection-banner");
    if (!banner) return;

    const count = selectedArchives.size;
    banner.hidden = count === 0;
    const countNode = banner.querySelector(".grid-selection-count");
    const countText = `${count} selected`;
    if (countNode && countNode.textContent !== countText) countNode.textContent = countText;
}

function hideSupersededControls() {
    document.body.classList.add("grid-selection-enabled");
}

function injectStyles() {
    if (document.getElementById("grid-selection-style")) return;

    const style = document.createElement("style");
    style.id = "grid-selection-style";
    style.textContent = `
        .grid-selection-enabled #msm-toggle,
        .grid-selection-enabled #msm-carousel-controls,
        .grid-selection-enabled #carousel-mode-menu {
            display: none !important;
        }

        .lrr-grid-selected {
            outline: 3px solid #2196f3;
            outline-offset: -3px;
        }

        tr.lrr-grid-selected {
            background: rgba(33, 150, 243, 0.15) !important;
        }

        #grid-selection-banner {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            margin-left: 12px;
            padding: 4px 8px;
            border: 1px solid rgba(33, 150, 243, 0.4);
            border-radius: 4px;
            background: rgba(33, 150, 243, 0.12);
            vertical-align: middle;
        }

        #grid-selection-banner[hidden] {
            display: none !important;
        }

        .grid-selection-count {
            font-weight: bold;
        }

        .grid-selection-btn {
            padding: 2px 8px;
            background: rgba(255, 255, 255, 0.1);
            border: 1px solid rgba(255, 255, 255, 0.3);
            border-radius: 4px;
            color: inherit;
            cursor: pointer;
            font-size: 12px;
        }

    `;
    document.head.appendChild(style);
}
