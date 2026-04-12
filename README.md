# Nerve

Nerve gives AI agents eyes and hands inside iOS apps.

Add the MCP server to your AI agent, and it can see every element on screen, tap buttons, fill forms, scroll, inspect state, intercept network calls, and debug your iOS app — all through natural language. No code changes needed.

## Setup

### 1. Install the MCP Server

```bash
npx nerve-mcp@latest
```

Or install globally:

```bash
npm install -g nerve-mcp
```

Or clone and build from source:

```bash
git clone https://github.com/luchi0208/nerve-ios.git
cd nerve/mcp-server && npm install && npm run build
```

### 2. Configure Your AI Agent

**Claude Code** — add to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "nerve": {
      "command": "npx",
      "args": ["nerve-mcp@latest"]
    }
  }
}
```

**Claude Desktop / Cursor / Other MCP clients:**

```json
{
  "mcpServers": {
    "nerve": {
      "command": "npx",
      "args": ["nerve-mcp@latest"]
    }
  }
}
```

If installed from source:

```json
{
  "mcpServers": {
    "nerve": {
      "command": "node",
      "args": ["/path/to/nerve/mcp-server/dist/index.js"]
    }
  }
}
```

That's it. Tell your AI agent to build and run your app — Nerve auto-injects on the Simulator with no code changes needed.

## Example

Things you can ask your AI agent with Nerve:

> "Run my app on the simulator. Go to the checkout screen and try submitting an empty form — what validation errors show up?"

> "There's a bug where the cart badge doesn't update after removing an item. Can you reproduce it and check the console logs?"

> "Navigate through every screen in the app and find any buttons that don't respond to taps."

> "The login screen looks broken on iPhone SE. Run it on that simulator and screenshot just the login form so I can see what's wrong."

> "Trace all calls to `CartManager.addItem` and then add three items to the cart. Show me what arguments are being passed."

> "Check what's stored in UserDefaults after onboarding completes. I think we're saving the auth token in the wrong key."

> "Intercept the network requests when I pull to refresh on the orders screen. Show me the response bodies — I think the API is returning stale data."

These are just starting points. The agent combines Nerve's tools on its own — you describe what you want in plain English, and it figures out the sequence of taps, inspections, and checks to get there.

## How It Works

Nerve auto-injects into the app at launch on the Simulator — no code changes needed. It runs inside the app process, starts a WebSocket server, and the MCP server on the Mac connects to it. AI agent tool calls are translated into commands executed inside the app.

Because it runs in-process, Nerve has access to the full view hierarchy, the Objective-C runtime, live objects, network delegates, and the HID event system.

```
AI Agent  →  MCP Server (Mac)  →  WebSocket  →  Nerve (in-app)  →  UIKit/SwiftUI
```

## Tools

### See the Screen

| Tool | Description |
|------|-------------|
| `nerve_view` | See all visible elements with type, label, ID, tap point, and position |
| `nerve_tree` | Full view hierarchy (UIKit + SwiftUI) |
| `nerve_inspect` | Detailed properties of a specific element |
| `nerve_screenshot` | Capture the screen as an image |

### Interact

| Tool | Description |
|------|-------------|
| `nerve_tap` | Tap an element by `@eN` ref, `#identifier`, `@label`, or coordinates |
| `nerve_type` | Type text into the focused field |
| `nerve_scroll` | Scroll in any direction |
| `nerve_swipe` | Swipe gesture |
| `nerve_long_press` | Long press |
| `nerve_double_tap` | Double tap |
| `nerve_drag_drop` | Drag from one element to another |
| `nerve_pull_to_refresh` | Pull to refresh |
| `nerve_pinch` | Pinch/zoom |
| `nerve_context_menu` | Open context menu |
| `nerve_back` | Navigate back |
| `nerve_dismiss` | Dismiss keyboard or modal |
| `nerve_action` | Invoke a custom accessibility action on an element |
| `nerve_sequence` | Execute multiple commands in a single call — faster than one-by-one |
| `nerve_wait_idle` | Wait for all network requests and animations to finish |

### Navigate

| Tool | Description |
|------|-------------|
| `nerve_map` | See all discovered screens and transitions |
| `nerve_navigate` | Auto-navigate to a known screen |
| `nerve_scroll_to_find` | Scroll until an element appears |
| `nerve_deeplink` | Open a URL scheme |

### Inspect & Debug

| Tool | Description |
|------|-------------|
| `nerve_console` | App logs (stdout/stderr) |
| `nerve_network` | Intercepted HTTP traffic with response bodies |
| `nerve_heap` | Find live object instances by class name |
| `nerve_storage` | Read UserDefaults, Keychain, cookies, files |
| `nerve_trace` | Swizzle any method to log calls |
| `nerve_highlight` | Draw colored borders on elements for visual debugging |
| `nerve_modify` | Change view properties at runtime |
| `nerve_lldb` | Full LLDB debugger access |

### Build & Launch

| Tool | Description |
|------|-------------|
| `nerve_run` | Build, install, and launch on the simulator (auto-injects Nerve) |
| `nerve_build` | Build only |
| `nerve_status` | Show connected targets |
| `nerve_list_simulators` | List available simulators |
| `nerve_boot_simulator` | Boot a simulator by name or UDID |
| `nerve_appearance` | Switch between light and dark mode |
| `nerve_grant_permissions` | Pre-grant iOS permissions |

## Element Queries

Nerve supports several query formats for targeting elements:

| Format | Example | Description |
|--------|---------|-------------|
| `@eN` | `@e2` | Element ref from `nerve_view` output |
| `#id` | `#login-btn` | Accessibility identifier |
| `@label` | `@Settings` | Accessibility label |
| `.type:index` | `.field:0` | Element type with index |
| `x,y` | `195,160` | Screen coordinates |

The `nerve_view` output shows each element with its ref and tap point:

```
@e1 btn "Product A" #product-a tap=195,222 x=16 y=195 w=358 h=54
@e2 field val=Email tap=195,160 x=32 y=149 w=326 h=22
```

Use `@e2` to tap that field — Nerve uses the element's activation point (center), which is always the correct hittable position.

## Architecture

```
Nerve/
  Sources/
    Nerve/           Swift framework — commands, element resolution, inspection
    NerveObjC/       ObjC/C bridge — touch synthesis, heap walking, swizzling
  Example/           Example app with test views
  Tests/
    E2E/             End-to-end tests (83 tests)
    NerveTests/      Unit tests
  mcp-server/        MCP server (TypeScript)
  cli/               CLI tool
```

## Requirements

- macOS 14+
- Xcode 16+
- iOS Simulator (iOS 16+)
- Node.js 18+

## License

MIT
