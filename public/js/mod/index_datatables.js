/**
 * All the Archive Index functions related to DataTables.
 */
import * as LRR from "lrr-common";
import * as Index from "lrr-index";
import * as Perf from "lrr-perf";
import { DEFAULT_INDEX_SORT_COLUMN, DEFAULT_INDEX_SORT_DIRECTION, getInitialIndexOrder } from "lrr-index-order";
import I18N from "i18n";

export let dataTable = {};
let originalTitle = document.title;
let isComingFromPopstate = false;
let currentSearch = "";
let pendingThumbnailCards = [];

/**
 * Initialize DataTables.
 */
export function initializeAll() {
    Perf.initializeLongTaskObserver();

    // Bind events to DOM
    $(document).on("click.apply-search", "#apply-search", () => { currentSearch = $("#search-input").val(); doSearch(); });
    $(document).on("click.clear-search", "#clear-search", () => { currentSearch = ""; doSearch(); });
    $(document).on("keyup.search-input", "#search-input", (e) => {
        if (e.defaultPrevented) {
            return;
        } else if (e.key === "Enter") {
            currentSearch = $("#search-input").val();
            doSearch();
        }
        e.preventDefault();
    });

    // Catch tag div clicks and do a search instead of reloading the page
    $(document).on("click.gt", ".gt", (e) => {
        e.preventDefault();
        currentSearch = $(e.target).attr("search");
        doSearch();
    });

    // Add a listen event to window.popstate to update the search accordingly
    // if the user goes back using browser history
    $(window).on("popstate", () => {
        isComingFromPopstate = true;
        consumeURLParameters();
    });

    // Clear searchbar cache
    $("#search-input").val("");

    // Classes for even/odd lines
    $.fn.dataTableExt.oStdClasses.sStripeOdd = "gtr0";
    $.fn.dataTableExt.oStdClasses.sStripeEven = "gtr1";

    // set custom columns
    const columns = [];
    columns.push({
        data: null, className: "title itd", name: "title", render: renderTitle,
    });
    const columnCount = Index.getColumnCount();
    // set custom columns
    for (let i = 1; i <= columnCount; i++) {
        columns.push({
            data: "tags",
            className: `customheader${i} itd`,
            name: localStorage[`customColumn${i}`] || `defaultCol${i}`,
            render: (data, type) => renderColumn(localStorage[`customColumn${i}`], type, data),
        });
    }
    columns.push({
        data: "tags", className: "tags itd", name: "tags", orderable: false, render: renderTags,
    });

    // Datatables configuration
    dataTable = $(".datatables").DataTable({
        serverSide: true,
        processing: true,
        ajax: {
            url: "search",
            cache: true,
            data: (d) => {
                if (localStorage.hidecompleted === "true") {
                    d.hidecompleted = "true";
                }
                if (localStorage.grouptanks === "false") {
                    d.grouptanks = "false";
                }
                return d;
            },
        },
        deferRender: true,
        lengthChange: false,
        pageLength: Index.pageSize,
        order: [[DEFAULT_INDEX_SORT_COLUMN, DEFAULT_INDEX_SORT_DIRECTION]],
        dom: `<"top"ip>rt<"bottom"p><"clear">`,
        language: {
            info: I18N.IndexPageCount,
            infoEmpty: `<h1><br/><i class="fas fa-4x fa-sad-cry"></i><br/><br/>
                        ${I18N.IndexNoArcsFound(new LRR.ApiURL("/upload"))}</h1><br/>`,
            processing: `<div id="progress" class="indeterminate"><div class="bar-container"><div class="bar" style="width: 80%;"></div></div></div>`,
        },
        preDrawCallback: initializeThumbView, // callbacks for thumbnail view
        drawCallback: drawCallback,
        createdRow: createdRow,
        columns,
    });

    // If the url has parameters, handle them now by doing the matching search.
    consumeURLParameters();
}

export function getCurrentSearch() {
    return currentSearch;
}

/**
 * Looks at the active filters and performs a search using DataTables' API.
 * (which is hooked back to the internal Search API)
 * If you specify a page argument, the search will load the given page.
 * @param {number} page Page to load
 */
export function doSearch(page) {
    // Add the selected category to the tags column so it's picked up by the search engine
    // This allows for the regular search bar to be used in conjunction with categories.
    dataTable.column(".tags.itd").search(Index.selectedCategory);

    // Update search input field
    $("#search-input").val(currentSearch);
    dataTable.search(currentSearch);

    // Add the current search terms to the title tab
    document.title = originalTitle + ((currentSearch !== "") ? ` - ${currentSearch}` : "");

    if (page) {
        // Hack the displayStart value to draw at the page we asked
        const customDisplayStart = page * dataTable.settings()[0]._iDisplayLength;
        dataTable.settings()[0].iInitDisplayStart = customDisplayStart;
    } else {
        dataTable.settings()[0].iInitDisplayStart = 0;
    }
    dataTable.draw();

    // Re-load categories so the most recently selected/created ones appear first
    Index.loadCategories();

    // Re-load carousel
    Index.updateCarousel();
}

// #region Compact View

/**
 * Generic function for rendering namespace columns.
 * @param {*} namespace The tag namespace to render
 * @param {*} type Whether this is a displayed column (html) or just a data request
 * @param {*} data The tag contents
 * @returns The table HTML, or raw data if type is data
 */
export function renderColumn(namespace, type, data) {
    if (type === "display") {
        if (data === "") return "";
        const regex = new RegExp(`${namespace}:([^,]+)`, "g"); // catch all values associated to the given namespace
        const matches = [...data.matchAll(regex)];

        if (matches != null) {
            let tagLinks = "";
            matches.forEach((match) => {
                let tagText = match[1];
                // If namespace is a date, consider the contents are a UNIX timestamp
                if (namespace === "date_added" || namespace === "timestamp") {
                    tagText = LRR.convertTimestamp(tagText);
                } else if (namespace !== "source") {
                    // Don't capitalize URLs to avoid breaking the hotlink
                    tagText = tagText.replace(/\b./g, (m) => m.toUpperCase());
                }
                const tagUrl = `${LRR.getTagSearchURL(namespace, tagText)}`;
                tagLinks += `<a style="cursor:pointer" href="${LRR.encodeHTML(tagUrl)}">${LRR.encodeHTML(tagText)}</a>, `;
            });

            const spanTags = tagLinks.slice(0, -2); // remove the last comma and space
            const popupTags = matches.map((match) => match[0]).join(","); //
            return `
                <span class="tag-tooltip" onmouseover="window.LRR.buildTagTooltip(this)" style="text-overflow:ellipsis;">${spanTags}</span>
                <div class="caption caption-tags" style="display: none;" >${LRR.buildTagsDiv(popupTags)}</div>
            `;
        } else return "";
    }
    return data;
}

/**
 * Render the title column.
 * @param {*} data Title
 * @param {*} type Whether this is a displayed column (html) or just a data request
 * @returns The table HTML, or raw title if type is data
 */
export function renderTitle(data, type) {
    if (type === "display") {
        const bookmarkIcon = LRR.buildBookmarkIconElement(data.arcid, "title-bookmark-icon");
        // For compact mode, the thumbnail API call enforces no_fallback=true in order to queue Minion jobs for missing thumbnails.
        // (Since compact mode is the "base", it's always loaded first even if you're in table mode)
        const thumbSrc = data.arcid.startsWith("TANK_")
            ? new LRR.ApiURL(`/api/tankoubons/${data.arcid}/thumbnail?no_fallback=true`)
            : new LRR.ApiURL(`/api/archives/${data.arcid}/thumbnail?no_fallback=true`);

        return `${LRR.buildStatusDiv(data)}${LRR.buildPageCountDiv(data)}${bookmarkIcon}
                <a id="${data.arcid}"
                   onmouseover="IndexTable.buildImageTooltip(this)"
                   href="${new LRR.ApiURL(`/reader?id=${data.arcid}`)}">
                    ${LRR.encodeHTML(data.title)}
                </a>
                <div class="caption" style="display: none;">
                    <img class="lazy-tooltip-thumbnail" style="height:300px" data-src="${thumbSrc}" loading="lazy"
                         onerror="this.src='${new LRR.ApiURL("/img/noThumb.png")}'">
                </div>`;
    }

    return data.title;
}

/**
 * Render the tags column.
 * @param {*} data Tags
 * @param {*} type Whether this is a displayed column (html) or just a data request
 * @returns The table HTML, or raw tags if type is data
 */
export function renderTags(data, type) {
    if (type === "display") {
        return `<span class="tag-tooltip" onmouseover="window.LRR.buildTagTooltip(this)" style="text-overflow:ellipsis;">
                    ${LRR.colorCodeTags(data)}
                </span>
                <div class="caption caption-tags" style="display: none;" >
                    ${LRR.buildTagsDiv(data)}
                </div>`;
    }
    return data;
}

// #endregion

// #region Thumbnail View
// Functions executed on DataTables draw callbacks to build the thumbnail view if it's enabled:

/**
 * Inits the div that contains the thumbnails
 */
export function initializeThumbView() {
    pendingThumbnailCards = [];

    // we only do all this thingamajang if thumbnail view is enabled
    if (localStorage.indexViewMode === "1") {
        // Create a thumbs container if it doesn't exist. put it in the dataTables_scrollbody div
        if ($("#thumbs_container").length < 1) $(".datatables").after("<div id='thumbs_container'></div>");

        // clear out the thumbs container; cards are swapped in once per draw.
        $("#thumbs_container").html("");

        $(".list").hide();
    } else {
        // Destroy the thumb container, make the table visible again and ensure autowidth is correct
        $("#thumbs_container").remove();
        $(".list").show();

        // Nuke style of table
        // Datatables' auto-width gets a bit lost when coming back from thumb view.
        $(".datatables").attr("style", "");

        dataTable.columns?.adjust();
    }
}

/**
 * Modifications when a row is created
 * @param {HTMLElement} row matching DataTables row
 * @param {[] | object} data raw data
 * @param {number} dataIndex index of row
 * @param {Node[]} cells cells for the column
 */
export function createdRow(row, data, dataIndex, cells) {
    // Update row with id and context-menu class
    row.id = data.arcid || data.id;
    row.classList.add("context-menu");
    // Builds a id1 class div to jam in the thumb container for the given archive data
    if (localStorage.indexViewMode === "1") {
        pendingThumbnailCards.push(LRR.buildThumbnailDiv(data));
    }
}

// #endregion

// #region Pushstate/Popstate URL parameters handling

/**
 * Called after the table is drawn. Updates page selector.
 * (And handles pushing the search parameters to the URL)
 */
export function drawCallback() {
    if (typeof (dataTable) !== "undefined") {
        Perf.measure("index.draw", () => {
            flushThumbnailCards();

            const pageInfo = dataTable.page.info();
            if (pageInfo.pages === 0) {
                $(".itg").hide();
            } else {
                $(".itg").show();
            }

            // Update url to contain all search parameters, and push it to the history
            if (isComingFromPopstate) {
                // But don't fire this if we're coming from popstate
                isComingFromPopstate = false;
            } else {
                let params = buildURLParameters();
                // don't push duplicate state entries, because that would wipe out forward history and
                // require multiple 'back' presses to go back)
                if (params === "?") {
                    // special case for empty search params: window.location.search is "" if there are
                    // no search params, even if window.location ends with '?'
                    if (window.location.search !== "") {
                        window.history.pushState(null, null, "/");
                    }
                } else if (params !== window.location.search) {
                    window.history.pushState(null, null, params);
                }
            }

            let currentSort = dataTable.order()[0][0];
            const currentOrder = dataTable.order()[0][1];

            // Save sort/order/page to localStorage
            localStorage.indexSort = currentSort;
            localStorage.indexOrder = currentOrder;

            // get current columns count, except title and tags
            const currentCustomColumnCount = dataTable.columns().count() - 2;
            // check currentSort, if out of range, back to use title
            if (currentSort > currentCustomColumnCount) {
                localStorage.indexSort = 0;
            }
            if (currentSort >= 1 && currentSort <= Index.getColumnCount()) {
                currentSort = localStorage.getItem(`customColumn${currentSort}`) || `Header ${currentSort}`;
            } else {
                currentSort = "title";
            }

            Index.updateTableControls(currentSort, currentOrder, pageInfo.pages, pageInfo.page + 1);

            // Re-apply selection highlights after each draw
            Index.applySelectionHighlights();

            // Clear potential leftover tooltips
            tippy.hideAll();
        });
    }
}

function flushThumbnailCards() {
    if (localStorage.indexViewMode !== "1") return;

    if (pendingThumbnailCards.length === 0) {
        dataTable.rows({ page: "current" }).data().each((data) => {
            pendingThumbnailCards.push(LRR.buildThumbnailDiv(data));
        });
    }

    $("#thumbs_container").html(pendingThumbnailCards.join(""));
    pendingThumbnailCards = [];
}

export function getVisibleArchiveIds() {
    const ids = [];
    dataTable.rows({ page: "current" }).data().each((data) => {
        ids.push(data.arcid || data.id);
    });
    return ids;
}

function markInsertedRows(previousIds) {
    const previous = new Set(previousIds);
    getVisibleArchiveIds().forEach((id) => {
        if (previous.has(id)) return;

        $(`#${id}.context-menu, #thumbs_container #${id}`)
            .addClass("lrr-row-enter");
        setTimeout(() => {
            $(`#${id}.context-menu, #thumbs_container #${id}`)
                .removeClass("lrr-row-enter");
        }, 900);
    });
}

export function reloadAfterArchiveMutation() {
    const previousIds = getVisibleArchiveIds();

    return dataTable.ajax.reload(() => {
        const pageInfo = dataTable.page.info();
        const currentRows = dataTable.rows({ page: "current" }).count();
        if (pageInfo.recordsDisplay > 0 && currentRows === 0 && pageInfo.page > 0) {
            dataTable.page(Math.max(0, pageInfo.page - 1)).draw(false);
            return;
        }

        markInsertedRows(previousIds);
    }, false);
}

export function buildURLParameters() {
    const cat = dataTable.column(".tags.itd").search();
    const page = dataTable.page.info().page + 1;
    const sortby = dataTable.order()[0][0];
    const sortorder = dataTable.order()[0][1];

    const encodedSearch = encodeURIComponent(dataTable.search());

    // Check each parameter and append them to the URL if they exist
    let params = "?";
    if (page !== 1) params += `p=${page}&`;
    if (sortby !== 0) params += `sort=${sortby}&`;
    if (sortorder !== "asc") params += `sortdir=${sortorder}&`;
    if (encodedSearch !== "") params += `q=${encodedSearch}&`;
    if (cat !== "") params += `c=${cat}&`;

    return params;
}

export function consumeURLParameters() {
    const params = new URLSearchParams(window.location.search);

    if (params.has("c")) Index.setSelectedCategory(params.get("c"));
    else Index.setSelectedCategory("");

    if (params.has("q")) { currentSearch = decodeURIComponent(params.get("q")); }

    // get current columns count, except title and tags
    const currentCustomColumnCount = dataTable.columns().count() - 2;
    const order = getInitialIndexOrder(params, localStorage, currentCustomColumnCount);

    dataTable.order(order);

    if (params.has("p")) {
        doSearch(params.get("p") - 1);
    } else {
        doSearch();
    }
}

// #endregion

/**
 * Build a tooltip when hovering over an archive title, then display it.
 * The tooltip is saved in DOM for further uses.
 * @param {*} target The target archive title
 * @returns
 */
export function buildImageTooltip(target) {
    if (target.innerHTML === "") return;

    const content = $(target).next("div").clone().attr("style", "height:300px;")[0];
    $(content).find(".lazy-tooltip-thumbnail").each((_, image) => {
        const src = $(image).attr("data-src");
        if (src && !$(image).attr("src")) {
            $(image).attr("src", src);
        }
    });

    tippy(target, {
        content,
        delay: 0,
        animation: false,
        maxWidth: "none",
        followCursor: true,
    }).show(); // Call show() so that the tooltip shows now

    $(target).attr("onmouseover", ""); // Don't trigger this function again for this element
}
