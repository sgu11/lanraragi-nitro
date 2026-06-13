import { existsSync } from "node:fs";
import { chromium } from "playwright-core";

const baseUrl = process.env.LANRARAGI_BASE_URL || "http://localhost:3000";
const readerId = process.env.LANRARAGI_READER_ID;
const chromeCandidates = [
    process.env.CHROME_PATH,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
].filter(Boolean);

const chromePath = chromeCandidates.find((candidate) => existsSync(candidate));

function fail(message) {
    console.error(message);
    process.exit(1);
}

if (!readerId) {
    fail("LANRARAGI_READER_ID is required, for example: LANRARAGI_READER_ID=<archive-id> npm run smoke:reader-chrome");
}

if (!chromePath) {
    fail("Chrome/Chromium was not found. Set CHROME_PATH to a Chrome-compatible executable.");
}

const browser = await chromium.launch({
    executablePath: chromePath,
    headless: true,
    args: ["--no-sandbox"],
});

const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const consoleErrors = [];
const pageErrors = [];

page.on("console", (message) => {
    if (message.type() === "error") {
        consoleErrors.push(message.text());
    }
});
page.on("pageerror", (error) => {
    pageErrors.push(error.message);
});

try {
    await page.goto(baseUrl, { waitUntil: "domcontentloaded" });
    await page.evaluate(() => {
        localStorage.hideHeader = "true";
        localStorage.infiniteScroll = "false";
        localStorage.fitMode = "fit-height";
    });

    const readerUrl = new URL("/reader", baseUrl);
    readerUrl.searchParams.set("id", readerId);
    await page.goto(readerUrl.toString(), { waitUntil: "networkidle" });
    await page.waitForSelector("body.reader-minimal-chrome", { timeout: 10000 });

    const result = await page.evaluate(() => {
        const styles = (selector) => {
            const element = document.querySelector(selector);
            if (!element) {
                return null;
            }
            const computed = getComputedStyle(element);
            return {
                display: computed.display,
                flexDirection: computed.flexDirection,
                gap: computed.gap,
                height: computed.height,
                maxHeight: computed.maxHeight,
            };
        };

        return {
            bodyClass: document.body.className,
            rightControls: styles("#i4 .absolute-right"),
            bottomChrome: styles("#i5"),
            utilityChrome: styles("#i7"),
            image: styles(".reader-image"),
            display: styles("#display"),
            hasReaderChromeStylesheet: [...document.styleSheets].some((sheet) => sheet.href?.includes("/css/reader-chrome.css")),
            scrollHeight: document.documentElement.scrollHeight,
            viewportHeight: window.innerHeight,
        };
    });

    const failures = [];
    if (!result.hasReaderChromeStylesheet) {
        failures.push("reader-chrome.css was not loaded");
    }
    if (result.rightControls?.display !== "flex" || result.rightControls?.flexDirection !== "column") {
        failures.push("minimal side controls are not stacked vertically");
    }
    if (result.rightControls?.gap !== "12px") {
        failures.push(`minimal side control gap is ${result.rightControls?.gap}, expected 12px`);
    }
    if (result.bottomChrome?.display !== "none" || result.utilityChrome?.display !== "none") {
        failures.push("bottom reader chrome is visible");
    }
    if (result.scrollHeight > result.viewportHeight + 1) {
        failures.push(`reader document scrolls: ${result.scrollHeight}px > ${result.viewportHeight}px`);
    }
    if (pageErrors.length > 0) {
        failures.push(`page errors: ${pageErrors.join(" | ")}`);
    }
    if (consoleErrors.length > 0) {
        failures.push(`console errors: ${consoleErrors.join(" | ")}`);
    }

    if (failures.length > 0) {
        console.error(JSON.stringify({ result, failures }, null, 2));
        process.exit(1);
    }

    console.log(JSON.stringify(result, null, 2));
} finally {
    await browser.close();
}
