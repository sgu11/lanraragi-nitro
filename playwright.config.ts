import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  reporter: "line",
  use: {
    baseURL: process.env.LANRARAGI_BASE_URL || "http://127.0.0.1:3000",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"], trace: "on-first-retry" },
      testMatch: "**/smoke.spec.ts",
    },
    {
      name: "obscura",
      use: { ...devices["Desktop Chrome"] },
      testMatch: "**/obscura-smoke.spec.ts",
    },
  ],
  webServer: [
    {
      command: "perl ./script/launcher.pl -m -v ./script/lanraragi",
      url: process.env.LANRARAGI_BASE_URL || "http://127.0.0.1:3000",
      reuseExistingServer: !process.env.CI,
      timeout: 120 * 1000,
      stdout: "pipe",
      stderr: "pipe",
    },
    ...(process.env.OBSCURA_CDP_URL === undefined
      ? [
          {
            // Only the static availability smoke uses Obscura. Dynamic module,
            // interaction, reader, and performance checks require Chromium.
            command: "obscura serve --port 9222 --allow-private-network",
            url: "http://127.0.0.1:9222/json/version",
            reuseExistingServer: true,
            timeout: 60_000,
          },
        ]
      : []),
  ],
});
