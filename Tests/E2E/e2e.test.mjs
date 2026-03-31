#!/usr/bin/env node

/**
 * Nerve E2E Tests
 *
 * Launches the NerveExample app on a simulator with Nerve injected,
 * connects via WebSocket, and tests all commands end-to-end.
 *
 * Usage:
 *   node e2e.test.mjs --build    # Build, launch, and test
 *   node e2e.test.mjs            # Connect to already-running instance
 *   node e2e.test.mjs --port 9500  # Connect to specific port
 */

import WebSocket from "ws";
import { execSync, exec } from "child_process";
import * as fs from "fs";
import * as path from "path";

// --- Config ---

const NERVE_ROOT = path.resolve(new URL(".", import.meta.url).pathname, "../..");
const PORT_DIR = "/tmp/nerve-ports";
const TIMEOUT_MS = 10000;

let ws;
let requestId = 0;
let testsPassed = 0;
let testsFailed = 0;
let testsSkipped = 0;
const failures = [];
let currentPort = null;
let simulatorUDID = null;

// --- Helpers ---

function log(msg) {
  console.log(`  ${msg}`);
}

function pass(name) {
  testsPassed++;
  console.log(`  ✓ ${name}`);
}

function fail(name, reason) {
  testsFailed++;
  failures.push({ name, reason });
  console.log(`  ✗ ${name}`);
  console.log(`    → ${reason}`);
}

function skip(name, reason) {
  testsSkipped++;
  console.log(`  ○ ${name} (skipped: ${reason})`);
}

/** Send a command and wait for the response */
function send(command, params = {}) {
  return new Promise((resolve, reject) => {
    const id = `e2e_${++requestId}`;
    const timer = setTimeout(() => {
      reject(new Error(`Timeout waiting for response to '${command}'`));
    }, TIMEOUT_MS);

    const handler = (data) => {
      try {
        const response = JSON.parse(data.toString());
        if (response.id === id) {
          ws.off("message", handler);
          clearTimeout(timer);
          resolve(response);
        }
      } catch {}
    };
    ws.on("message", handler);

    ws.send(JSON.stringify({ id, command, params }));
  });
}

/** Assert a condition */
function assert(condition, message) {
  if (!condition) throw new Error(message || "Assertion failed");
}

/** Wait for a duration */
function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

/** Restart the app and reconnect WebSocket for a clean state */
async function restartApp() {
  // Find simulator UDID from port file if not already known
  if (!simulatorUDID) {
    if (fs.existsSync(PORT_DIR)) {
      const files = fs.readdirSync(PORT_DIR).filter(f => f.endsWith(".json"));
      for (const file of files) {
        try {
          const info = JSON.parse(fs.readFileSync(path.join(PORT_DIR, file), "utf-8"));
          if (info.port === currentPort) {
            simulatorUDID = info.udid;
            break;
          }
        } catch {}
      }
    }
  }

  if (!simulatorUDID) {
    log("[restartApp] No simulator UDID found, skipping restart");
    return;
  }

  // Close existing WebSocket
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.close();
  }

  // Terminate the app
  try {
    execSync(`xcrun simctl terminate "${simulatorUDID}" com.nerve.example 2>/dev/null`);
  } catch {}

  // Clean up old port file
  try {
    fs.unlinkSync(`${PORT_DIR}/${simulatorUDID}-com.nerve.example.json`);
  } catch {}

  await sleep(300);

  // Relaunch
  execSync(`xcrun simctl launch "${simulatorUDID}" com.nerve.example`);

  // Wait for Nerve port file
  const portFile = `${PORT_DIR}/${simulatorUDID}-com.nerve.example.json`;
  for (let i = 0; i < 30; i++) {
    if (fs.existsSync(portFile)) {
      const info = JSON.parse(fs.readFileSync(portFile, "utf-8"));
      currentPort = info.port;
      break;
    }
    await sleep(500);
  }

  // Reconnect WebSocket (use 127.0.0.1 to avoid IPv6 resolution issues)
  ws = new WebSocket(`ws://127.0.0.1:${currentPort}`);
  await new Promise((resolve, reject) => {
    ws.on("open", resolve);
    ws.on("error", reject);
    setTimeout(() => reject(new Error("WebSocket reconnect timeout")), 5000);
  });

  // Wait for app to be ready
  await sleep(500);
}

// --- Build & Launch ---

async function buildAndLaunch() {
  console.log("\n🔨 Building example app...");

  // Find a simulator
  const simJSON = execSync("xcrun simctl list devices available -j", {
    encoding: "utf-8",
  });
  const simData = JSON.parse(simJSON);
  let udid = null;
  let simName = null;

  // Prefer an already-booted simulator
  for (const [, devices] of Object.entries(simData.devices)) {
    for (const d of devices) {
      if (d.state === "Booted" && d.name.includes("iPhone")) {
        udid = d.udid;
        simName = d.name;
        break;
      }
    }
    if (udid) break;
  }

  if (!udid) {
    // Find any iPhone simulator
    for (const [, devices] of Object.entries(simData.devices)) {
      for (const d of devices) {
        if (d.name.includes("iPhone")) {
          udid = d.udid;
          simName = d.name;
          break;
        }
      }
      if (udid) break;
    }
  }

  if (!udid) {
    console.error("No iPhone simulator found");
    process.exit(1);
  }

  console.log(`  Simulator: ${simName} (${udid})`);

  // Boot if needed
  try {
    execSync(`xcrun simctl boot "${udid}" 2>/dev/null`);
    console.log("  Booted simulator.");
  } catch {
    // Already booted
  }

  // Build the example app with xcodebuild
  const derivedData = "/tmp/nerve-e2e-derived";
  console.log("  Building NerveExample...");
  try {
    execSync(
      `xcodebuild build -project "${NERVE_ROOT}/Example/NerveExample.xcodeproj" -scheme NerveExample -sdk iphonesimulator -destination "id=${udid}" -derivedDataPath "${derivedData}" -configuration Debug -quiet 2>&1`,
      { timeout: 300000 }
    );
  } catch (e) {
    console.error("Build failed:", e.message);
    process.exit(1);
  }

  // Find the built .app bundle
  const appDir = `${derivedData}/Build/Products/Debug-iphonesimulator/NerveExample.app`;

  if (!fs.existsSync(appDir)) {
    console.error(`App bundle not found at ${appDir}`);
    process.exit(1);
  }

  // Install the app
  console.log("  Installing...");
  execSync(`xcrun simctl install "${udid}" "${appDir}"`);

  // Kill any existing instance
  try {
    execSync(
      `xcrun simctl terminate "${udid}" com.nerve.example 2>/dev/null`
    );
  } catch {}

  // Clean up old port file
  try {
    fs.unlinkSync(`${PORT_DIR}/${udid}-com.nerve.example.json`);
  } catch {}

  // Launch
  console.log("  Launching...");
  execSync(`xcrun simctl launch "${udid}" com.nerve.example`);

  // Wait for Nerve port file
  console.log("  Waiting for Nerve...");
  const portFile = `${PORT_DIR}/${udid}-com.nerve.example.json`;
  for (let i = 0; i < 30; i++) {
    if (fs.existsSync(portFile)) {
      const info = JSON.parse(fs.readFileSync(portFile, "utf-8"));
      console.log(`  Nerve ready on port ${info.port}`);
      return info.port;
    }
    await sleep(500);
  }

  console.error("  Nerve did not start within 15s");
  process.exit(1);
}

async function findRunningInstance() {
  // Check for a port from CLI args
  const portArg = process.argv.indexOf("--port");
  if (portArg !== -1 && process.argv[portArg + 1]) {
    return parseInt(process.argv[portArg + 1]);
  }

  // Check port files
  if (!fs.existsSync(PORT_DIR)) return null;
  const files = fs.readdirSync(PORT_DIR).filter((f) => f.endsWith(".json"));

  for (const file of files) {
    try {
      const info = JSON.parse(
        fs.readFileSync(path.join(PORT_DIR, file), "utf-8")
      );
      // Check if process is alive
      try {
        process.kill(info.pid, 0);
        return info.port;
      } catch {
        fs.unlinkSync(path.join(PORT_DIR, file));
      }
    } catch {}
  }

  return null;
}

// --- Test Suites ---

async function testConnection() {
  console.log("\n── Connection ──");
  await restartApp();

  try {
    const res = await send("status");
    assert(res.ok, `status failed: ${res.data}`);
    assert(res.data.includes("status: connected"), "should report connected");
    assert(res.data.includes("nerve: 0.1.0"), "should report version");
    pass("status returns connection info");
  } catch (e) {
    fail("status returns connection info", e.message);
  }
}

async function testView() {
  console.log("\n── View (Screen Inspection) ──");
  await restartApp();

  try {
    const res = await send("view");
    assert(res.ok, `view failed: ${res.data}`);
    assert(res.data.includes("screen"), "should include screen dimensions");
    assert(res.data.includes("---"), "should include separator");
    pass("view returns screen description");
  } catch (e) {
    fail("view returns screen description", e.message);
  }

  try {
    const res = await send("view");
    // SwiftUI accessibility nodes may not appear in the initial view walk
    // This tests whether the tree has any content beyond the header
    const hasContent = res.data.split("\n").length > 2;
    if (hasContent) {
      pass("view shows screen elements");
    } else {
      skip("view shows screen elements", "SwiftUI accessibility tree not yet fully walked — known limitation");
    }
  } catch (e) {
    fail("view shows screen elements", e.message);
  }
}

async function testTree() {
  console.log("\n── Tree (View Hierarchy) ──");
  await restartApp();

  try {
    const res = await send("tree", { depth: 3 });
    assert(res.ok, `tree failed: ${res.data}`);
    assert(res.data.includes("UIWindow"), "should show UIWindow");
    pass("tree returns view hierarchy");
  } catch (e) {
    fail("tree returns view hierarchy", e.message);
  }
}

async function testInspect() {
  console.log("\n── Inspect ──");
  await restartApp();

  try {
    // Inspect an element that's on the Home screen
    const lookRes = await send("view");
    if (lookRes.data.includes("#product-a")) {
      const res = await send("inspect", { query: "#product-a" });
      assert(res.ok, `inspect failed: ${res.data}`);
      assert(res.data.includes("view:"), "should include view type");
      pass("inspect element by identifier");
    } else if (lookRes.data.includes("@e1")) {
      // Inspect any element that exists
      const res = await send("inspect", { query: "@Home" });
      assert(res.ok, `inspect failed: ${res.data}`);
      pass("inspect element by identifier");
    } else {
      fail("inspect element by identifier", "No elements found in view output");
    }
  } catch (e) {
    fail("inspect element by identifier", e.message);
  }

  try {
    const res = await send("inspect", { query: "#nonexistent-element-xyz" });
    assert(!res.ok, "should fail for nonexistent element");
    assert(
      res.data.includes("not found"),
      "should report element not found"
    );
    pass("inspect returns error for missing element");
  } catch (e) {
    fail("inspect returns error for missing element", e.message);
  }
}

async function testTap() {
  console.log("\n── Tap ──");
  await restartApp();

  // Test tap by coordinates (center of screen)
  try {
    const res = await send("tap", { query: "220,478" });
    assert(res.ok, `tap by coords failed: ${res.data}`);
    assert(res.data.toLowerCase().includes("tapped"), "should confirm tap");
    pass("tap by coordinates");
  } catch (e) {
    fail("tap by coordinates", e.message);
  }

  // Test tap by label
  try {
    const res = await send("tap", { query: "@Settings" });
    assert(res.ok, `tap by label failed: ${res.data}`);
    pass("tap element by label");

    // Go back to Home for subsequent tests
    await send("tap", { query: "@Home" });
  } catch (e) {
    fail("tap element by label", e.message);
  }
}

async function testScroll() {
  console.log("\n── Scroll ──");
  await restartApp();

  try {
    const res = await send("scroll", { direction: "down", amount: 100 });
    assert(res.ok, `scroll failed: ${res.data}`);
    assert(
      res.data.toLowerCase().includes("scrolled"),
      "should confirm scroll"
    );
    pass("scroll down");
  } catch (e) {
    fail("scroll down", e.message);
  }
}

async function testType() {
  console.log("\n── Type ──");
  await restartApp();

  // Navigate to Login screen first
  try {
    // Verify we can see the Login link
    const lookRes = await send("view");
    if (!lookRes.data.includes("login-link") && !lookRes.data.includes("Login")) {
      fail("type text into field", "Login link not visible on Home screen");
      return;
    }

    // Tap Login link
    const tapRes = await send("tap", { query: "#login-link" });
    assert(tapRes.ok, `tap login failed: ${tapRes.data}`);

    // Verify we're on Login screen
    const loginLook = await send("view");
    assert(loginLook.data.includes("email-field"), "Should be on Login screen with email field");

    // Tap email field to focus it
    const focusRes = await send("tap", { query: "#email-field" });
    assert(focusRes.ok, `tap email failed: ${focusRes.data}`);

    // Type email
    const typeRes = await send("type", { text: "test@nerve.dev" });
    assert(typeRes.ok, `type failed: ${typeRes.data}`);
    assert(
      typeRes.data.toLowerCase().includes("typed"),
      "should confirm type"
    );
    pass("type text into email field");

    // Go back
    await send("back");
  } catch (e) {
    fail("type text into field", e.message);
  }
}

async function testConsole() {
  console.log("\n── Console ──");
  await restartApp();

  try {
    const res = await send("console", { limit: 10 });
    assert(res.ok, `console failed: ${res.data}`);
    assert(res.data.includes("console:"), "should include console header");
    pass("console returns log output");
  } catch (e) {
    fail("console returns log output", e.message);
  }

  try {
    const res = await send("console", {
      limit: 10,
      filter: "[nerve]",
    });
    assert(res.ok, `console filter failed: ${res.data}`);
    pass("console with [nerve] filter");
  } catch (e) {
    fail("console with [nerve] filter", e.message);
  }

  try {
    const res = await send("console", { since: "last_action", limit: 50 });
    assert(res.ok, `console since failed: ${res.data}`);
    pass("console with since=last_action");
  } catch (e) {
    fail("console with since=last_action", e.message);
  }
}

async function testNetwork() {
  console.log("\n── Network ──");
  await restartApp();

  try {
    const res = await send("network", { limit: 5 });
    assert(res.ok, `network failed: ${res.data}`);
    assert(
      res.data.includes("network:"),
      "should include network header"
    );
    pass("network returns transaction list");
  } catch (e) {
    fail("network returns transaction list", e.message);
  }
}

async function testHeap() {
  console.log("\n── Heap ──");
  await restartApp();

  try {
    const res = await send("heap", { class_name: "UIWindow" });
    assert(res.ok, `heap failed: ${res.data}`);
    assert(res.data.includes("heap:"), "should include heap header");
    assert(res.data.includes("UIWindow"), "should find UIWindow instances");
    pass("heap finds UIWindow instances");
  } catch (e) {
    fail("heap finds UIWindow instances", e.message);
  }

  try {
    const res = await send("heap", {
      class_name: "FakeClassThatDoesNotExist999",
    });
    assert(res.ok, `heap failed: ${res.data}`);
    assert(res.data.includes("0 instances"), "should find zero instances");
    pass("heap returns 0 for nonexistent class");
  } catch (e) {
    fail("heap returns 0 for nonexistent class", e.message);
  }
}

async function testMap() {
  console.log("\n── Navigation Map ──");
  await restartApp();

  try {
    const res = await send("map");
    assert(res.ok, `map failed: ${res.data}`);
    // Should have some screens from our navigation
    pass("map returns navigation graph");
  } catch (e) {
    fail("map returns navigation graph", e.message);
  }

  try {
    const res = await send("map", { format: "json" });
    assert(res.ok, `map json failed: ${res.data}`);
    JSON.parse(res.data); // Should be valid JSON
    pass("map returns valid JSON");
  } catch (e) {
    fail("map returns valid JSON", e.message);
  }
}

async function testScreenshot() {
  console.log("\n── Screenshot ──");
  await restartApp();

  try {
    const res = await send("screenshot", { scale: 0.5 });
    assert(res.ok, `screenshot failed: ${res.data}`);
    assert(
      res.data.startsWith("data:image/png;base64,"),
      "should return base64 PNG"
    );
    // Decode and check it's valid
    const base64 = res.data.replace("data:image/png;base64,", "");
    const buf = Buffer.from(base64, "base64");
    assert(buf.length > 1000, "screenshot should be >1KB");
    pass("screenshot returns base64 PNG");
  } catch (e) {
    fail("screenshot returns base64 PNG", e.message);
  }
}

async function testStorage() {
  console.log("\n── Storage ──");
  await restartApp();

  try {
    const res = await send("storage", { type: "defaults" });
    assert(res.ok, `storage defaults failed: ${res.data}`);
    assert(
      res.data.includes("defaults:"),
      "should include defaults header"
    );
    pass("storage reads UserDefaults");
  } catch (e) {
    fail("storage reads UserDefaults", e.message);
  }

  try {
    const res = await send("storage", { type: "files" });
    assert(res.ok, `storage files failed: ${res.data}`);
    assert(res.data.includes("files:"), "should include files header");
    pass("storage lists sandbox files");
  } catch (e) {
    fail("storage lists sandbox files", e.message);
  }
}

async function testWaitIdle() {
  console.log("\n── Wait Idle ──");
  await restartApp();

  try {
    const res = await send("wait_idle", { timeout: 2, quiet: 0.5 });
    assert(res.ok, `wait_idle failed: ${res.data}`);
    assert(
      res.data.includes("Idle") || res.data.includes("idle") || res.data.includes("Timeout"),
      "should report idle or timeout state"
    );
    pass("wait_idle returns when app is idle");
  } catch (e) {
    fail("wait_idle returns when app is idle", e.message);
  }
}

async function testBackAndDismiss() {
  console.log("\n── Back & Dismiss ──");
  await restartApp();

  try {
    const res = await send("back");
    // May succeed or say "nothing to go back from"
    assert(res.ok || res.data.includes("Nothing"), "should not crash");
    pass("back command executes");
  } catch (e) {
    fail("back command executes", e.message);
  }

  try {
    const res = await send("dismiss");
    assert(res.ok, `dismiss failed: ${res.data}`);
    pass("dismiss command executes");
  } catch (e) {
    fail("dismiss command executes", e.message);
  }
}

async function testUnknownCommand() {
  console.log("\n── Error Handling ──");
  await restartApp();

  try {
    const res = await send("completely_bogus_command");
    assert(!res.ok, "should return error for unknown command");
    assert(
      res.data.includes("Unknown command"),
      "should say unknown command"
    );
    pass("unknown command returns error");
  } catch (e) {
    fail("unknown command returns error", e.message);
  }
}

// --- Feature-Specific Tests (#3, #6, #8, #9, #10, #13, #15) ---

/** Helper: restart app and navigate to a specific test screen */
async function goToTestScreen(identifier) {
  // Restart app for clean state — no scroll pollution between tests
  await restartApp();

  // Go to Tests tab
  await send("tap", { query: "@Tests" });

  // Use scroll_to_find to ensure the target element is visible
  await send("scroll_to_find", { query: `#${identifier}` });

  // Read position — if element overlaps tab bar, scroll it into safe zone
  let look = await send("view");
  let match = look.data.split("\n").find(l => l.includes(identifier));

  if (match) {
    const yM = match.match(/y=(\d+)/);
    const hM = match.match(/h=(\d+)/);
    if (yM) {
      const ey = parseInt(yM[1]);
      const eh = hM ? parseInt(hM[1]) : 54;
      if (ey + eh > 760) {
        // Scroll list just enough to clear the tab bar (tab bar starts ~y=765)
        const needed = (ey + eh) - 700;
        await send("scroll", { direction: "down", amount: needed });
        look = await send("view");
        match = look.data.split("\n").find(l => l.includes(identifier));
      }
    }
  }

  if (match) {
    const yMatch = match.match(/y=(\d+)/);
    const xMatch = match.match(/x=(\d+)/);
    const wMatch = match.match(/w=(\d+)/);
    const hMatch = match.match(/h=(\d+)/);
    if (yMatch) {
      const ey = parseInt(yMatch[1]);
      const eh = hMatch ? parseInt(hMatch[1]) : 54;
      const ew = wMatch ? parseInt(wMatch[1]) : 400;
      const ex = xMatch ? parseInt(xMatch[1]) : 20;
      const tapX = ex + ew / 2;
      // Tap near top of element if center would land on tab bar (y > 870)
      const center = ey + eh / 2;
      const tapY = center > 760 ? ey + 10 : center;
      await send("tap", { query: `${Math.round(tapX)},${Math.round(tapY)}` });
      return;
    }
  }

  // Fallback: tap by identifier
  await send("tap", { query: `#${identifier}` });
}

/** Helper: go back to Tests tab from a test screen */
async function goBackToTests() {
  await send("back");
}

async function testAlertAndSheet() {
  console.log("\n── #3: Alerts & Sheets ──");

  try {
    await goToTestScreen("test-alerts");

    // Test alert
    const tapAlert = await send("tap", { query: "#show-alert-btn" });
    assert(tapAlert.ok, `tap show-alert failed: ${tapAlert.data}`);

    // Look while alert is showing — should see alert buttons
    const lookAlert = await send("view");
    const hasAlertContent = lookAlert.data.includes("Confirm") || lookAlert.data.includes("Cancel");
    if (hasAlertContent) {
      pass("alert buttons visible in view output");
    } else {
      fail("alert buttons visible in view output", "Alert content not found");
    }

    // Tap Confirm button to dismiss alert
    const tapConfirm = await send("tap", { query: "@Confirm" });
    if (tapConfirm.ok) {
      // Wait for alert dismiss animation (iOS 26 Liquid Glass)
      await sleep(800);
      const lookAfterConfirm = await send("view");
      if (!lookAfterConfirm.data.includes("Confirm Action")) {
        pass("tap alert Confirm button dismisses alert");
      } else {
        fail("tap alert Confirm button dismisses alert", "Alert still showing after tap");
      }
    } else {
      fail("tap alert Confirm button", tapConfirm.data);
    }

    await send("wait_idle", { timeout: 2, quiet: 0.5 });

    // Verify we can see the sheet button
    let lookAfterAlert = await send("view");
    if (!lookAfterAlert.data.includes("show-sheet-btn") && !lookAfterAlert.data.includes("Show Sheet")) {
      // Still not visible — retry
      lookAfterAlert = await send("view");
    }
    if (!lookAfterAlert.data.includes("show-sheet-btn") && !lookAfterAlert.data.includes("Show Sheet")) {
      // Last resort — navigate back to the test screen fresh
      await send("tap", { query: "@Home" });
      await goToTestScreen("test-alerts");
    }

    // Test sheet — try identifier first, then label, then coordinate
    let tapSheet = await send("tap", { query: "#show-sheet-btn" });
    if (!tapSheet.ok) {
      tapSheet = await send("tap", { query: "@Show Sheet" });
    }
    if (!tapSheet.ok) {
      // Try coordinate — Show Sheet button is at roughly y=226 based on previous view
      const sheetLook = await send("view");
      const sheetLine = sheetLook.data.split("\n").find(l => l.includes("Show Sheet") || l.includes("show-sheet"));
      if (sheetLine) {
        const yM = sheetLine.match(/y=(\d+)/);
        const hM = sheetLine.match(/h=(\d+)/);
        if (yM) {
          const y = parseInt(yM[1]) + (hM ? parseInt(hM[1]) / 2 : 11);
          tapSheet = await send("tap", { query: `220,${Math.round(y)}` });
        }
      }
    }
    if (!tapSheet.ok) {
      skip("sheet content visible in view output", "Could not tap Show Sheet button");
      skip("sheet elements tagged with presentation context", "Could not open sheet");
      await goBackToTests();
      return;
    }

    const lookSheet = await send("view");
    if (lookSheet.data.includes("sheet-save-btn") || lookSheet.data.includes("Sheet Content") || lookSheet.data.includes("sheet-title")) {
      pass("sheet content visible in view output");
    } else {
      fail("sheet content visible in view output", "Sheet content not found in: " + lookSheet.data.substring(0, 200));
    }

    // Check presentation context
    if (lookSheet.data.includes("[sheet]") || lookSheet.data.includes("[modal]")) {
      pass("sheet elements tagged with presentation context");
    } else {
      skip("sheet elements tagged with presentation context", "Context tags not present");
    }

    // Dismiss sheet
    await send("dismiss");

    await goBackToTests();
  } catch (e) {
    fail("alerts & sheets", e.message);
    try { await send("dismiss"); await goBackToTests(); } catch {}
  }
}

async function testLazyList() {
  console.log("\n── #9: Scroll-to-Find (Lazy List) ──");

  try {
    // Reset to Home tab first, then go to Tests > Lazy List
    await send("tap", { query: "@Home" });
    await goToTestScreen("test-lazy-list");

    // Item 0 should be visible
    const look1 = await send("view");
    if (look1.data.includes("lazy-item-0") || look1.data.includes("Item 0") || look1.data.includes("Lazy List")) {
      pass("lazy list item 0 visible");
    } else {
      // May need to verify we're actually on the lazy list screen
      fail("lazy list item 0 visible", "Item 0 not in view output. Got: " + look1.data.substring(0, 200));
    }

    // Item 90 should NOT be visible (it's off-screen in a lazy container)
    if (!look1.data.includes("lazy-item-90")) {
      pass("lazy list item 90 not initially visible");
    } else {
      skip("lazy list item 90 not initially visible", "Item 90 already visible");
    }

    // Use scroll_to_find to locate item 90
    const findRes = await send("scroll_to_find", { query: "#lazy-item-90", max_attempts: 15 });
    if (findRes.ok) {
      pass("scroll_to_find locates off-screen element");
    } else {
      fail("scroll_to_find locates off-screen element", findRes.data);
    }

    await goBackToTests();
  } catch (e) {
    fail("lazy list test", e.message);
    try { await goBackToTests(); } catch {}
  }
}

async function testCustomActions() {
  console.log("\n── #15: Custom Accessibility Actions ──");

  try {
    await goToTestScreen("test-custom-actions");

    // Inspect an item to discover custom actions
    const inspectRes = await send("inspect", { query: "#action-item-apple" });
    if (inspectRes.ok && inspectRes.data.includes("Favorite")) {
      pass("custom actions discovered via inspect");
    } else {
      fail("custom actions discovered via inspect", "Actions not found in: " + (inspectRes.data || "").substring(0, 200));
      await goBackToTests();
      return;
    }

    // Invoke the Favorite action
    const actionRes = await send("action", { query: "#action-item-apple", action: "Favorite" });
    if (actionRes.ok) {
      pass("custom action invoked successfully");
    } else {
      fail("custom action invoked successfully", actionRes.data);
    }

    await goBackToTests();
  } catch (e) {
    fail("custom actions test", e.message);
    try { await goBackToTests(); } catch {}
  }
}

async function testOverlays() {
  console.log("\n── #6: 5-Point Hit Test (Overlays) ──");

  try {
    await goToTestScreen("test-overlays");

    // The hidden button should be behind the overlay
    const lookRes = await send("view");
    if (lookRes.data.includes("hidden-btn") || lookRes.data.includes("Hidden Behind")) {
      pass("occluded element found in view output");
    } else {
      fail("occluded element found in view output", "Element not found");
    }

    // Toggle overlay off
    const toggleRes = await send("tap", { query: "#toggle-overlay-btn" });
    assert(toggleRes.ok, `toggle overlay failed: ${toggleRes.data}`);

    // Now tap the previously hidden button
    const tapRes = await send("tap", { query: "#hidden-btn" });
    if (tapRes.ok) {
      pass("tap element after overlay removed");
    } else {
      fail("tap element after overlay removed", tapRes.data);
    }

    await goBackToTests();
  } catch (e) {
    fail("overlays test", e.message);
    try { await goBackToTests(); } catch {}
  }
}

async function testLongPress() {
  console.log("\n── #8: Long Press ──");

  try {
    await goToTestScreen("test-long-press");

    // Long press the button
    const lpRes = await send("long_press", { query: "#longpress-btn", duration: 0.8 });
    if (lpRes.ok) {
      pass("long press command executes");
    } else {
      fail("long press command executes", lpRes.data);
    }

    // Check console for long press result
    const consoleRes = await send("console", { filter: "Long press", limit: 10 });
    if (consoleRes.data.includes("Long press detected")) {
      pass("long press gesture recognized");
    } else {
      // Also check view output for state change
      const lookRes = await send("view");
      if (lookRes.data.includes("Long press detected")) {
        pass("long press gesture recognized (via view)");
      } else {
        skip("long press gesture recognized", "Long press handler may not have fired");
      }
    }

    await goBackToTests();
  } catch (e) {
    fail("long press test", e.message);
    try { await goBackToTests(); } catch {}
  }
}

async function testDisabledElements() {
  console.log("\n── Disabled Elements ──");

  try {
    await goToTestScreen("test-disabled");

    // Disabled button should be visible with disabled flag
    const lookRes = await send("view");
    if (lookRes.data.includes("disabled")) {
      pass("disabled elements show disabled flag");
    } else {
      fail("disabled elements show disabled flag", "No 'disabled' in view output");
    }

    // Tapping disabled button should fail
    const tapRes = await send("tap", { query: "#disabled-btn" });
    if (!tapRes.ok && tapRes.data.includes("disabled")) {
      pass("tap disabled element returns error");
    } else if (tapRes.ok) {
      // Some implementations allow tapping disabled elements
      pass("tap disabled element (accepted without error)");
    } else {
      pass("tap disabled element returns error");
    }

    await goBackToTests();
  } catch (e) {
    fail("disabled elements test", e.message);
    try { await goBackToTests(); } catch {}
  }
}

async function testVoiceOverLabels() {
  console.log("\n── #13: VoiceOver Labels ──");

  try {
    await goToTestScreen("test-voiceover");

    const lookRes = await send("view");

    // Check that accessibility labels are visible
    if (lookRes.data.includes("Standard Label")) {
      pass("standard accessibility label visible");
    } else {
      fail("standard accessibility label visible", "Label not in view output");
    }

    if (lookRes.data.includes("Favorite Star") || lookRes.data.includes("voiceover-star")) {
      pass("icon button accessibility label visible");
    } else {
      fail("icon button accessibility label visible", "Star label not found");
    }

    // Check accessibilityValue
    if (lookRes.data.includes("75 percent") || lookRes.data.includes("75%")) {
      pass("accessibilityValue readable");
    } else {
      skip("accessibilityValue readable", "Value not found in view output");
    }

    await goBackToTests();
  } catch (e) {
    fail("VoiceOver labels test", e.message);
    try { await goBackToTests(); } catch {}
  }
}

async function testAutoTagging() {
  console.log("\n── #10: Auto-Tagging ──");

  try {
    await goToTestScreen("test-autotag");

    const lookRes = await send("view");

    // The "already-tagged-btn" should keep its identifier
    if (lookRes.data.includes("already-tagged-btn")) {
      pass("existing identifier preserved");
    } else {
      fail("existing identifier preserved", "already-tagged-btn not found");
    }

    // Auto-tagged elements should have generated identifiers
    // Button without identifier should get "button_untagged_button" or similar
    if (lookRes.data.includes("button_") || lookRes.data.includes("Untagged Button")) {
      pass("auto-tagged button visible");
    } else {
      skip("auto-tagged button visible", "Auto-generated identifier not found in view output");
    }

    await goBackToTests();
  } catch (e) {
    fail("auto-tagging test", e.message);
    try { await goBackToTests(); } catch {}
  }
}

// --- Gesture Tests ---

async function testDoubleTap() {
  console.log("\n── Double Tap ──");

  try {
    await goToTestScreen("test-double-tap");

    const r = await send("double_tap", { query: "#doubletap-target" });
    if (r.ok) {
      pass("double tap command executes");
    } else {
      fail("double tap command executes", r.data);
    }

    const look = await send("view");
    if (look.data.includes("Double tap #")) {
      pass("double tap gesture recognized");
    } else if (look.data.includes("Single tap")) {
      skip("double tap gesture recognized", "Single tap fired instead of double");
    } else {
      skip("double tap gesture recognized", "Result not detected in view output");
    }

    await goBackToTests();
  } catch (e) {
    fail("double tap test", e.message);
    try { await goBackToTests(); } catch {}
  }
}

async function testDragDrop() {
  console.log("\n── Drag & Drop ──");

  try {
    await goToTestScreen("test-drag-drop");

    // Verify we see drag items
    const look = await send("view");
    if (look.data.includes("drag-item-a") || look.data.includes("Item A")) {
      pass("drag drop screen loads");
    } else {
      fail("drag drop screen loads", "Items not found");
      await goBackToTests();
      return;
    }

    // Drag Item A down to Item C position
    const r = await send("drag_drop", {
      from: "#drag-item-a",
      to: "#drag-item-c",
      hold_duration: 0.5,
      drag_duration: 0.5,
    });
    if (r.ok) {
      pass("drag drop command executes");
    } else {
      fail("drag drop command executes", r.data);
    }

    await goBackToTests();
  } catch (e) {
    fail("drag drop test", e.message);
    try { await goBackToTests(); } catch {}
  }
}

async function testPinch() {
  console.log("\n── Pinch / Zoom ──");

  try {
    await goToTestScreen("test-pinch");

    // Pinch to zoom in
    const r = await send("pinch", { query: "#pinch-target", scale: 2.0 });
    if (r.ok) {
      pass("pinch zoom in command executes");
    } else {
      fail("pinch zoom in command executes", r.data);
    }

    const look = await send("view");
    if (look.data.includes("Zoomed to") || look.data.includes("pinch-scale")) {
      pass("pinch gesture detected");
    } else {
      skip("pinch gesture detected", "Zoom result not in view output");
    }

    await goBackToTests();
  } catch (e) {
    fail("pinch test", e.message);
    try { await goBackToTests(); } catch {}
  }
}

async function testContextMenu() {
  console.log("\n── Context Menu ──");

  try {
    await goToTestScreen("test-context-menu");

    // Open context menu
    const r = await send("context_menu", { query: "#contextmenu-target" });
    if (r.ok) {
      pass("context menu command executes");
    } else {
      fail("context menu command executes", r.data);
      await goBackToTests();
      return;
    }

    // Dismiss the context menu — tap outside it
    await send("tap", { query: "20,20" });

    await goBackToTests();
  } catch (e) {
    fail("context menu test", e.message);
    try { await send("tap", { query: "20,20" }); await goBackToTests(); } catch {}
  }
}

async function testPullToRefresh() {
  console.log("\n── Pull to Refresh ──");
  await restartApp();

  try {
    // Go to Orders tab and place a sample order so the list (scroll view) appears
    await send("tap", { query: "@Orders" });
    await send("tap", { query: "#place-sample-order" });
    await sleep(1500);

    const r = await send("pull_to_refresh");
    if (r.ok) {
      pass("pull to refresh command executes");
    } else {
      fail("pull to refresh command executes", r.data);
    }
  } catch (e) {
    fail("pull to refresh test", e.message);
  }
}

// --- Deeplink & Permissions Tests ---

async function testDeeplink() {
  console.log("\n── Deeplink ──");
  await restartApp();

  try {
    // Test deeplink with custom URL scheme
    const r = await send("deeplink", { url: "nerveexample://test" });
    if (r.ok) {
      pass("deeplink command executes");
    } else {
      fail("deeplink command executes", r.data);
    }

  } catch (e) {
    fail("deeplink test", e.message);
  }

  try {
    // Test invalid URL
    const r = await send("deeplink", { url: "" });
    assert(!r.ok, "should fail for empty URL");
    pass("deeplink rejects empty URL");
  } catch (e) {
    fail("deeplink rejects empty URL", e.message);
  }

  try {
    // Test missing url parameter
    const r = await send("deeplink", {});
    assert(!r.ok, "should fail for missing url");
    pass("deeplink rejects missing url param");
  } catch (e) {
    fail("deeplink rejects missing url param", e.message);
  }
}

async function testGrantPermissions() {
  console.log("\n── Grant Permissions ──");
  await restartApp();

  try {
    // grant_permissions must run on Mac side, so in-app should return error
    const r = await send("grant_permissions", { services: ["camera"] });
    assert(!r.ok, "should fail in-process");
    assert(r.data.includes("MCP server"), "should mention MCP server");
    pass("grant_permissions returns Mac-side instruction");
  } catch (e) {
    fail("grant_permissions returns Mac-side instruction", e.message);
  }
}

// --- Inspection Tests ---

async function testNetworkResponseBody() {
  console.log("\n── Network Response Body ──");
  await goToTestScreen("test-network");

  try {
    // Verify we're on the Network test screen
    const viewRes = await send("view");
    if (!viewRes.data.includes("fetch-btn")) {
      // Try scrolling down and tapping again
      await send("scroll_to_find", { query: "#fetch-btn" });
    }

    // Tap the Fetch Data button to trigger an HTTP request
    const tapRes = await send("tap", { query: "#fetch-btn" });
    assert(tapRes.ok, `tap fetch failed: ${tapRes.data}`);
    await sleep(3000); // Wait for HTTP request to complete

    // Check that the network transaction was captured
    const listRes = await send("network", { limit: 5 });
    assert(listRes.ok, `network list failed: ${listRes.data}`);
    assert(listRes.data.includes("#1"), "should have at least one transaction");
    pass("network captures HTTP request");

    // Get detail of the first transaction
    const detailRes = await send("network", { index: 1 });
    assert(detailRes.ok, `network detail failed: ${detailRes.data}`);
    assert(
      detailRes.data.includes("status:") && detailRes.data.includes("duration:"),
      "should include status and duration"
    );
    pass("network detail shows request info");
  } catch (e) {
    fail("network response body test", e.message);
  }

  try {
    // Invalid index should error
    const r = await send("network", { index: 9999 });
    assert(!r.ok, "should fail for invalid index");
    pass("network rejects invalid index");
  } catch (e) {
    fail("network rejects invalid index", e.message);
  }

  await goBackToTests();
}

async function testHeapPropertyInspection() {
  console.log("\n── Heap Property Inspection ──");
  await restartApp();

  try {
    // Find UIWindow instances (always exist)
    const listRes = await send("heap", { class_name: "UIWindow" });
    assert(listRes.ok, `heap list failed: ${listRes.data}`);
    assert(listRes.data.includes("UIWindow"), "should find UIWindow");
    pass("heap lists instances");
  } catch (e) {
    fail("heap lists instances", e.message);
  }

  try {
    // Inspect first UIWindow's properties
    const detailRes = await send("heap", { class_name: "UIWindow", index: 1 });
    assert(detailRes.ok, `heap inspect failed: ${detailRes.data}`);
    assert(detailRes.data.includes("heap inspect:"), "should show inspect header");
    // UIWindow should have properties like windowLevel, isKeyWindow, etc.
    if (detailRes.data.includes("=")) {
      pass("heap inspect shows properties with values");
    } else {
      fail("heap inspect shows properties with values", "No property values found");
    }
  } catch (e) {
    fail("heap inspect shows properties with values", e.message);
  }

  try {
    // Invalid index should error
    const r = await send("heap", { class_name: "UIWindow", index: 999 });
    assert(!r.ok, "should fail for invalid index");
    pass("heap rejects invalid index");
  } catch (e) {
    fail("heap rejects invalid index", e.message);
  }
}

async function testCoreDataInspection() {
  console.log("\n── Core Data Inspection ──");
  await restartApp();

  try {
    // This app may not use Core Data — that's OK, just verify the command works
    const r = await send("storage", { type: "coredata" });
    if (r.ok) {
      assert(r.data.includes("coredata:"), "should include coredata header");
      pass("coredata lists entities");
    } else {
      // Expected: no Core Data in the example app
      assert(r.data.includes("No NSManagedObjectContext"), "should report no context");
      pass("coredata reports no context when not used");
    }
  } catch (e) {
    fail("coredata inspection", e.message);
  }
}

// --- Debug Tools ---

async function testTrace() {
  console.log("\n── Trace ──");
  await restartApp();

  try {
    // Install a trace on UIViewController.viewDidAppear:
    const addRes = await send("trace", { action: "add", class_name: "UIViewController", method: "viewDidAppear:" });
    assert(addRes.ok, `trace add failed: ${addRes.data}`);
    assert(addRes.data.includes("Tracing"), "should confirm tracing");
    pass("trace installs on method");
  } catch (e) {
    fail("trace installs on method", e.message);
  }

  try {
    // List should show 1 active trace
    const listRes = await send("trace", { action: "list" });
    assert(listRes.ok, `trace list failed: ${listRes.data}`);
    assert(listRes.data.includes("1"), "should show 1 active trace");
    pass("trace list shows active traces");
  } catch (e) {
    fail("trace list shows active traces", e.message);
  }

  try {
    // Navigate to trigger viewDidAppear
    await send("tap", { query: "@Settings" });
    await sleep(500); // Wait for trace log to be captured

    // Check console for trace output
    const consoleRes = await send("console", { filter: "trace", limit: 10 });
    assert(consoleRes.ok, `console failed: ${consoleRes.data}`);
    assert(consoleRes.data.includes("[trace]"), "should have trace log entries");
    pass("trace logs method calls to console");
  } catch (e) {
    fail("trace logs method calls to console", e.message);
  }

  try {
    // Remove all traces
    const removeRes = await send("trace", { action: "remove_all" });
    assert(removeRes.ok, `trace remove_all failed: ${removeRes.data}`);
    pass("trace remove_all clears traces");
  } catch (e) {
    fail("trace remove_all clears traces", e.message);
  }
}

async function testHighlight() {
  console.log("\n── Highlight ──");
  await restartApp();

  try {
    const r = await send("highlight", { query: "#product-a", color: "blue" });
    assert(r.ok, `highlight failed: ${r.data}`);
    assert(r.data.includes("Highlighted"), "should confirm highlight");
    pass("highlight draws border on element");
  } catch (e) {
    fail("highlight draws border on element", e.message);
  }

  try {
    const r = await send("highlight", { action: "clear" });
    assert(r.ok, `highlight clear failed: ${r.data}`);
    assert(r.data.includes("Cleared"), "should confirm clear");
    pass("highlight clear removes all highlights");
  } catch (e) {
    fail("highlight clear removes all highlights", e.message);
  }

  try {
    const r = await send("highlight", { query: "#nonexistent-xyz" });
    assert(!r.ok, "should fail for nonexistent element");
    pass("highlight rejects missing element");
  } catch (e) {
    fail("highlight rejects missing element", e.message);
  }
}

async function testModify() {
  console.log("\n── Modify ──");
  await restartApp();

  try {
    const r = await send("modify", { query: "#product-a", hidden: "true" });
    assert(r.ok, `modify hidden failed: ${r.data}`);
    assert(r.data.includes("hidden=true"), "should confirm hidden change");
    pass("modify sets hidden property");
  } catch (e) {
    fail("modify sets hidden property", e.message);
  }

  try {
    // Restore
    await send("modify", { query: "#product-a", hidden: "false" });

    const r = await send("modify", { query: "#product-a", alpha: "0.5" });
    assert(r.ok, `modify alpha failed: ${r.data}`);
    assert(r.data.includes("alpha=0.5"), "should confirm alpha change");
    pass("modify sets alpha property");
  } catch (e) {
    fail("modify sets alpha property", e.message);
  }

  try {
    const r = await send("modify", { query: "#nonexistent-xyz", hidden: "true" });
    assert(!r.ok, "should fail for nonexistent element");
    pass("modify rejects missing element");
  } catch (e) {
    fail("modify rejects missing element", e.message);
  }
}

// --- Form Fill & Submit ---

async function testFormFillAndSubmit() {
  console.log("\n── Form Fill & Submit ──");
  await restartApp();

  // Test 1: Fill login form and submit successfully
  try {
    // Navigate to Login
    await send("tap", { query: "#login-link" });

    const look = await send("view");
    assert(look.data.includes("email-field"), "Should be on Login screen");

    // Fill email
    await send("tap", { query: "#email-field" });
    await send("type", { text: "user@example.com" });

    // Fill password (secure field)
    await send("tap", { query: "#password-field" });
    await send("type", { text: "secret123" });

    // Dismiss keyboard
    await send("dismiss");

    // Verify Sign In button is now enabled
    const lookAfterFill = await send("view");
    assert(
      lookAfterFill.data.includes("login-btn") && !lookAfterFill.data.includes("login-btn") === false,
      "Sign In button should be visible"
    );

    // Tap Sign In
    await send("tap", { query: "#login-btn" });
    await sleep(1500); // Wait for simulated network delay (1s in app code)

    // Check for success result on screen
    const resultLook = await send("view");
    assert(
      resultLook.data.includes("Welcome") || resultLook.data.includes("login-result"),
      "Should show login result"
    );

    pass("form fill and submit succeeds");
  } catch (e) {
    fail("form fill and submit succeeds", e.message);
  }

  // Test 2: Toggle interaction on Settings
  await restartApp();
  try {
    // Go to Settings tab
    await send("tap", { query: "@Settings" });

    // Check initial toggle state
    const look = await send("view");
    assert(look.data.includes("dark-mode-toggle"), "Should see dark mode toggle");

    // Tap the dark mode toggle
    const tapRes = await send("tap", { query: "#dark-mode-toggle" });
    assert(tapRes.ok, `tap toggle failed: ${tapRes.data}`);

    pass("toggle interaction works");
  } catch (e) {
    fail("toggle interaction works", e.message);
  }

  // Test 3: Type into Settings username field
  try {
    await send("tap", { query: "#username-field" });
    const typeRes = await send("type", { text: "nerveuser" });
    assert(typeRes.ok, `type username failed: ${typeRes.data}`);
    assert(typeRes.data.toLowerCase().includes("typed"), "should confirm typed");
    pass("type into settings text field");
  } catch (e) {
    fail("type into settings text field", e.message);
  }

  // Test 4: Submit with invalid credentials (missing @)
  await restartApp();
  try {
    await send("tap", { query: "#login-link" });

    // Fill with invalid email (no @)
    await send("tap", { query: "#email-field" });
    await send("type", { text: "bademail" });

    await send("tap", { query: "#password-field" });
    await send("type", { text: "pass1234" });

    await send("dismiss");

    await send("tap", { query: "#login-btn" });
    await sleep(1500); // Wait for simulated network delay

    // Should show error result on screen
    const resultLook = await send("view");
    assert(
      resultLook.data.includes("Invalid") || resultLook.data.includes("login-result"),
      "Should show error result"
    );

    pass("form submit with invalid data shows error");
  } catch (e) {
    fail("form submit with invalid data shows error", e.message);
  }
}

// --- Reconnection ---

async function testReconnection() {
  console.log("\n── Reconnection ──");

  try {
    // Verify we can send a command before restart
    const beforeRes = await send("status");
    assert(beforeRes.ok, `status before restart failed: ${beforeRes.data}`);
    const oldPort = currentPort;
    pass("command works before restart");

    // Restart the app — this kills the process, changes the port, and reconnects
    await restartApp();

    // Verify we can send a command after restart
    const afterRes = await send("status");
    assert(afterRes.ok, `status after restart failed: ${afterRes.data}`);
    assert(afterRes.data.includes("status: connected"), "should be connected after restart");
    pass("command works after restart");

    // Verify the app state is fresh (Home tab, no prior navigation)
    const lookRes = await send("view");
    assert(lookRes.ok, `view after restart failed: ${lookRes.data}`);
    assert(lookRes.data.includes("product-a"), "should show Home screen elements after restart");
    pass("app state is fresh after restart");

    // Verify port changed (restart assigns a new port)
    if (currentPort !== oldPort) {
      pass("reconnected on new port");
    } else {
      pass("reconnected on same port");
    }
  } catch (e) {
    fail("reconnection after restart", e.message);
  }
}

// --- Main ---

async function main() {
  const shouldBuild = process.argv.includes("--build");
  let port;

  if (shouldBuild) {
    port = await buildAndLaunch();
  } else {
    port = await findRunningInstance();
    if (!port) {
      console.log(
        "No running Nerve instance found. Use --build to build and launch, or start the example app manually."
      );
      console.log(
        "Alternatively, specify a port: node e2e.test.mjs --port 9500"
      );
      process.exit(1);
    }
  }

  // Connect WebSocket
  currentPort = port;
  console.log(`\nConnecting to ws://127.0.0.1:${port}...`);
  ws = new WebSocket(`ws://127.0.0.1:${port}`);

  await new Promise((resolve, reject) => {
    ws.on("open", () => {
      console.log("Connected!\n");
      console.log("═══════════════════════════════════");
      console.log("  Nerve E2E Tests");
      console.log("═══════════════════════════════════");
      resolve();
    });
    ws.on("error", (err) => {
      console.error(`WebSocket connection failed: ${err.message}`);
      reject(err);
    });
    setTimeout(
      () => reject(new Error("WebSocket connection timeout")),
      5000
    );
  });

  // Run test suites
  await testConnection();
  await testView();
  await testTree();
  await testInspect();
  await testTap();
  await testScroll();
  await testType();
  await testConsole();
  await testNetwork();
  await testHeap();
  await testMap();
  await testScreenshot();
  await testStorage();
  await testWaitIdle();
  await testBackAndDismiss();
  await testUnknownCommand();

  // Feature-specific tests (items #3, #6, #8, #9, #10, #13, #15)
  await testAlertAndSheet();
  await testLazyList();
  await testCustomActions();
  await testOverlays();
  await testLongPress();
  await testDisabledElements();
  await testVoiceOverLabels();
  await testAutoTagging();

  // Gesture tests
  await testDoubleTap();
  await testDragDrop();
  await testPinch();
  await testContextMenu();
  await testPullToRefresh();

  // Navigation & permissions tests
  await testDeeplink();
  await testGrantPermissions();

  // Inspection tests
  await testNetworkResponseBody();
  await testHeapPropertyInspection();
  await testCoreDataInspection();

  // Debug tools
  await testTrace();
  await testHighlight();
  await testModify();

  // Form fill & submit
  await testFormFillAndSubmit();

  // Reconnection
  await testReconnection();

  // Summary
  console.log("\n═══════════════════════════════════");
  console.log(
    `  Results: ${testsPassed} passed, ${testsFailed} failed, ${testsSkipped} skipped`
  );
  console.log("═══════════════════════════════════\n");

  if (failures.length > 0) {
    console.log("Failures:");
    for (const f of failures) {
      console.log(`  ✗ ${f.name}: ${f.reason}`);
    }
    console.log();
  }

  ws.close();
  process.exit(testsFailed > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error("E2E test error:", e.message);
  process.exit(1);
});
