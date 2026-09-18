import * as Server from "lrr-server";
import * as LRR from "lrr-common";
import * as Perf from "lrr-perf";
import I18N from "i18n";

const OVERLAY_PAGE_WINDOW_SIZE = 60;

/** Page-list presentation owns filtering; navigation remains in the reader. */
export function createReaderOverlay({ getState, setCurrentChapter, getCurrentChapter,
    getArchiveForPage, goToPage, pageThumbnails }) {
    let overlayFiltered = false;
    function updateArchiveOverlay(forceUpdate = false, requestedStartPage = null) {
        const { currentPage, currentChapter, content, pages } = getState();
        $("#extract-spinner").hide();

        const overlay = $("#archivePagesOverlay");
        const nextChapter = getCurrentChapter();
        const sameChapter = (currentChapter === null && nextChapter === null)
            || (currentChapter !== null && nextChapter !== null
                && currentChapter.startPage === nextChapter.startPage
                && currentChapter.endPage === nextChapter.endPage);
        const visibleFirst = Number(overlay.attr("data-first-page"));
        const visibleLast = Number(overlay.attr("data-last-page"));
        if (overlay.attr("loaded") === "true" && !forceUpdate && sameChapter
            && currentPage + 1 >= visibleFirst && currentPage + 1 <= visibleLast) {
            return;
        }

        // Reset stamp filter state when the overlay is rebuilt for a new chapter
        if (overlayFiltered) {
            overlayFiltered = false;
            $("#filter-stamped").removeClass("toggled");
        }

        // Otherwise, update chapter and overlay -- If there are no chapters defined, just show all pages
        setCurrentChapter(nextChapter);
        const firstPage = nextChapter ? nextChapter.startPage : 1;
        const lastPage = nextChapter ? nextChapter.endPage : pages.length;
        const latestWindowStart = Math.max(firstPage, lastPage - OVERLAY_PAGE_WINDOW_SIZE + 1);
        const centeredWindowStart = Math.max(
            firstPage,
            Math.min(latestWindowStart, currentPage + 1 - Math.floor(OVERLAY_PAGE_WINDOW_SIZE / 2)),
        );
        const windowStart = Number.isInteger(requestedStartPage)
            ? Math.max(firstPage, Math.min(latestWindowStart, requestedStartPage))
            : centeredWindowStart;
        const windowEnd = Math.min(lastPage, windowStart + OVERLAY_PAGE_WINDOW_SIZE - 1);

        $("#overlay-section").text(nextChapter ? nextChapter.name : I18N.ReaderPages);

        if (nextChapter !== null) {
            // Create <select> options for jumping to other chapters
            let chapterOptions = `<select class="favtag-btn" id="chapter-select">`;
            if (content.chapters) {
                content.chapters.forEach((chapter) => {
                    const selected = (nextChapter && chapter.startPage === nextChapter.startPage) ? "selected" : "";
                    chapterOptions += `<option value="${chapter.startPage}" ${selected}>${LRR.encodeHTML(chapter.name)}</option>`;

                    if (chapter.chapters && chapter.chapters.length > 0) {
                        chapter.chapters.forEach((subChapter) => {
                            const subSelected = (nextChapter && subChapter.startPage === nextChapter.startPage) ? "selected" : "";
                            chapterOptions += `<option value="${subChapter.startPage}" ${subSelected}>&nbsp;&nbsp;&nbsp;${LRR.encodeHTML(subChapter.name)}</option>`;
                        });
                    }
                });
            }
            chapterOptions += `</select>`;

            if (LRR.isUserLogged() && nextChapter.chapters === null ) // Only show edit/delete options for leaf chapters
                chapterOptions += `<a class="fas fa-pencil-alt edit-toc" href="#" style="padding:8px; font-size:14px" title="${I18N.ReaderEditToc}"/>
                                <a class="fas fa-trash-alt remove-toc" href="#" style="padding:8px; font-size:14px" title="${I18N.ReaderDeleteToc}"/>`;

            $(".chapter-selector").html(chapterOptions);

            $("#chapter-select").off("change").on("change", function () {
                goToPage($(this).val() - 1);
            });
        } else {
            $(".chapter-selector").html("");
        }

        // Render a bounded window instead of creating six DOM nodes per page for
        // the entire archive. Previous/next controls keep every page reachable.
        let htmlBlob = `<div class="overlay-window-controls">`;
        if (windowStart > firstPage) {
            htmlBlob += `<button type="button" class="stdbtn overlay-window-button" data-start-page="${Math.max(firstPage, windowStart - OVERLAY_PAGE_WINDOW_SIZE)}">${I18N.ReaderPreviousPages || "Previous pages"}</button>`;
        }
        htmlBlob += `<span>${windowStart}–${windowEnd} / ${lastPage}</span>`;
        if (windowEnd < lastPage) {
            htmlBlob += `<button type="button" class="stdbtn overlay-window-button" data-start-page="${windowEnd + 1}">${I18N.ReaderNextPages || "Next pages"}</button>`;
        }
        htmlBlob += `</div><div class="overlay-window-pages">`;

        for (let page = windowStart; page <= windowEnd; ++page) {
            const index = page - 1;

            const thumbCss = (localStorage.cropthumbs === "true") ? "id3" : "id3 nocrop";
            const { arcId, localPage } = getArchiveForPage(page);
            const thumbnailUrl = new LRR.ApiURL(`/api/archives/${arcId}/thumbnail?page=${localPage}`);

            let thumbnail = `
                <div class='${thumbCss} quick-thumbnail' page='${index}' style='display: inline-block; cursor: pointer'>
                    <span class='page-number'>${I18N.ReaderPage(page)}</span>
                    <img src="${thumbnailUrl}" id="${index}_thumb" loading="lazy" alt="${I18N.ReaderPage(page)}" />`;

            if (LRR.isUserLogged())
                thumbnail += `<a href="#" style="padding:12px; top:2%; left:72%;"
                                 title="${I18N.ReaderSetPageAsThumbnail}"
                                 class="fas fa-file-image page-number set-thumbnail"></a>
                              <a href="#" style="padding:12px; top:80%; left:72%;"
                                 title="${I18N.ReaderAddToc}"
                                 class="fas fa-book-medical page-number add-toc"></a>`;

            if (pageThumbnails.has(index)) thumbnail +=
                `</div>`;
            else thumbnail +=
                    `<i id="${index}_spinner" class="fa fa-4x fa-circle-notch fa-spin ttspinner" style="display:flex;justify-content: center; align-items: center;"></i>
                </div>`;

            htmlBlob += thumbnail;
        }
        htmlBlob += `</div>`;

        // NOTE: This can be slow on huge archives and on slower devices, due to the huge DOM change.
        Perf.measure("reader.overlay", () => {
            $("#pages-section").html(htmlBlob);
        });
        overlay
            .attr("loaded", "true")
            .attr("data-first-page", windowStart)
            .attr("data-last-page", windowEnd);
        checkStampedPages();
    }

    function checkStampedPages() {
        const { currentPage } = getState();
        const { arcId } = getArchiveForPage(currentPage + 1);
        Server.callAPI(`/api/archives/${arcId}/stamps/`, "GET", null, I18N.ServerInfoError,
            (data) => {
                $("#extract-spinner").hide();
                cleanStampedPages();
                let pages = data.result.sort();
                let elements = $("div.id3.quick-thumbnail");

                for (let element of elements) {
                    let page = parseInt(element.getAttribute("page"));
                    const { _, localPage } = getArchiveForPage(page+1);

                    if (pages.includes((localPage).toString())) {
                        element.dataset.stamped = true;
                    }
                }
            }
        );
    }

    function cleanStampedPages() {
        let elements = $("div.id3.quick-thumbnail[data-stamped=true]");

        for (let element of elements) {
            delete element.dataset.stamped;
        }
    }

    function filterStampedOverlay() {
        let elements = $("div.id3.quick-thumbnail");

        if (overlayFiltered) {
            overlayFiltered = false;
            $("#filter-stamped").removeClass("toggled");
            for (let element of elements) {
                element.style.display = `inline-block`;
            }
        } else {
            overlayFiltered = true;
            $("#filter-stamped").addClass("toggled");
            for (let element of elements) {
                if (!element.dataset.stamped) {
                    element.style.display = `none`;
                }
            }
        }
    }

    return { updateArchiveOverlay, checkStampedPages, filterStampedOverlay };
}
