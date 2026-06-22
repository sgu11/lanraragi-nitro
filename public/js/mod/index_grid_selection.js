import * as LRR from "./common.js";
import * as IndexTable from "./index_datatables.js";
import I18N from "i18n";

const selectedArchives = new Set();
let initialized = false;
let latestCatList = [];
let redrawQueued = false;
let mutationObserver = null;

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
    document.addEventListener("contextmenu", handleContextMenuCapture, true);

    $(document).on("click.grid-selection-select-page", "#grid-selection-select-page", (event) => {
        event.preventDefault();
        selectCurrentPage();
    });

    $(document).on("click.grid-selection-clear", "#grid-selection-clear", (event) => {
        event.preventDefault();
        clear();
    });

    $(document).on("click.grid-selection-actions-toggle", "#grid-selection-actions-toggle", (event) => {
        event.preventDefault();
        event.stopPropagation();
        const menu = document.getElementById("grid-selection-actions-menu");
        if (menu) menu.hidden = !menu.hidden;
    });

    $(document).on("click.grid-selection-actions-item", "#grid-selection-actions-menu [data-action]", function (event) {
        event.preventDefault();
        const menu = document.getElementById("grid-selection-actions-menu");
        if (menu) menu.hidden = true;
        handleBulkAction(this.getAttribute("data-action"), null, latestCatList);
    });

    $(document).on("click.grid-selection-actions-outside", (event) => {
        const menu = document.getElementById("grid-selection-actions-menu");
        if (!menu || menu.hidden) return;
        if (event.target.closest("#grid-selection-actions-menu") || event.target.closest("#grid-selection-actions-toggle")) return;
        menu.hidden = true;
    });

    $(document).on("draw.dt.grid-selection", ".datatables", queueApplySelectionHighlights);
}

function handleContextMenuCapture(event) {
    const trigger = event.target.closest(".context-menu[id]");
    if (!trigger || !LRR.isUserLogged()) return;

    const { id } = trigger;
    if (!isSelectableId(id)) return;
    if (selectedArchives.has(id)) return;

    event.preventDefault();
    event.stopImmediatePropagation();
    select(id);
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
    mutationObserver = new MutationObserver(queueApplySelectionHighlights);
    mutationObserver.observe(document.body, { childList: true, subtree: true });
}

function injectBanner() {
    if (document.getElementById("grid-selection-banner")) return;

    const banner = document.createElement("span");
    banner.id = "grid-selection-banner";
    banner.hidden = true;
    banner.innerHTML = `
        <span class="grid-selection-count">0 selected</span>
        <button type="button" id="grid-selection-select-page" class="grid-selection-btn">Select page</button>
        <button type="button" id="grid-selection-clear" class="grid-selection-btn">Clear</button>
        <span class="grid-selection-actions">
            <button type="button" id="grid-selection-actions-toggle" class="grid-selection-btn">Actions</button>
            <ul id="grid-selection-actions-menu" hidden>
                <li data-action="batch"><i class="fas fa-hammer"></i> Run Batch Operations</li>
                <li data-action="addcat"><i class="fas fa-search-plus"></i> Add to category</li>
                <li data-action="delete"><i class="fas fa-trash-alt"></i> Delete from library</li>
            </ul>
        </span>`;

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
    if (countNode) countNode.textContent = `${count} selected`;
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

        .grid-selection-actions {
            position: relative;
        }

        #grid-selection-actions-menu {
            position: absolute;
            top: 100%;
            right: 0;
            z-index: 30;
            min-width: 220px;
            margin: 4px 0 0 0;
            padding: 4px 0;
            list-style: none;
            background: #2a2a2a;
            border: 1px solid rgba(255, 255, 255, 0.2);
            border-radius: 4px;
        }

        #grid-selection-actions-menu li {
            padding: 8px 14px;
            color: #fff;
            cursor: pointer;
        }

        #grid-selection-actions-menu li:hover {
            background: rgba(33, 150, 243, 0.3);
        }
    `;
    document.head.appendChild(style);
}
