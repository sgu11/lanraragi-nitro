import { expect, test } from "./obscura";

test("index HTTP response and static DOM load through Obscura", async ({ page }) => {
    const response = await page.goto("/", { waitUntil: "domcontentloaded" });
    expect(response, "GET / should return a response (is LRR running?)").not.toBeNull();
    expect(response!.ok(), `GET / status ${response!.status()} should be ok`).toBeTruthy();
    await expect(page.locator("body")).toBeVisible();
});
