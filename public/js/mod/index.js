/**
 * Non-DataTables Index functions.
 * (The split is there to permit easier switch if we ever yeet datatables from the main UI)
 * @global
 */
const Index = {};
Index.selectedCategory = "";
Index.awesomplete = {};
Index.carouselInitialized = false;
Index.swiper = {};
Index.serverVersion = "";
Index.debugMode = false;
Index.isProgressLocal = true;
Index.isProgressAuthenticated = true;
Index.pageSize = 100;
Index.pseudoCopyBtn = undefined;

/**
 * Initialize the Archive Index.
 */
Index.initializeAll = function () {
    // Bind events to DOM
    $(document).on("click", "[id^=edit-header-]", function () {
        const headerIndex = $(this).attr("id").split("-")[2];
        Index.promptCustomColumn(headerIndex);
    });
    $(document).on("change.page-select", "#page-select", () => IndexTable.dataTable.page($("#page-select").val() - 1).draw("page"));
    $(document).on("change.namespace-sortby", "#namespace-sortby", Index.handleCustomSort);
    $(document).on("change.columnCount", "#columnCount", Index.handleColumnNum);
    $(document).on("click.order-sortby", "#order-sortby", Index.toggleOrder);
    $(document).on("click.open-carousel", ".collapsible-title", Index.toggleCarousel);
    $(document).on("click.reload-carousel", "#reload-carousel", Index.updateCarousel);
    $(document).on("click.toggle-carousel-visibility", "#toggle-carousel-visibility", Index.toggleCarouselVisibility);
    $(document).on("click.close-overlay", "#overlay-shade", LRR.closeOverlay);
    $(document).on("click.thumbnail-bookmark-icon", ".thumbnail-bookmark-icon", Index.toggleBookmarkStatusByIcon);
    $(document).on("click.title-bookmark-icon", ".title-bookmark-icon", Index.toggleBookmarkStatusByIcon);
    $(document).on("keydown.quick-search", Index.handleQuickSearch);
    $(document).on("keydown.escape-overlay", Index.handleEscapeKey);

    // Bulk-selection: toggle Selection when user clicks the card's checkbox glyph.
    // Delegated so newly-rendered DataTables rows inherit the handler.
    // Gated on logged-in state — bulk actions require auth, so no selection for guests.
    $(document).on("click.card-select", ".card-select", function (e) {
        e.stopPropagation();
        e.preventDefault();
        if (!LRR.isUserLogged()) return;
        const id = $(this).attr("data-arcid") || $(this).closest(".context-menu").attr("id");
        if (!id) return;
        Selection.toggle(id);
        const checked = Selection.has(id);
        $(this).toggleClass("checked", checked);
        $(this).attr("aria-checked", checked ? "true" : "false");
        $(this).closest(".context-menu").toggleClass("selected", checked);
    });

    // Banner show/hide + count update driven by Selection changes.
    Selection.onChange(function (size) {
        const banner = document.getElementById("bulk-selection-banner");
        if (!banner) return;
        if (size === 0) {
            banner.style.display = "none";
        } else {
            banner.style.display = "inline-flex";
            const countEl = banner.querySelector(".bulk-count");
            if (countEl) {
                countEl.textContent = `${size} ${I18N.Selected || "selected"}`;
            }
        }
    });

    // Banner: add every rendered card/row on the current page to Selection.
    $(document).on("click.bulk-select-page", "#bulk-select-page", function () {
        const ids = (localStorage.indexViewMode === "1")
            ? $("#thumbs_container .id1").map((_, el) => el.id).get()
            : $(".itg.datatables tbody tr.context-menu").map((_, el) => el.id).get();
        ids.forEach(id => Selection.add(id));
        ids.forEach(id => {
            const cards = document.querySelectorAll(`.id1#${CSS.escape(id)}, tr.context-menu#${CSS.escape(id)}`);
            cards.forEach(el => {
                el.classList.add("selected");
                const glyph = el.querySelector(".card-select");
                if (glyph) {
                    glyph.classList.add("checked");
                    glyph.setAttribute("aria-checked", "true");
                }
            });
        });
    });

    // Banner: clear selection and visually reset every card/row on screen.
    $(document).on("click.bulk-clear", "#bulk-clear", function () {
        Selection.clear();
        document.querySelectorAll(".id1.selected, tr.selected").forEach(el => {
            el.classList.remove("selected");
        });
        document.querySelectorAll(".card-select.checked").forEach(el => {
            el.classList.remove("checked");
            el.setAttribute("aria-checked", "false");
        });
    });

    // Banner Actions dropdown: toggle menu, close on outside click, dispatch on item click.
    $(document).on("click.bulk-actions-toggle", "#bulk-actions-toggle", function (e) {
        e.stopPropagation();
        const menu = document.getElementById("bulk-actions-menu");
        if (!menu) return;
        menu.hidden = !menu.hidden;
    });

    $(document).on("click.bulk-actions-outside", function (e) {
        const menu = document.getElementById("bulk-actions-menu");
        if (!menu || menu.hidden) return;
        if (e.target.closest("#bulk-actions-menu") || e.target.closest("#bulk-actions-toggle")) return;
        menu.hidden = true;
    });

    $(document).on("click.bulk-actions-item", "#bulk-actions-menu li", function () {
        const action = this.getAttribute("data-action");
        const menu = document.getElementById("bulk-actions-menu");
        if (menu) menu.hidden = true;
        Index.handleBulkAction(action);
    });

    // 0 = List view
    // 1 = Thumbnail view
    // List view is at 0 but became the non-default state later so here's some legacy weirdness
    if (localStorage.getItem("indexViewMode") === null) {
        localStorage.indexViewMode = 1;
    }

    // Default to crop landscape
    if (localStorage.getItem("cropthumbs") === null) {
        localStorage.cropthumbs = true;
    }

    // Default custom columns
    if (localStorage.getItem("customColumn1") === null) {
        localStorage.customColumn1 = "artist";
        localStorage.customColumn2 = "series";
    }

    // Default to on deck for carousel
    if (localStorage.getItem("carouselType") === null) {
        localStorage.carouselType = "ondeck";
    }

    // Default to opened carousel
    if (localStorage.getItem("carouselOpen") === null) {
        localStorage.carouselOpen = 1;
    }

    // Default to visible carousel
    if (localStorage.getItem("carouselHidden") === null) {
        localStorage.carouselHidden = "0";
    }

    Index.applyCarouselVisibility();

    if (localStorage.carouselHidden !== "1") {
        // Force-open the collapsible if carouselOpen = true
        if (localStorage.carouselOpen === "1") {
            $(".collapsible-title").trigger("click", [false]);
            // Index.updateCarousel(); will be executed by toggleCarousel
        } else {
            Index.updateCarousel();
        }
    }

    // Initialize carousel mode menu
    $.contextMenu({
        selector: "#carousel-mode-menu",
        trigger: "left",
        build: () => ({
            callback(key) {
                localStorage.carouselType = key;
                Index.updateCarousel();
            },
            items: {
                ondeck: { name: I18N.CarouselOnDeck, icon: "fas fa-book-reader" },
                random: { name: I18N.CarouselRandom, icon: "fas fa-random" },
                inbox: { name: I18N.NewArchives, icon: "fas fa-envelope-open-text" },
                untagged: { name: I18N.UntaggedArchives, icon: "fas fa-edit" },
            },
        }),
    });

    // Initialize settings menu (display mode, crop thumbnails, hide completed)
    $.contextMenu({
        selector: "#settings-menu",
        trigger: "left",
        build: () => {
            const isThumbnail = localStorage.indexViewMode === "1";
            return {
                items: {
                    "header": {
                        name: I18N.IndexSettingsDisplayMode,
                        icon: "fas fa-table",
                        disabled: true,
                    },
                    "mode-thumbnail": {
                        name: I18N.IndexSettingsThumbnail,
                        type: "radio",
                        radio: "displayMode",
                        value: "1",
                        selected: isThumbnail,
                        events: {
                            click() {
                                localStorage.indexViewMode = "1";
                                IndexTable.dataTable.draw();
                            },
                        }
                    },
                    "mode-compact": {
                        name: I18N.IndexSettingsCompact,
                        type: "radio",
                        radio: "displayMode",
                        value: "0",
                        selected: !isThumbnail,
                        events: {
                            click() {
                                localStorage.indexViewMode = "0";
                                IndexTable.dataTable.draw();
                            },
                        }
                    },
                    "sep1": "---------",
                    "crop-thumbnails": {
                        name: `<span title="${I18N.IndexSettingsCropDesc}">${I18N.IndexSettingsCropThumbs}</span>`,
                        isHtmlName: true,
                        type: "checkbox",
                        selected: localStorage.cropthumbs === "true",
                        events: {
                            click() {
                                localStorage.cropthumbs = $(this).is(":checked");
                                IndexTable.dataTable.draw();
                            },
                        },
                    },
                    "hide-completed": {
                        name: `<span title="${I18N.IndexSettingsHideCompletedDesc}">${I18N.IndexSettingsHideCompleted}</span>`,
                        isHtmlName: true,
                        type: "checkbox",
                        selected: localStorage.hidecompleted === "true",
                        events: {
                            click() {
                                localStorage.hidecompleted = $(this).is(":checked");
                                IndexTable.dataTable.draw();
                            },
                        },
                    },
                    "group-tanks": {
                        name: `<span title="${I18N.IndexSettingsGroupTanksDesc}">${I18N.IndexSettingsGroupTanks}</span>`,
                        isHtmlName: true,
                        type: "checkbox",
                        selected: localStorage.grouptanks !== "false",
                        events: {
                            click() {
                                localStorage.grouptanks = $(this).is(":checked");
                                IndexTable.dataTable.draw();
                            },
                        },
                    },
                },
            };
        },
    });

    // Tell user about the context menu
    if (localStorage.getItem("sawContextMenuToast") === null) {
        localStorage.sawContextMenuToast = true;

        LRR.toast({
            heading: I18N.IndexWelcome(Index.serverVersion),
            text: I18N.IndexWelcome2,
            icon: "info",
            hideAfter: 13000,
        });
    }

    // Get some info from the server: version, debug mode, local progress
    Server.callAPI("/api/info", "GET", null, I18N.ServerInfoError,
        (data) => {
            Index.serverVersion = data.version;
            Index.debugMode = !!data.debug_mode;
            Index.isProgressLocal = !data.server_tracks_progress;
            Index.isProgressAuthenticated = data.authenticated_progress;
            Index.pageSize = data.archives_per_page;

            // Check version if not in debug mode
            if (!Index.debugMode) {
                Index.checkVersion();
                Index.fetchChangelog();
            } else {
                LRR.toast({
                    heading: `<i class="fas fa-bug"></i> ` + I18N.DebugModeHeader,
                    text: I18N.DebugModeDesc(new LRR.apiURL("/debug")),
                    icon: "warning",
                });
            }

            Index.migrateProgress();
            Index.loadTagSuggestions();

            // Make bookmark category ID available to index and indextable
            Server.loadBookmarkCategoryId()
                .then(() => Index.loadCategories())
                .then(() => IndexTable.initializeAll())
                // eslint-disable-next-line no-console
                .catch(error => console.error("Error initializing index:", error));
        });

    const columnCountSelect = document.getElementById("columnCount");
    columnCountSelect.value = Index.getColumnCount();

    Index.updateTableHeaders();
    Index.resizableColumns();

    Index.pseudoCopyBtn = $("#pseudo-copy-btn")
    Index.clipboard = new window.ClipboardJS("#pseudo-copy-btn");

    Index.clipboard.on("success", function (e) {
        LRR.toast({
            heading: I18N.IndexCopyLinkSuccess,
            icon: "info",
            hideAfter: 3000,
        });
        e.clearSelection();
    });

    Index.clipboard.on("error", function (_e) {
        LRR.toast({
            heading: I18N.IndexCopyLinkFail,
            icon: "error",
            hideAfter: false,
        });
    });
};

// Turn bookmark icons to OFF for all archives.
Index.bookmarkIconOff = function (arcid) {
    const icons = document.querySelectorAll(`.title-bookmark-icon[id='${arcid}'], .thumbnail-bookmark-icon[id='${arcid}']`);
    icons.forEach(el => {
        el.classList.remove("fas");
        el.classList.add("far");
    })
}

// Turn bookmark icons to ON for all archives.
Index.bookmarkIconOn = function (arcid) {
    const icons = document.querySelectorAll(`.title-bookmark-icon[id='${arcid}'], .thumbnail-bookmark-icon[id='${arcid}']`);
    icons.forEach(el => {
        el.classList.remove("far");
        el.classList.add("fas");
    })
}

Index.toggleBookmarkStatusByIcon = function (e) {
    const icon = e.currentTarget;
    const { id } = icon;

    if (!LRR.isUserLogged()) {
        LRR.toast({
            heading: I18N.LoginRequired(new LRR.apiURL("/login")),
            icon: "warning",
            hideAfter: 5000,
        });
        return;
    }

    if (icon.classList.contains("far")) {
        Server.addArchiveToCategory(id, localStorage.getItem("bookmarkCategoryId"));
        Index.bookmarkIconOn(id);
    } else if (icon.classList.contains("fas")) {
        Server.removeArchiveFromCategory(id, localStorage.getItem("bookmarkCategoryId"));
        Index.bookmarkIconOff(id);
    }
};

/**
 * Handle quick search functionality. If user is in index page and
 * presses "/" key, focus to search input. If the release overlay
 * is open, closes it before focusing to search input.
 * 
 * @param {KeyboardEvent} e - The keyboard event
 */
Index.handleQuickSearch = function (e) {
    if (e.key !== "/") return;
    if (e.target.tagName === "INPUT") return;
    if (e.ctrlKey || e.altKey || e.shiftKey || e.metaKey) return;
    e.preventDefault();
    if ($("#overlay-shade").is(":visible")) LRR.closeOverlay();
    $("#search-input")[0].focus();
};

/**
 * Handle escape key to close overlays.
 * @param {KeyboardEvent} e - The keyboard event
 */
Index.handleEscapeKey = function (e) {
    if (e.key !== "Escape") return;
    if (e.target.tagName === "INPUT") return;
    LRR.closeOverlay();
};

Index.toggleMode = function () {
    localStorage.indexViewMode = (localStorage.indexViewMode === "1") ? "0" : "1";
    IndexTable.dataTable.draw();
};

Index.applyCarouselVisibility = function () {
    const hidden = localStorage.carouselHidden === "1";
    $(".index-carousel").toggle(!hidden);
    $("#toggle-carousel-visibility").val(hidden ? I18N.ShowCarousel : I18N.HideCarousel);
};

Index.toggleCarouselVisibility = function (e) {
    if (e) e.preventDefault();
    localStorage.carouselHidden = (localStorage.carouselHidden === "1") ? "0" : "1";
    Index.applyCarouselVisibility();

    if (localStorage.carouselHidden === "1") return;

    // Re-show: initialize/update carousel if the collapsible is open
    if (localStorage.carouselOpen === "1") {
        if (!Index.carouselInitialized) {
            // Force-open triggers carousel init + update
            $(".collapsible-title").trigger("click", [false]);
        } else {
            Index.updateCarousel();
        }
    }
};

Index.toggleCarousel = function (e, updateLocalStorage = true) {
    if (updateLocalStorage) localStorage.carouselOpen = (localStorage.carouselOpen === "1") ? "0" : "1";

    if (!Index.carouselInitialized) {
        Index.carouselInitialized = true;
        $("#reload-carousel").show();

        Index.swiper = new Swiper(".index-carousel-container", {
            breakpoints: (() => {
                const breakpoints = {
                    0: { // ensure every device have at least 1 slide
                        slidesPerView: 1,
                    },
                };
                // virtual Slides doesn't work with slidesPerView: 'auto'
                // the following loops are meant to implement same functionality by doing mathworks
                // it also helps avoid writing a billion slidesPerView combos for window widths
                // when the screen width <= 560px, every thumbnails have a different width
                // from 169px, when the width is 17px bigger, we display 0.1 more slide
                for (let width = 169, sides = 1; width <= 424; width += 17, sides += 0.1) {
                    breakpoints[width] = {
                        slidesPerView: sides,
                    };
                }
                // from 427px, when the width is 46px bigger, we display 0.2 more slide
                // the width support up to 4K resolution
                for (let width = 427, sides = 1.8; width <= 3840; width += 46, sides += 0.2) {
                    breakpoints[width] = {
                        slidesPerView: sides,
                    };
                }
                return breakpoints;
            })(),
            breakpointsBase: "container",
            centerInsufficientSlides: false,
            mousewheel: true,
            navigation: {
                nextEl: ".carousel-next",
                prevEl: ".carousel-prev",
            },
            slidesPerView: 7,
            virtual: {
                enabled: true,
                addSlidesAfter: 2,
                addSlidesBefore: 2,
            },
        });

        Index.updateCarousel();
    }
};

Index.toggleCrop = function () {
    localStorage.cropthumbs = $("#thumbnail-crop")[0].checked;
    IndexTable.dataTable.draw();
};

Index.toggleHideCompleted = function () {
    localStorage.hidecompleted = $("#hide-completed")[0].checked;
    IndexTable.dataTable.draw();
};

Index.toggleOrder = function (e) {
    e.preventDefault();
    const order = IndexTable.dataTable.order();
    order[0][1] = order[0][1] === "asc" ? "desc" : "asc";
    IndexTable.dataTable.order(order);
    IndexTable.dataTable.draw();
};

/**
 * Toggles a category filter.
 * Sets the internal selectedCategory variable and changes the button's class.
 * @param {*} button Button matching the category.
 */
Index.toggleCategory = function (button) {
    // Add/remove class to button depending on the state
    const categoryId = button.id;
    if (Index.selectedCategory === categoryId) {
        button.classList.remove("toggled");
        Index.selectedCategory = "";
    } else {
        Index.selectedCategory = categoryId;
        button.classList.add("toggled");
    }

    // Trigger search
    IndexTable.doSearch();
};

/**
 * Show a prompt to update the namespace of a column in compact mode.
 * @param {*} column Index of the column to modify, either 1 or 2
 */
Index.promptCustomColumn = function (column) {
    LRR.showPopUp({
        title: I18N.CustomColumn,
        text: I18N.CustomColumnDesc + "\n" + I18N.CustomColumnDesc2,
        input: "text",
        inputValue: localStorage.getItem(`customColumn${column}`),
        inputPlaceholder: I18N.TagNamespace,
        inputAttributes: {
            autocapitalize: "off",
        },
        showCancelButton: true,
        reverseButtons: true,
        inputValidator: (value) => {
            if (!value) {
                return I18N.TagNamespaceError;
            }
            return undefined;
        },
    }).then((result) => {
        if (result.isConfirmed) {
            if (!LRR.isNullOrWhitespace(result.value)) {
                const namespace = result.value.trim();
                localStorage.setItem(`customColumn${column}`, namespace);

                IndexTable.dataTable.settings()[0].aoColumns[column].sName = namespace;
                // Update header text in-place to preserve DataTables sort handlers
                $(`#header-${column}`).html(namespace.charAt(0).toUpperCase() + namespace.slice(1));
                IndexTable.doSearch();
            }
        }
    });
};

/**
 * Update table controls to reflect the current status.
 * @param {*} currentSort Current sort column
 * @param {*} currentOrder Current sort order
 * @param {*} totalPages Total pages of the table
 * @param {*} currentPage Current page of the table
 */
Index.updateTableControls = function (currentSort, currentOrder, totalPages, currentPage) {
    $(".table-options").show();

    $("#namespace-sortby").val(currentSort);
    $("#order-sortby")[0].classList.remove("fa-sort-alpha-down", "fa-sort-alpha-up");
    $("#order-sortby")[0].classList.add(currentOrder === "asc" ? "fa-sort-alpha-down" : "fa-sort-alpha-up");

    if (localStorage.indexViewMode === "1") {
        $(".thumbnail-options").show();
        $(".compact-options").hide();
    } else {
        $(".thumbnail-options").hide();
        $(".compact-options").show();
    }

    // Page selector
    const pageSelect = $("#page-select");
    pageSelect.empty();

    for (let j = 1; j <= totalPages; j++) {
        const oOption = document.createElement("option");
        oOption.text = j;
        oOption.value = j;
        pageSelect[0].add(oOption, null);
    }

    pageSelect.val(currentPage);
};

Index.handleCustomSort = function () {
    const namespace = $("#namespace-sortby").val();
    const order = IndexTable.dataTable.order();

    // Special case for title sorting, as that uses column 0
    if (namespace === "title") {
        order[0][0] = 0;
    } else {
        // The order set in the combobox uses is offset from title by 1; 
        // e.g. customColumn1 is offset from title by 1.
        order[0][0] = 1;
        localStorage.customColumn1 = namespace;
        IndexTable.dataTable.settings()[0].aoColumns[1].sName = namespace;
        // Update header text in-place to preserve DataTables sort handlers
        $(`#header-1`).html(namespace.charAt(0).toUpperCase() + namespace.slice(1));
    }

    IndexTable.dataTable.order(order);
    IndexTable.dataTable.draw();
};

Index.updateCarousel = function (e) {
    e?.preventDefault();
    $("#carousel-empty").hide();
    $("#carousel-loading").show();
    $(".swiper-wrapper").hide();

    $("#reload-carousel").addClass("fa-spin");

    // Hit a different API endpoint depending on the requested localStorage carousel type
    let endpoint;
    const filter = IndexTable.currentSearch ? `&filter=${IndexTable.currentSearch}` : "";
    const category = Index.selectedCategory ? `&category=${Index.selectedCategory}` : "";

    switch (localStorage.carouselType) {
        case "random":
            $("#carousel-icon")[0].classList = "fas fa-random";
            $("#carousel-title").text(I18N.CarouselRandom);
            endpoint = `/api/search/random?count=15${filter}${category}`;

            // Special categories that imply additional query params
            if (Index.selectedCategory === "NEW_ONLY") {
                endpoint += "&newonly=true";
            } else if (Index.selectedCategory === "UNTAGGED_ONLY") {
                endpoint += "&untaggedonly=true";
            }

            break;
        case "inbox":
            $("#carousel-icon")[0].classList = "fas fa-envelope-open-text";
            $("#carousel-title").text(I18N.NewArchives);
            endpoint = `/api/search?newonly=true&sortby=date_added&order=desc&start=-1${filter}${category}`;
            break;
        case "untagged":
            $("#carousel-icon")[0].classList = "fas fa-edit";
            $("#carousel-title").text(I18N.UntaggedArchives);
            endpoint = `/api/search?untaggedonly=true&sortby=date_added&order=desc&start=-1${filter}${category}`;
            break;
        case "ondeck":
            $("#carousel-icon")[0].classList = "fas fa-book-reader";
            $("#carousel-title").text(I18N.CarouselOnDeck);
            endpoint = `/api/search?sortby=lastread&hidecompleted=true${filter}`;
            break;
        default:
            $("#carousel-icon")[0].classList = "fas fa-pastafarianism";
            $("#carousel-title").text("What???");
            endpoint = `/api/search?${filter}${category}`.replace(/\?$/, "");
            break;
    }

    if (Index.carouselInitialized) {
        Server.callAPI(endpoint, "GET", null, I18N.CarouselError,
            (results) => {
                Index.swiper.virtual.removeAllSlides();
                const slides = results.data
                    .map((archive) => LRR.buildThumbnailDiv(archive));
                Index.swiper.virtual.appendSlide(slides);
                Index.swiper.virtual.update();

                if (results.data.length === 0) {
                    $("#carousel-empty").show();
                }

                $("#carousel-loading").hide();
                $(".swiper-wrapper").show();
                $("#reload-carousel").removeClass("fa-spin");
            },
        );
    }
};

Index.handleColumnNum = function () {
    const columnCountSelect = document.getElementById("columnCount");
    const selectedCount = columnCountSelect.value;
    localStorage.setItem("columnCount", selectedCount);
    Index.updateTableHeaders();
    document.location.reload(true);
};

/**
 * Generate the Table Headers based on the custom namespaces set in localStorage.
 */
Index.generateTableHeaders = function (columnCount) {
    const headerRow = $("#header-row");
    headerRow.empty();
    const headerWidth = localStorage.getItem(`resizeColumn0`) || "";
    headerRow.append(`
        <th id="titleheader" width="${headerWidth}">
            <a>${I18N.IndexTitle}</a>
        </th>`);

    for (let i = 1; i <= columnCount; i++) {
        const customColumn = localStorage[`customColumn${i}`] || `Header ${i}`;
        const colWidth = localStorage.getItem(`resizeColumn${i}`) || "";

        const headerHtml = `
            <th id="customheader${i}" width="${colWidth}">
                <i id="edit-header-${i}" class="fas fa-pencil-alt edit-header-btn" title="${I18N.IndexEditColumn}"></i>
                <a id="header-${i}">${customColumn.charAt(0).toUpperCase() + customColumn.slice(1)}</a>
            </th>`;
        headerRow.append(headerHtml);
    }
    headerRow.append(`
        <th id="tagsheader">
            <a>${I18N.IndexTags}</a>
        </th>`);
};

/**
 * Handle context menu clicks.
 * @param {*} option The clicked option
 * @param {*} id The Archive ID
 * @returns
 */
Index.handleContextMenu = function (option, id) {
    switch (option) {
        case "edit":
            LRR.openInNewTab(new LRR.apiURL(`/edit?id=${id}`));
            break;
        case "delete":
            LRR.showPopUp({
                text: I18N.ConfirmArchiveDeletion,
                icon: "warning",
                showCancelButton: true,
                focusConfirm: false,
                confirmButtonText: I18N.ConfirmYes,
                reverseButtons: true,
                confirmButtonColor: "#d33",
            }).then((result) => {
                if (result.isConfirmed) {
                    Server.deleteArchive(id, () => {
                        if (typeof IndexTable !== "undefined" && IndexTable.dataTable) {
                            IndexTable.dataTable.ajax.reload(null, false);
                        }
                    });
                }
            });
            break;
        case "read":
            LRR.openInNewTab(new LRR.apiURL(`/reader?id=${id}`));
            break;
        case "download":
            LRR.openInNewTab(new LRR.apiURL(`/api/archives/${id}/download`));
            break;
        case "copy link":
            Index.pseudoCopyBtn.attr("data-clipboard-text", `${window.location.origin}${new LRR.apiURL(`/reader?id=${id}`).toString()}`);
            Index.pseudoCopyBtn.click()
            break;
        default:
            break;
    }
};

/**
 * Load tag suggestions for the tag search bar.
 */
Index.loadTagSuggestions = function () {
    // Query the tag cloud API to get the most used tags, excluding configured namespaces.
    Server.callAPI("/api/database/stats?minweight=2&hide_excluded_namespaces=true", "GET", null, I18N.TagStatsLoadFailure,
        (data) => {
            // Get namespaces objects in the data array to fill the namespace-sortby combobox
            const namespacesSet = new Set(data.map((element) => (element.namespace === "parody" ? "series" : element.namespace)));
            namespacesSet.forEach((element) => {
                if (element !== "") {
                    $("#namespace-sortby").append(`<option value="${element}">${element.charAt(0).toUpperCase() + element.slice(1)}</option>`);
                }
            });

            // Setup awesomplete for the tag search bar
            Index.awesomplete = new Awesomplete("#search-input", {
                list: data,
                data(tag) {
                    // Format tag objects from the API into a format awesomplete likes.
                    let label = tag.text;
                    if (tag.namespace !== "") label = `${tag.namespace}:${tag.text}`;

                    return { label, value: tag.weight };
                },
                // Sort by weight
                sort(a, b) {
                    return b.value - a.value;
                },
                filter(text, input) {
                    return Awesomplete.FILTER_CONTAINS(text, input.match(/[^, -]*$/)[0]);
                },
                item(text, input) {
                    return Awesomplete.ITEM(text, input.match(/[^, -]*$/)[0]);
                },
                replace(text) {
                    const before = this.input.value.match(/^.*(,|-)\s*-*|/)[0];
                    this.input.value = `${before + text}$, `;
                },
            });
        },
    );
};

/**
 * Query the category API to build the filter buttons.
 */
Index.loadCategories = function () {
    return Server.callAPI("/api/categories", "GET", null, I18N.CategoryFetchError,
        (data) => {
            // Sort by pinned + alpha
            // Pinned categories are shown at the beginning
            data.sort((b, a) => b.name.localeCompare(a.name));
            data.sort((a, b) => b.pinned - a.pinned);
            // Queue some hardcoded categories at the beginning - those are special-cased in the DataTables variant of the search endpoint. 
            let html = `<div style='display:inline-block'>
                            <input class='favtag-btn ${(("NEW_ONLY" === Index.selectedCategory) ? "toggled" : "")}' 
                            type='button' id='NEW_ONLY' value='🆕 ${I18N.NewArchives}' 
                            onclick='Index.toggleCategory(this)' title='${I18N.NewArchiveDesc}'/>
                        </div><div style='display:inline-block'>
                            <input class='favtag-btn ${(("UNTAGGED_ONLY" === Index.selectedCategory) ? "toggled" : "")}' 
                            type='button' id='UNTAGGED_ONLY' value='🏷️ ${I18N.UntaggedArchives}' 
                            onclick='Index.toggleCategory(this)' title='${I18N.UntaggedArcDesc}'/>
                        </div>`;

            const iteration = (data.length > 10 ? 10 : data.length);

            for (let i = 0; i < iteration; i++) {
                const category = data[i];
                const pinned = category.pinned === "1";

                let catName = (pinned ? "📌" : "") + category.name;
                catName = LRR.encodeHTML(catName);

                const div = `<div style='display:inline-block'>
                    <input class='favtag-btn ${((category.id === Index.selectedCategory) ? "toggled" : "")}' 
                            type='button' id='${category.id}' value='${catName}' 
                            onclick='Index.toggleCategory(this)' title='${I18N.CategoryDesc}'/>
                </div>`;

                // Take this opportunity to update the bookmark
                if (category.id === localStorage.getItem("bookmarkCategoryId")) {
                    localStorage.setItem("bookmarkedArchives", JSON.stringify(category.archives));
                }

                html += div;
            }

            // If more than 10 categories, the rest goes into a dropdown
            if (data.length > 10) {
                html += `<select id="catdropdown" class="favtag-btn">
                            <option selected disabled>...</option>`;

                for (let i = 10; i < data.length; i++) {
                    const category = data[i];

                    html += `<option id='${category.id}'>
                                ${LRR.encodeHTML(category.name)}
                            </option>`;
                }
                html += "</select>";
            }

            $("#category-container").html(html);

            // Add a listener on dropdown selection
            $("#catdropdown").on("change", () => Index.toggleCategory($("#catdropdown")[0].selectedOptions[0]));
        },
    );
};

/**
 * If server-side progress tracking is enabled, migrate local progression to the server.
 */
Index.migrateProgress = function () {
    // No migration if local progress is enabled, or if progress is authenticated and we're not logged in.
    if (Index.isProgressLocal || (Index.isProgressAuthenticated && !LRR.isUserLogged())) {
        return;
    }

    const localProgressKeys = Object.keys(localStorage).filter((x) => x.endsWith("-reader")).map((x) => x.slice(0, -7));
    if (localProgressKeys.length > 0) {
        LRR.toast({
            heading: I18N.LocalProgression,
            text: I18N.LocalProgressionDesc + " ☕",
            icon: "info",
            hideAfter: 23000,
        });

        const promises = [];
        localProgressKeys.forEach((id) => {
            const progress = localStorage.getItem(`${id}-reader`);

            promises.push(fetch(new LRR.apiURL(`api/archives/${id}/metadata`), { method: "GET" })
                .then((response) => response.json())
                .then((data) => {
                    // Don't migrate if the server progress is already further
                    if (progress !== null
                        && data !== undefined
                        && data !== null
                        && progress > data.progress) {
                        Server.callAPI(`api/archives/${id}/progress/${progress}?force=1`, "PUT", null, I18N.LocalProgressionError, null);
                    }

                    // Clear out localStorage'd progress
                    localStorage.removeItem(`${id}-reader`);
                    localStorage.removeItem(`${id}-totalPages`);
                }));
        });

        Promise.all(promises).then(() => LRR.toast({
            heading: I18N.LocalProgressionComplete + " 🎉",
            text: I18N.LocalProgressionCompleteDesc,
            icon: "success",
            hideAfter: 13000,
        }));
    } else {
        // eslint-disable-next-line no-console
        console.log("No local reading progression to migrate");
    }
};

/**
 * Restore and update column width, data store in localstorge.
 */
Index.resizableColumns = function () {
    let currentHeader;
    let currentIndex;
    let startX;
    let startWidth;
    let didDrag = false;

    const headers = document.querySelectorAll("#header-row th");
    headers.forEach(header => {
        // init
        header.addEventListener("mousedown", function (event) {
            if (event.offsetX > header.offsetWidth - 10) {
                currentHeader = header;
                currentIndex = Array.from(headers).indexOf(currentHeader);
                startX = event.clientX;

                startWidth = localStorage.getItem(`resizeColumn${currentIndex}`) || header.width || header.offsetWidth;
                if (!Number.isInteger(startWidth))
                    startWidth = parseInt(startWidth.replace("px", ""));

                didDrag = false;

                document.addEventListener("mousemove", resizeColumn);
                document.addEventListener("mouseup", stopResize);

                document.body.style.cursor = "col-resize";
            }
        });
        header.addEventListener("click", function (e) {
            if (didDrag) {
                // If releasing from a drag, block click.DT handler from triggering a draw.
                e.stopImmediatePropagation();
                didDrag = false;
            }
        }, true);
        header.addEventListener("mousemove", function (event) {
            if (event.offsetX > header.offsetWidth - 10) {
                header.style.cursor = "col-resize";
            } else {
                header.style.cursor = "default";
            }
        });
    });

    function resizeColumn(event) {
        didDrag = true;
        if (currentHeader) {
            currentHeader.style.cursor = "col-resize";
            let newWidth = startWidth + (event.clientX - startX);
            const minWidth = parseInt(window.getComputedStyle(currentHeader).minWidth.replace("px", ""));
            const maxWidth = parseInt(window.getComputedStyle(currentHeader).maxWidth.replace("px", ""));

            if (newWidth > maxWidth)
                newWidth = maxWidth;

            if (newWidth < minWidth)
                newWidth = minWidth;

            if (newWidth > 0) {
                currentHeader.style.width = newWidth + "px";
                localStorage.setItem(`resizeColumn${currentIndex}`, newWidth + "px");
            }
        }
    }

    function stopResize() {
        if (currentHeader) {
            currentHeader = null;
        }
        document.removeEventListener("mousemove", resizeColumn);
        document.removeEventListener("mouseup", stopResize);

        document.body.style.cursor = "default";
    }
};

/**
 * @returns number of custom columns in compact mode
 */
Index.getColumnCount = function () {
    return localStorage.getItem("columnCount") ? parseInt(localStorage.getItem("columnCount")) : 2;
}

jQuery(() => {
    Index.initializeAll();
});
