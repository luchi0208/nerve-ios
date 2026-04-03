# Nerve Roadmap

## Zero-touch DYLD injection (low priority)

Allow Nerve to inject into any simulator app without SPM dependency or code changes.

**Proven working** — tested and validated with e2e tests (80/82 pass).

### How it works
1. Pre-build Nerve as a standalone `.framework` dylib for iphonesimulator
2. On `nerve run`, launch the app via `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` pointing to the pre-built dylib
3. `__attribute__((constructor))` fires automatically, starts Nerve — no import, no `Nerve.start()` needed

### What was done
- Made `nerve_auto_start` a public/exported symbol (required for `dlsym` to find it)
- Fixed bootstrap to register notification observer synchronously + fallback for already-launched apps
- Manual dylib build tested and working

### What remains
- `nerve install` command — pre-builds the dylib and copies to a known path (e.g., `/usr/local/lib/Nerve/`)
- Update `nerve run` / MCP `nerve_run` to use `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` when no SPM dep detected
- Build script or Makefile target to produce the standalone dylib
- Optional: distribute pre-built xcframework for manual embed (Xcode Cmd+R path)

### Limitations
- Simulator only — DYLD env vars are stripped on real devices
- App must be launched through `nerve run` / `simctl launch`, not Xcode Cmd+R
- For Xcode Cmd+R, user can manually embed the xcframework (no code changes, constructor auto-starts)
