#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import WebSocket from "ws";
import { execSync, spawn } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as net from "net";

// --- Types ---

interface NerveTarget {
  id: string;
  platform: "simulator" | "device";
  bundleId: string;
  appName: string;
  port: number;
  host: string;
  udid?: string;
  pid?: number;
}

interface NerveResponse {
  id: string;
  ok: boolean;
  data: string;
}

// --- Discovery ---

function discoverSimulatorTargets(): NerveTarget[] {
  const dir = "/tmp/nerve-ports";
  if (!fs.existsSync(dir)) return [];

  const targets: NerveTarget[] = [];
  for (const file of fs.readdirSync(dir)) {
    if (!file.endsWith(".json")) continue;
    try {
      const info = JSON.parse(fs.readFileSync(path.join(dir, file), "utf-8"));

      // Check if process is still alive
      try {
        process.kill(info.pid, 0);
      } catch {
        // Process is dead, clean up stale file
        fs.unlinkSync(path.join(dir, file));
        continue;
      }

      targets.push({
        id: `sim:${info.udid}:${info.bundleId}`,
        platform: "simulator",
        bundleId: info.bundleId,
        appName: info.appName,
        port: info.port,
        host: "127.0.0.1",
        udid: info.udid,
        pid: info.pid,
      });
    } catch {
      // Skip malformed files
    }
  }
  return targets;
}

function discoverBonjourTargets(): NerveTarget[] {
  // Use dns-sd to browse for _nerve._tcp services (non-blocking check)
  try {
    // Quick one-shot browse with timeout
    const result = execSync(
      'dns-sd -B _nerve._tcp . 2>/dev/null & PID=$!; sleep 1; kill $PID 2>/dev/null; wait $PID 2>/dev/null',
      { timeout: 3000, encoding: "utf-8" }
    );

    const targets: NerveTarget[] = [];
    for (const line of result.split("\n")) {
      const match = line.match(/Nerve-(\S+)/);
      if (match) {
        // Resolve would need another dns-sd call. For MVP, skip and rely on
        // manual connection or iproxy.
      }
    }
    return targets;
  } catch {
    return [];
  }
}

// --- Connect-Per-Command WebSocket ---

function getAliveTargets(): NerveTarget[] {
  return [...discoverSimulatorTargets(), ...discoverBonjourTargets()];
}

function resolveTarget(targetId?: string): NerveTarget {
  if (targetId) {
    const parts = targetId.split(":");
    if (parts.length >= 3 && parts[0] === "sim") {
      const udid = parts[1];
      const bundleId = parts.slice(2).join(":");
      const portFile = path.join("/tmp/nerve-ports", `${udid}-${bundleId}.json`);

      if (!fs.existsSync(portFile)) {
        throw new Error(`Target not found: no port file for ${targetId}`);
      }

      const info = JSON.parse(fs.readFileSync(portFile, "utf-8"));
      try { process.kill(info.pid, 0); } catch {
        fs.unlinkSync(portFile);
        throw new Error(`Target ${targetId} is not running (process dead)`);
      }

      return {
        id: targetId, platform: "simulator",
        bundleId: info.bundleId, appName: info.appName,
        port: info.port, host: "127.0.0.1", udid: info.udid, pid: info.pid,
      };
    }
    throw new Error(`Unknown target format: ${targetId}`);
  }

  const all = getAliveTargets();
  if (all.length === 0) {
    throw new Error("No Nerve instance found. Make sure your iOS app is running with Nerve.start() or launched via nerve_run.");
  }
  if (all.length > 1) {
    const list = all.map(t => `  ${t.id} — ${t.appName} (${t.platform})`).join("\n");
    throw new Error(`Multiple targets found. Specify 'target' parameter:\n${list}`);
  }
  return all[0];
}

let requestCounter = 0;

async function send(
  command: string,
  params: Record<string, unknown> = {},
  targetId?: string,
  timeoutMs = 30000,
): Promise<string> {
  const target = resolveTarget(targetId);
  const url = `ws://${target.host}:${target.port}`;
  const id = `req_${++requestCounter}`;
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) { settled = true; ws.terminate(); reject(new Error(`Command '${command}' timed out after ${timeoutMs / 1000}s`)); }
    }, timeoutMs);

    ws.on("open", () => {
      ws.send(JSON.stringify({ id, command, params }));
    });

    ws.on("message", (data: WebSocket.Data) => {
      try {
        const response: NerveResponse = JSON.parse(data.toString());
        if (response.id === id && !settled) {
          settled = true;
          clearTimeout(timer);
          ws.close();
          if (response.ok) resolve(response.data);
          else reject(new Error(response.data));
        }
      } catch { /* ignore malformed */ }
    });

    ws.on("error", (err) => {
      if (!settled) { settled = true; clearTimeout(timer); reject(new Error(`Connection error: ${err.message}`)); }
    });

    ws.on("close", () => {
      if (!settled) { settled = true; clearTimeout(timer); reject(new Error("Connection closed before response")); }
    });
  });
}

function tcpProbe(host: string, port: number, timeoutMs: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    socket.setTimeout(timeoutMs);
    socket.on("connect", () => { socket.destroy(); resolve(true); });
    socket.on("error", () => { socket.destroy(); resolve(false); });
    socket.on("timeout", () => { socket.destroy(); resolve(false); });
    socket.connect(port, host);
  });
}

// --- MCP Server ---

const server = new Server(
  { name: "nerve", version: "0.1.0" },
  {
    capabilities: { tools: {} },
    instructions: `Nerve is an in-process iOS automation framework. It lets you see, interact with, and inspect a running iOS app from within the app's process.

## Autonomous Verification Loop

When developing features or fixing bugs, use this closed loop to verify your changes without human intervention:

1. **Write code** — implement the feature or fix. Add \`print("[nerve] ...")\` trace logs at key points (e.g., \`print("[nerve] item added: \\(item.name)")\`).
2. **Build & launch** — call nerve_run to build and launch the app on the simulator.
3. **Navigate** — use nerve_view to see the screen, then nerve_tap to navigate to the relevant screen.
4. **Perform the action** — tap buttons, fill fields, trigger the feature you're testing.
5. **Read results** — call nerve_console with filter="[nerve]" and since="last_action" to read your trace logs. Call nerve_view to see the screen state.
6. **Iterate** — if the output is wrong, fix the code and go back to step 2. Repeat until correct.

This replaces the manual cycle of: edit code → build in Xcode → manually tap through the app → copy logs → paste back.

## How to navigate and interact

### See the screen
Call nerve_view to see all visible elements with their type (btn, txt, field, toggle), label, identifier (#id), tap point, and position. Always call this before interacting.

Each element has a ref like @e1, @e2 — use these directly: nerve_tap "@e2".
Elements with identifiers can also be tapped by #id: nerve_tap "#login-btn".
The tap= coordinate is the center point where the element is reliably hittable.

### Navigate
- nerve_tap to tap tabs, buttons, links, and rows to move between screens.
- nerve_back to go back, nerve_dismiss to close modals/keyboard.
- nerve_map to see all discovered screens. nerve_navigate to auto-navigate to a known screen.
- nerve_deeplink to open a URL scheme directly.
- Interaction commands (tap, scroll, type, swipe, back, dismiss) automatically return the updated screen state — no need to call nerve_view after them.

### Interact
- nerve_tap to press buttons and select items. Use @eN refs or #id.
- nerve_type to enter text (tap the field first to focus it).
- nerve_scroll or nerve_scroll_to_find for off-screen content.
- **No sleep needed between commands.** Every interaction command automatically waits for the UI to settle (animations complete, transitions finish) before returning. Just send commands back-to-back.

### Wait for async work
- nerve_wait_idle to wait for network requests + animations to finish.
- nerve_network to check specific requests.
- Note: auto-wait after actions only covers UI settling (animations, transitions). For network completion, use nerve_wait_idle or nerve_network explicitly.

### Verify
- nerve_view to see updated screen state — this is your PRIMARY inspection tool. It returns structured element data with refs, identifiers, and tap coordinates you can act on directly.
- nerve_console with filter="[nerve]" and since="last_action" for your trace logs.
- nerve_screenshot ONLY when you need to verify visual layout, colors, or spatial relationships that text can't convey. Do NOT use screenshot as a substitute for nerve_view.
- nerve_heap to inspect live objects (e.g., check ViewModel state).

### Tips
- Always call nerve_view before interacting — don't guess element identifiers.
- Use @eN refs from nerve_view output to tap elements without identifiers.
- nerve_view is lightweight (~1 line per element) and gives you everything needed to interact. Prefer it over nerve_screenshot for all inspection tasks.
- If an element isn't visible, try nerve_scroll_to_find before giving up.
- The navigation map builds automatically and persists across sessions.
- Do NOT add sleep/delay between commands — Nerve handles waiting automatically.
- Call nerve_grant_permissions before features that need camera, photos, location, etc.`,
  }
);

// Tool definitions
const TOOLS = [
  {
    name: "nerve_view",
    description:
      "See the current screen. Returns all visible UI elements with their type (btn, txt, field, toggle), label, identifier (#id), and position. This is your primary tool for understanding what's on screen. Always call this before interacting with elements.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string", description: "Target ID. Auto-selects if only one connected." },
      },
    },
  },
  {
    name: "nerve_tree",
    description: "Dump the complete view hierarchy tree showing all views with nesting, types, and frames.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        depth: { type: "number", description: "Max depth. Default: unlimited." },
      },
    },
  },
  {
    name: "nerve_inspect",
    description:
      "Inspect a specific UI element. Returns properties, accessibility info, constraints, and type information. Query by #identifier, @label, .Type, or x,y coordinates.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        query: { type: "string", description: "Element query: #id, @label, .Type:index, or x,y" },
      },
      required: ["query"],
    },
  },
  {
    name: "nerve_tap",
    description: "Tap a UI element. Response includes the updated screen state (auto-view), so you do NOT need to call nerve_view after tapping. Use #identifier, @label, or x,y coordinates.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        query: { type: "string", description: "Element to tap: #id, @label, .Type, or x,y" },
      },
      required: ["query"],
    },
  },
  {
    name: "nerve_scroll",
    description: "Scroll the current scroll view in a direction.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        direction: { type: "string", enum: ["up", "down", "left", "right"] },
        amount: { type: "number", description: "Scroll distance in points. Default: 300." },
      },
      required: ["direction"],
    },
  },
  {
    name: "nerve_swipe",
    description: "Perform a swipe gesture in a direction.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        direction: { type: "string", enum: ["up", "down", "left", "right"] },
        from: { type: "string", description: "Starting point as 'x,y'. Default: screen center." },
      },
      required: ["direction"],
    },
  },
  {
    name: "nerve_double_tap",
    description: "Double-tap a UI element. Used for zoom in/out on maps, text selection.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        query: { type: "string", description: "Element to double-tap: #id, @label, .Type, or x,y" },
      },
      required: ["query"],
    },
  },
  {
    name: "nerve_drag_drop",
    description: "Drag and drop: long-press the source element, drag to the target, release.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        from: { type: "string", description: "Source element: #id, @label, or x,y" },
        to: { type: "string", description: "Destination element: #id, @label, or x,y" },
        hold_duration: { type: "number", description: "Hold time before dragging (seconds). Default: 0.5." },
        drag_duration: { type: "number", description: "Drag animation time (seconds). Default: 0.5." },
      },
      required: ["from", "to"],
    },
  },
  {
    name: "nerve_pull_to_refresh",
    description: "Pull down to refresh the current scroll view content.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
      },
    },
  },
  {
    name: "nerve_pinch",
    description: "Two-finger pinch/zoom gesture. Scale > 1.0 zooms in, < 1.0 zooms out.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        query: { type: "string", description: "Element to pinch on: #id, @label, or x,y. Default: screen center." },
        scale: { type: "number", description: "Zoom scale factor. Default: 2.0 (zoom in). Use 0.5 for zoom out." },
      },
    },
  },
  {
    name: "nerve_context_menu",
    description: "Open a context menu by long-pressing an element. Returns the current screen showing menu items. Use nerve_tap to select a menu item.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        query: { type: "string", description: "Element to long-press for context menu: #id, @label, or x,y" },
      },
      required: ["query"],
    },
  },
  {
    name: "nerve_long_press",
    description: "Long-press a UI element. Triggers context menus, drag initiation, and haptic touch actions.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        query: { type: "string", description: "Element to long-press: #id, @label, .Type, or x,y" },
        duration: { type: "number", description: "Press duration in seconds. Default: 1.0." },
      },
      required: ["query"],
    },
  },
  {
    name: "nerve_type",
    description: "Type text into the currently focused text field. Tap the field first with nerve_tap to focus it, then call this to enter text.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        text: { type: "string", description: "Text to type." },
        submit: { type: "boolean", description: "Press Return after typing. Default: false." },
      },
      required: ["text"],
    },
  },
  {
    name: "nerve_back",
    description: "Navigate back (pop navigation or dismiss presented view controller).",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
      },
    },
  },
  {
    name: "nerve_dismiss",
    description: "Dismiss the keyboard or the frontmost presented view controller.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
      },
    },
  },
  {
    name: "nerve_screenshot",
    description: "Capture a screenshot of the current screen. Returns base64-encoded PNG. Prefer nerve_view for understanding screen state and finding elements — it returns structured data with element refs and tap coordinates. Only use screenshot for visual layout verification when text output isn't enough.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        scale: { type: "number", description: "Image scale. Default: 1.0." },
        maxDimension: { type: "number", description: "Resize so longest side fits within this value (in points). Normalizes across device sizes. Example: 800. Overrides scale when set." },
      },
    },
  },
  {
    name: "nerve_console",
    description:
      "Read the app's console log output. Use filter to narrow results (e.g., filter='[nerve]' for your trace logs, filter='error' for errors). Use since='last_action' to see only logs from the most recent interaction.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        limit: { type: "number", description: "Max log lines. Default: 50." },
        filter: { type: "string", description: "Keyword filter (e.g., '[nerve]' to see only your trace logs)." },
        level: { type: "string", enum: ["debug", "info", "warning", "error"] },
        since: { type: "string", enum: ["last_action"], description: "Only show logs since the last tap/scroll/type/swipe action." },
      },
    },
  },
  {
    name: "nerve_network",
    description: "Show recent HTTP requests with method, URL, status, and timing. In-flight requests show as 'pending'. Use index to see full response body and headers for a specific request — e.g., check what the API returned after a login call.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        limit: { type: "number", description: "Max transactions. Default: 20." },
        filter: { type: "string", description: "URL pattern filter." },
        index: { type: "number", description: "Transaction number (from the list) to see full response body and headers." },
      },
    },
  },
  {
    name: "nerve_heap",
    description: "Find live instances of a class on the heap and inspect their properties. First call with just class_name to list instances. Then call with index to read all properties of a specific instance (e.g., check a ViewModel's state).",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        class_name: { type: "string", description: "Class name (e.g., 'UserViewModel', 'UINavigationController')." },
        limit: { type: "number", description: "Max instances. Default: 20." },
        index: { type: "number", description: "Instance number (1-based) to inspect all properties." },
      },
      required: ["class_name"],
    },
  },
  {
    name: "nerve_storage",
    description: "Read app storage: UserDefaults, Keychain, cookies, sandbox files, or Core Data. For Core Data, omit entity to list all entities, or specify entity to fetch records.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        type: { type: "string", enum: ["defaults", "keychain", "cookies", "files", "coredata"] },
        key: { type: "string", description: "Specific key (for defaults)." },
        path: { type: "string", description: "Directory path (for files)." },
        entity: { type: "string", description: "Core Data entity name. Omit to list all entities." },
        predicate: { type: "string", description: "NSPredicate to filter Core Data records (e.g., \"name CONTAINS 'milk'\")." },
        limit: { type: "number", description: "Max records for Core Data. Default: 20." },
      },
      required: ["type"],
    },
  },
  {
    name: "nerve_status",
    description: "Check connection status, app state, and Nerve version for all connected targets.",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
  {
    name: "nerve_map",
    description:
      "Show the app's navigation map — all discovered screens and how to get between them. The map builds automatically as you navigate and persists across sessions. Use this to plan how to reach a specific screen. Use format='json' to export.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        format: { type: "string", enum: ["text", "json"], description: "Output format. Default: text." },
        import: { type: "string", description: "JSON string to import a previously exported map." },
      },
    },
  },
  {
    name: "nerve_navigate",
    description:
      "Auto-navigate to a screen by name (e.g., 'Settings', 'Orders'). Uses the navigation map to find the shortest path and executes each step automatically. Call nerve_map first to see available screens. If the screen isn't in the map yet, navigate there manually with nerve_tap to discover it.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        target_screen: { type: "string", description: "Screen name to navigate to (e.g., 'SettingsViewController', 'CheckoutScreen')." },
        inputs: {
          type: "object",
          description: "Map of field identifiers to values for screens requiring input (e.g., {\"#email-field\": \"test@example.com\", \"#password-field\": \"pass123\"}).",
          additionalProperties: { type: "string" },
        },
      },
      required: ["target_screen"],
    },
  },
  {
    name: "nerve_action",
    description: "Invoke a custom accessibility action on an element. Use nerve_inspect to discover available actions first.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        query: { type: "string", description: "Element query: #id, @label, .Type, or x,y" },
        action: { type: "string", description: "Name of the custom accessibility action to invoke." },
      },
      required: ["query", "action"],
    },
  },
  {
    name: "nerve_scroll_to_find",
    description: "Find an element that's off-screen by scrolling through the list. Use this when nerve_view doesn't show the element you need — it may be below the fold in a scrollable list.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        query: { type: "string", description: "Element to find: #id, @label" },
        max_attempts: { type: "number", description: "Max scroll pages to try. Default: 10." },
      },
      required: ["query"],
    },
  },
  {
    name: "nerve_wait_idle",
    description:
      "Wait until ALL network requests complete and animations finish. Simple but may wait too long if the app has background polling. For precise control, use nerve_network instead to check if a specific request completed.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        timeout: { type: "number", description: "Max wait time in seconds. Default: 5." },
        quiet: { type: "number", description: "Seconds of no activity before considered idle. Default: 1." },
      },
    },
  },
  {
    name: "nerve_build",
    description: "Build an iOS app for the simulator using xcodebuild.",
    inputSchema: {
      type: "object" as const,
      properties: {
        scheme: { type: "string", description: "Xcode scheme to build." },
        workspace: { type: "string", description: "Path to .xcworkspace (optional)." },
        project: { type: "string", description: "Path to .xcodeproj (optional)." },
        simulator: { type: "string", description: "Simulator name. Default: iPhone 16 Pro." },
      },
      required: ["scheme"],
    },
  },
  {
    name: "nerve_run",
    description:
      "Build, install, and launch an iOS app on the simulator. The app must include the Nerve SPM package. After launching, call nerve_view to see the initial screen, then navigate and interact as needed.",
    inputSchema: {
      type: "object" as const,
      properties: {
        scheme: { type: "string", description: "Xcode scheme to build." },
        workspace: { type: "string", description: "Path to .xcworkspace (optional)." },
        project: { type: "string", description: "Path to .xcodeproj (optional)." },
        simulator: { type: "string", description: "Simulator name. Default: iPhone 16 Pro." },
      },
      required: ["scheme"],
    },
  },
  {
    name: "nerve_deeplink",
    description:
      "Open a deeplink URL in the app to navigate directly to a screen. Works with custom URL schemes (e.g., 'myapp://settings') and universal links.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        url: { type: "string", description: "The deeplink URL to open (e.g., 'myapp://settings/profile')." },
        method: { type: "string", enum: ["in_app", "simctl"], description: "How to open: 'in_app' uses UIApplication.open (default), 'simctl' uses xcrun simctl openurl." },
      },
      required: ["url"],
    },
  },
  {
    name: "nerve_grant_permissions",
    description:
      "Pre-grant iOS permissions so system dialogs never appear during automation. Call before interacting with features that require permissions (camera, location, photos, etc.).",
    inputSchema: {
      type: "object" as const,
      properties: {
        services: {
          type: "array",
          items: { type: "string" },
          description: "Permissions to grant: 'all', 'camera', 'photos', 'location', 'location-always', 'contacts', 'microphone', 'calendar', 'reminders', 'motion', 'tracking', 'speech-recognition'.",
        },
      },
      required: ["services"],
    },
  },
  {
    name: "nerve_list_simulators",
    description: "List available iOS simulators and their state (Booted/Shutdown).",
    inputSchema: {
      type: "object" as const,
      properties: {
        booted_only: { type: "boolean", description: "Only show booted simulators. Default: false." },
      },
      required: [],
    },
  },
  {
    name: "nerve_boot_simulator",
    description: "Boot a simulator by name or UDID. Opens the Simulator app if not already open.",
    inputSchema: {
      type: "object" as const,
      properties: {
        simulator: { type: "string", description: "Simulator name (e.g., 'iPhone 16 Pro') or UDID." },
      },
      required: ["simulator"],
    },
  },
  {
    name: "nerve_trace",
    description:
      "Trace method calls at runtime via swizzling. Logs every invocation to the console (read with nerve_console). Zero overhead compared to LLDB breakpoints. Use this to understand code flow without rebuilding.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        action: { type: "string", enum: ["add", "remove", "remove_all", "list"], description: "Action to perform. Default: add." },
        class_name: { type: "string", description: "ObjC class name (e.g., 'UIViewController', 'LoginViewController')." },
        method: { type: "string", description: "Selector name (e.g., 'viewDidAppear:', 'loginWithEmail:password:')." },
        type: { type: "string", enum: ["instance", "class"], description: "Instance method (-) or class method (+). Default: instance." },
      },
      required: [],
    },
  },
  {
    name: "nerve_highlight",
    description:
      "Draw a colored border around a UI element for visual debugging. Use with nerve_screenshot to see the result. Call with action='clear' to remove all highlights.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        query: { type: "string", description: "Element query (#id, @label, or coordinates)." },
        color: { type: "string", description: "Border color: red, blue, green, yellow, orange, purple, pink, cyan. Default: red." },
        action: { type: "string", enum: ["show", "clear"], description: "Show highlight or clear all. Default: show." },
      },
      required: [],
    },
  },
  {
    name: "nerve_modify",
    description:
      "Modify a UI element's properties at runtime without rebuilding. Test UI fixes instantly — change text, visibility, colors, or any KVC property.",
    inputSchema: {
      type: "object" as const,
      properties: {
        target: { type: "string" },
        query: { type: "string", description: "Element query (#id, @label, or coordinates)." },
        hidden: { type: "string", description: "Set hidden state ('true' or 'false')." },
        alpha: { type: "string", description: "Set opacity (0.0 to 1.0)." },
        backgroundColor: { type: "string", description: "Set background color (red, blue, green, yellow, etc.)." },
        text: { type: "string", description: "Set text content (works on labels, text fields, buttons)." },
        enabled: { type: "string", description: "Set enabled state ('true' or 'false')." },
        key: { type: "string", description: "KVC key for arbitrary property." },
        value: { type: "string", description: "Value to set for the KVC key." },
      },
      required: ["query"],
    },
  },
  {
    name: "nerve_lldb",
    description:
      "Execute an LLDB debugger command against the running app. The debugger session persists across calls. Use this for deep debugging: inspect variables, set breakpoints, evaluate expressions, view backtraces, and modify state at runtime.\n\nCommon commands:\n  po <expr>                — Print object description\n  expr <code>              — Evaluate expression (e.g., expr self.title = @\"new\")\n  bt                       — Show backtrace\n  frame variable           — Show local variables\n  breakpoint set -n <method> --auto-continue -C 'po self'  — Log when method is called\n  breakpoint set -f File.swift -l 42  — Break at line\n  breakpoint list          — List breakpoints\n  breakpoint delete <id>   — Remove breakpoint\n  continue                 — Resume execution (after hitting breakpoint)\n  thread list              — Show all threads\n  image lookup -n <symbol> — Find where a symbol is defined\n\nNote: When a real breakpoint is hit, the app freezes (including Nerve). Use --auto-continue for non-blocking logpoints. Use 'continue' to resume after a real breakpoint.",
    inputSchema: {
      type: "object" as const,
      properties: {
        command: { type: "string", description: "LLDB command to execute (e.g., 'po [UIApplication sharedApplication]')" },
        detach: { type: "boolean", description: "Detach the debugger and end the session." },
      },
      required: [],
    },
  },
];

// --- LLDB Session (Mac-side) ---

class LLDBSession {
  private process: ReturnType<typeof spawn> | null = null;
  private pid: number | null = null;
  private output = "";
  private ready = false;
  private static SENTINEL = "__NERVE_LLDB_DONE__";

  isAttached(): boolean {
    return this.process !== null && this.ready;
  }

  async attach(pid: number): Promise<string> {
    if (this.process && this.pid === pid) {
      return "Already attached.";
    }

    if (this.process) {
      this.detach();
    }

    this.pid = pid;

    return new Promise((resolve, reject) => {
      this.process = spawn("lldb", ["-p", String(pid)], {
        stdio: ["pipe", "pipe", "pipe"],
      });

      const timeout = setTimeout(() => {
        reject(new Error("LLDB attach timed out after 15s"));
      }, 15000);

      const onData = (data: Buffer) => {
        this.output += data.toString();
        if (this.output.includes("(lldb)")) {
          clearTimeout(timeout);
          this.ready = true;
          resolve(`Attached to PID ${pid}`);
        }
      };

      this.process.stdout!.on("data", onData);
      this.process.stderr!.on("data", onData);

      this.process.on("close", () => {
        this.process = null;
        this.ready = false;
        this.pid = null;
      });

      this.process.on("error", (err) => {
        clearTimeout(timeout);
        this.process = null;
        this.ready = false;
        reject(err);
      });
    });
  }

  async execute(command: string): Promise<string> {
    if (!this.process || !this.ready) {
      throw new Error("LLDB not attached.");
    }

    // Reset output buffer
    this.output = "";

    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        // On timeout, return whatever we have — app may be paused at breakpoint
        const result = this.extractOutput();
        resolve(result || "(no output — app may be paused at a breakpoint. Use 'continue' to resume)");
      }, 15000);

      const check = setInterval(() => {
        if (this.output.includes(LLDBSession.SENTINEL)) {
          clearTimeout(timeout);
          clearInterval(check);
          resolve(this.extractOutput());
        }
      }, 50);

      // Send the actual command, then a sentinel so we know when output is complete
      this.process!.stdin!.write(command + "\n");
      this.process!.stdin!.write(`script print("${LLDBSession.SENTINEL}")\n`);
    });
  }

  private extractOutput(): string {
    const lines = this.output.split("\n");
    return lines
      .filter(l =>
        !l.includes(LLDBSession.SENTINEL) &&
        !l.includes("script print") &&
        !l.trimStart().startsWith("(lldb)") &&
        !l.includes("stop reason = signal SIGSTOP") &&
        !l.includes("Executable binary set to") &&
        !l.includes("Architecture set to:")
      )
      .join("\n")
      .trim();
  }

  detach() {
    if (this.process) {
      try {
        this.process.stdin!.write("detach\n");
        this.process.stdin!.write("quit\n");
      } catch {}
      setTimeout(() => {
        try { this.process?.kill(); } catch {}
      }, 1000);
      this.process = null;
    }
    this.ready = false;
    this.pid = null;
    this.output = "";
  }
}

const lldbSession = new LLDBSession();

async function handleLLDB(params: Record<string, unknown>) {
  const command = params.command as string | undefined;
  const detach = params.detach as boolean | undefined;

  if (detach) {
    lldbSession.detach();
    return { content: [{ type: "text", text: "LLDB session detached." }] };
  }

  if (!command) {
    return {
      content: [{ type: "text", text: "Error: 'command' parameter is required" }],
      isError: true,
    };
  }

  // Auto-attach if not already connected
  if (!lldbSession.isAttached()) {
    let pid: number | undefined;
    const targets = getAliveTargets();
    if (targets.length > 0 && targets[0].pid) {
      pid = targets[0].pid;
    }

    if (!pid) {
      return {
        content: [{ type: "text", text: "Error: No running app found. Launch the app first with nerve_run." }],
        isError: true,
      };
    }

    try {
      const attachMsg = await lldbSession.attach(pid);
      const result = await lldbSession.execute(command);
      return { content: [{ type: "text", text: `${attachMsg}\n\n${result}` }] };
    } catch (e) {
      return {
        content: [{ type: "text", text: `Error attaching LLDB: ${(e as Error).message}` }],
        isError: true,
      };
    }
  }

  try {
    const result = await lldbSession.execute(command);
    return { content: [{ type: "text", text: result }] };
  } catch (e) {
    return {
      content: [{ type: "text", text: `LLDB error: ${(e as Error).message}` }],
      isError: true,
    };
  }
}

// --- Simulator Management (Mac-side) ---

async function handleListSimulators(params: Record<string, unknown>) {
  const bootedOnly = params.booted_only as boolean | undefined;

  try {
    const json = JSON.parse(await runShell("xcrun simctl list devices available -j"));
    const lines: string[] = [];

    for (const [runtime, devices] of Object.entries(json.devices) as [string, any[]][]) {
      // Extract OS version from runtime string
      const osMatch = runtime.match(/iOS[- ](\d+[\d.-]*)/);
      if (!osMatch) continue;
      const os = `iOS ${osMatch[1].replace(/-/g, ".")}`;

      const filtered = bootedOnly ? devices.filter((d: any) => d.state === "Booted") : devices;
      if (filtered.length === 0) continue;

      lines.push(`${os}:`);
      for (const d of filtered) {
        const state = d.state === "Booted" ? " [Booted]" : "";
        lines.push(`  ${d.name} — ${d.udid}${state}`);
      }
    }

    if (lines.length === 0) {
      return { content: [{ type: "text", text: bootedOnly ? "No booted simulators." : "No simulators available." }] };
    }

    return { content: [{ type: "text", text: lines.join("\n") }] };
  } catch (e) {
    return {
      content: [{ type: "text", text: `Error listing simulators: ${(e as Error).message}` }],
      isError: true,
    };
  }
}

async function handleBootSimulator(params: Record<string, unknown>) {
  const simulator = params.simulator as string;
  if (!simulator) {
    return {
      content: [{ type: "text", text: "Error: 'simulator' parameter is required" }],
      isError: true,
    };
  }

  try {
    // Check if it's a UDID or a name
    let udid = simulator;
    if (!simulator.match(/^[0-9A-F]{8}-/i)) {
      // It's a name, resolve to UDID
      udid = await findSimulatorUDID(simulator);
    }

    try {
      await runShell(`xcrun simctl boot "${udid}"`);
    } catch {
      // Already booted
    }
    await runShell("open -a Simulator");

    return { content: [{ type: "text", text: `Booted simulator: ${simulator} (${udid})` }] };
  } catch (e) {
    return {
      content: [{ type: "text", text: `Error: ${(e as Error).message}` }],
      isError: true,
    };
  }
}

// Register tool list handler
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

// Register tool call handler
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const params = (args ?? {}) as Record<string, unknown>;
  const targetId = params.target as string | undefined;

  // Map MCP tool name to Nerve command
  const command = name.replace("nerve_", "");

  // --- Mac-side commands (don't go through WebSocket) ---

  if (command === "build" || command === "run") {
    return handleBuildRun(command, params);
  }

  // Grant permissions via simctl (Mac-side)
  if (command === "grant_permissions") {
    return handleGrantPermissions(params);
  }

  // LLDB debugger (Mac-side)
  if (command === "lldb") {
    return handleLLDB(params);
  }

  // Simulator management (Mac-side)
  if (command === "list_simulators") {
    return handleListSimulators(params);
  }
  if (command === "boot_simulator") {
    return handleBootSimulator(params);
  }

  // Deeplink via simctl (Mac-side, when method is "simctl")
  if (command === "deeplink" && (params.method === "simctl" || getAliveTargets().length === 0)) {
    return handleDeeplinkSimctl(params);
  }

  // Special case: status doesn't need a connection
  if (command === "status") {
    const targets = getAliveTargets();
    if (targets.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: "No Nerve instances found.\n\nMake sure your iOS app includes the Nerve SPM package:\n  #if DEBUG\n  import Nerve\n  Nerve.start()\n  #endif\n\nThen build and run with nerve_run.",
          },
        ],
      };
    }

    // Get status from each alive target
    const results: string[] = [];
    for (const target of targets) {
      try {
        const result = await send("status", {}, target.id);
        results.push(result);
      } catch (e) {
        results.push(`${target.id}: error — ${(e as Error).message}`);
      }
    }

    return {
      content: [{ type: "text", text: results.join("\n\n") }],
    };
  }

  try {
    // Remove device 'target' from params before forwarding
    const { target: _, target_screen, ...commandParams } = params as Record<string, unknown> & { target_screen?: string };
    // For navigate: rename target_screen → target for the framework
    if (command === "navigate" && target_screen) {
      (commandParams as Record<string, unknown>).target = target_screen;
    }
    const result = await send(command, commandParams, targetId);

    // For screenshots, check if the result is base64 image data
    if (command === "screenshot" && result.startsWith("data:image/")) {
      const base64 = result.replace("data:image/png;base64,", "");
      return {
        content: [
          {
            type: "image",
            data: base64,
            mimeType: "image/png",
          },
        ],
      };
    }

    return {
      content: [{ type: "text", text: result }],
    };
  } catch (e) {
    const error = e as Error;
    return {
      content: [{ type: "text", text: `Error: ${error.message}` }],
      isError: true,
    };
  }
});

// --- Build & Run (Mac-side, no WebSocket) ---

function runShell(cmd: string, timeoutMs = 120000): Promise<string> {
  return new Promise((resolve, reject) => {
    const proc = spawn("bash", ["-c", cmd], { timeout: timeoutMs });
    let stdout = "";
    let stderr = "";
    proc.stdout?.on("data", (d: Buffer) => { stdout += d.toString(); });
    proc.stderr?.on("data", (d: Buffer) => { stderr += d.toString(); });
    proc.on("close", (code: number | null) => {
      if (code === 0) resolve(stdout + (stderr ? `\n${stderr}` : ""));
      else reject(new Error(`Exit code ${code}\n${stderr || stdout}`));
    });
    proc.on("error", reject);
  });
}

async function findSimulatorUDID(name: string): Promise<string> {
  const json = await runShell("xcrun simctl list devices available -j");
  const data = JSON.parse(json);
  for (const [, devices] of Object.entries(data.devices) as [string, any[]][]) {
    for (const d of devices) {
      if (d.name === name) return d.udid;
    }
  }
  throw new Error(`Simulator '${name}' not found`);
}

async function handleBuildRun(command: string, params: Record<string, unknown>) {
  const scheme = params.scheme as string;
  const simulator = (params.simulator as string) || "iPhone 16 Pro";
  const workspace = params.workspace as string | undefined;
  const project = params.project as string | undefined;

  if (!scheme) {
    return {
      content: [{ type: "text", text: "Error: 'scheme' parameter is required" }],
      isError: true,
    };
  }

  const log: string[] = [];

  try {
    // Build args
    let buildSource = "";
    if (workspace) buildSource = `-workspace "${workspace}"`;
    else if (project) buildSource = `-project "${project}"`;

    // Per-project derived data to avoid cross-project collisions
    const projectDir = workspace ? path.dirname(path.resolve(workspace)) : project ? path.dirname(path.resolve(project)) : process.cwd();
    const projectName = path.basename(projectDir);
    const derivedData = `/tmp/nerve-derived-data-${projectName}`;
    const buildCmd = `set -o pipefail && xcodebuild build ${buildSource} -scheme "${scheme}" -sdk iphonesimulator -derivedDataPath "${derivedData}" -quiet 2>&1 | tail -20`;

    log.push(`Building ${scheme} for simulator...`);
    let buildOutput: string;
    try {
      buildOutput = await runShell(buildCmd, 300000);
    } catch (e) {
      const errMsg = (e as Error).message;
      log.push(errMsg);
      return {
        content: [{ type: "text", text: log.join("\n") }],
        isError: true,
      };
    }
    if (buildOutput.trim()) log.push(buildOutput.trim());
    log.push("Build succeeded.");

    if (command === "build") {
      return { content: [{ type: "text", text: log.join("\n") }] };
    }

    // --- Run: install + launch with Nerve injection ---

    // Get exact app path from build settings (no guessing with find)
    const settingsCmd = `xcodebuild -showBuildSettings ${buildSource} -scheme "${scheme}" -sdk iphonesimulator -derivedDataPath "${derivedData}" 2>/dev/null`;
    const settings = await runShell(settingsCmd);
    const builtProductsDir = settings.match(/^\s*BUILT_PRODUCTS_DIR = (.+)/m)?.[1]?.trim();
    const productName = settings.match(/^\s*FULL_PRODUCT_NAME = (.+)/m)?.[1]?.trim();

    const appPath = builtProductsDir && productName ? `${builtProductsDir}/${productName}` : "";

    if (!appPath) {
      return {
        content: [{ type: "text", text: log.join("\n") + "\nError: Could not find .app bundle" }],
        isError: true,
      };
    }

    const bundleId = (await runShell(
      `/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${appPath}/Info.plist"`
    )).trim();

    log.push(`App: ${bundleId}`);

    // Find simulator
    const udid = await findSimulatorUDID(simulator);
    log.push(`Simulator: ${simulator} (${udid})`);

    // Boot simulator if needed
    try {
      await runShell(`xcrun simctl boot "${udid}" 2>/dev/null`);
      log.push("Booted simulator.");
    } catch {
      // Already booted
    }

    // Install
    await runShell(`xcrun simctl install "${udid}" "${appPath}"`);
    log.push("Installed app.");

    // Stop existing instance if running
    try {
      await runShell(`xcrun simctl terminate "${udid}" "${bundleId}" 2>/dev/null`);
    } catch {
      // Not running
    }

    // Clean up old port file
    try {
      await runShell(`rm -f "/tmp/nerve-ports/${udid}-${bundleId}.json"`);
    } catch { /* ignore */ }

    // Launch
    await runShell(`xcrun simctl launch "${udid}" "${bundleId}"`);
    log.push("Launched.");

    // Wait for Nerve to be ready: poll port file + TCP probe
    const portFile = `/tmp/nerve-ports/${udid}-${bundleId}.json`;
    const launchTime = Date.now();
    let nerveReady = false;
    for (let i = 0; i < 40; i++) {
      if (fs.existsSync(portFile)) {
        try {
          const info = JSON.parse(fs.readFileSync(portFile, "utf-8"));
          const fileTime = fs.statSync(portFile).mtimeMs;
          if (fileTime >= launchTime - 2000) {
            // Port file is fresh — TCP probe to verify server is accepting connections
            if (await tcpProbe("127.0.0.1", info.port, 2000)) {
              log.push(`Nerve ready on port ${info.port}`);
              nerveReady = true;
              break;
            }
          }
        } catch { /* file being written, retry */ }
      }
      await new Promise(r => setTimeout(r, 500));
    }

    if (!nerveReady) {
      log.push("Nerve did not start. Ensure your app includes the Nerve SPM package with Nerve.start() in #if DEBUG.");
    }

    return { content: [{ type: "text", text: log.join("\n") }] };
  } catch (e) {
    const error = e as Error;
    log.push(`Error: ${error.message}`);
    return {
      content: [{ type: "text", text: log.join("\n") }],
      isError: true,
    };
  }
}

// --- Grant Permissions (Mac-side) ---

async function handleGrantPermissions(params: Record<string, unknown>) {
  const services = params.services as string[] | undefined;
  if (!services || services.length === 0) {
    return {
      content: [{ type: "text", text: "Error: 'services' parameter is required (e.g., ['camera', 'photos'] or ['all'])" }],
      isError: true,
    };
  }

  // Find alive target to get UDID and bundle ID
  const targets = getAliveTargets();
  let udid: string | undefined;
  let bundleId: string | undefined;

  if (targets.length > 0) {
    udid = targets[0].udid;
    bundleId = targets[0].bundleId;
  }

  if (!udid || !bundleId) {
    return {
      content: [{ type: "text", text: "Error: No running Nerve instance found. Launch the app first." }],
      isError: true,
    };
  }

  const log: string[] = [];
  for (const service of services) {
    try {
      await runShell(`xcrun simctl privacy "${udid}" grant ${service} "${bundleId}" 2>&1`);
      log.push(`Granted: ${service}`);
    } catch (e) {
      log.push(`Failed: ${service} — ${(e as Error).message.split("\n")[0]}`);
    }
  }

  return { content: [{ type: "text", text: log.join("\n") }] };
}

// --- Deeplink via simctl (Mac-side) ---

async function handleDeeplinkSimctl(params: Record<string, unknown>) {
  const url = params.url as string;
  if (!url) {
    return {
      content: [{ type: "text", text: "Error: 'url' parameter is required" }],
      isError: true,
    };
  }

  // Find UDID
  let udid: string | undefined;
  const targets = getAliveTargets();
  if (targets.length > 0) {
    udid = targets[0].udid;
  }

  if (!udid) {
    // Try booted simulators
    try {
      const json = JSON.parse(await runShell("xcrun simctl list devices available -j"));
      for (const [, devices] of Object.entries(json.devices) as [string, any[]][]) {
        for (const d of devices) {
          if (d.state === "Booted") { udid = d.udid; break; }
        }
        if (udid) break;
      }
    } catch {}
  }

  if (!udid) {
    return {
      content: [{ type: "text", text: "Error: No simulator found" }],
      isError: true,
    };
  }

  try {
    await runShell(`xcrun simctl openurl "${udid}" "${url}"`);
    return { content: [{ type: "text", text: `Opened URL: ${url}` }] };
  } catch (e) {
    return {
      content: [{ type: "text", text: `Error opening URL: ${(e as Error).message}` }],
      isError: true,
    };
  }
}

// --- Main ---

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("[nerve] MCP server started");
}

main().catch((e) => {
  console.error("[nerve] Fatal:", e);
  process.exit(1);
});
