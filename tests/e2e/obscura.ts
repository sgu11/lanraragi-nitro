import { chromium, test as base } from "@playwright/test";

const cdpUrl = process.env.OBSCURA_CDP_URL;

export const test = base.extend({
  page: async ({ baseURL, viewport }, use) => {
    const browser =
      cdpUrl === ""
        ? await chromium.launch()
        : await chromium.connectOverCDP(cdpUrl ?? "http://127.0.0.1:9222");
    const context = await browser.newContext({
      ...(baseURL ? { baseURL } : {}),
      ...(viewport ? { viewport } : {}),
    });
    const page = await context.newPage();
    await use(page);
    await context.close();
    await browser.close();
  },
});

export { expect } from "@playwright/test";
