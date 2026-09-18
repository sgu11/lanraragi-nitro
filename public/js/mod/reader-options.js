/** Keep settings presentation separate from image and navigation lifetimes. */
export function applyReaderSettingsUI({ mangaMode, doublePageMode, ignoreProgress,
    infiniteScroll, showOverlayByDefault, markersVisible, imageQuality,
    mobileFullscreen, containerWidth }) {
    // Initialize settings and button toggles
    if (localStorage.hideHeader === "true" || false) {
        $("#hide-header").addClass("toggled");
    } else {
        $("#show-header").addClass("toggled");
    }

    if (mangaMode) {
        $("#manga-mode").addClass("toggled");
        $(".reading-direction").toggleClass("fa-arrow-left fa-arrow-right");
    } else {
        $("#normal-mode").addClass("toggled");
    }

    doublePageMode ? $("#double-page").addClass("toggled") : $("#single-page").addClass("toggled");

    ignoreProgress ? $("#untrack-progress").addClass("toggled") : $("#track-progress").addClass("toggled");

    $(infiniteScroll ? "#infinite-scroll-on" : "#infinite-scroll-off").addClass("toggled");

    $(showOverlayByDefault ? "#show-overlay" : "#hide-overlay").addClass("toggled");

    if (localStorage.fitMode === "fit-width") {
        $("#fit-width").addClass("toggled");
        $("#container-width").hide();
    } else if (localStorage.fitMode === "fit-height") {
        $("#fit-height").addClass("toggled");
        $("#container-width").hide();
    } else {
        $("#fit-container").addClass("toggled");
    }

    if (containerWidth) { $("#container-width-input").val(containerWidth); }

    $("#toggle-stamps").prop("checked", markersVisible);

    // fork: image quality / interpolation
    $("#image-quality input").removeClass("toggled");
    const qualityMap = { "auto": "#quality-auto", "high-quality": "#quality-high", "smooth-sharp": "#quality-sharp", "pixelated": "#quality-pixelated" };
    $(qualityMap[imageQuality] || "#quality-auto").addClass("toggled");


    // fork: auto-fullscreen-on-first-click
    $(mobileFullscreen ? "#mobile-fullscreen-on" : "#mobile-fullscreen-off").addClass("toggled");
    initializeToggleAccessibility();
}

function initializeToggleAccessibility() {
    const settings = document.getElementById("settingsOverlay");
    if (!settings || settings.dataset.toggleA11yInitialized === "true") return;
    settings.dataset.toggleA11yInitialized = "true";

    const sync = (button) => button.setAttribute("aria-pressed", button.classList.contains("toggled") ? "true" : "false");
    settings.querySelectorAll(".config-btn").forEach(sync);
    new MutationObserver((records) => {
        records.forEach((record) => {
            if (record.target.matches(".config-btn")) sync(record.target);
        });
    }).observe(settings, { subtree: true, attributes: true, attributeFilter: ["class"] });
}
