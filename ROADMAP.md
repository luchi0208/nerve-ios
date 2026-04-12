# Nerve Roadmap

## Zero-touch DYLD injection — DONE

Nerve auto-injects into any simulator app without SPM dependency or code changes.

### How it works
1. `nerve_run` builds the app normally
2. Detects whether the app already includes Nerve (SPM) by checking for `nerve_auto_start` symbol
3. If not found, builds `Nerve.framework` from source (cached at `.build/inject/`) and launches via `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`
4. `__attribute__((constructor))` fires automatically, starts Nerve — no import, no `Nerve.start()` needed

### Integration modes
- **Simulator (inject)**: Zero-touch via `DYLD_INSERT_LIBRARIES` — no code changes needed
- **Simulator (SPM)**: Add Nerve package + `Nerve.start()` — auto-detected, no injection
- **Device**: SPM only — DYLD env vars are stripped on real devices

### Implementation
- `Package.swift`: `NerveDynamic` product (dynamic library for framework build)
- `scripts/build-framework.sh`: Builds `Nerve.framework` for iphonesimulator, cached with staleness check
- `mcp-server/src/index.ts`: `nerve_run` auto-detects SPM vs inject, auto-builds framework if missing
- `cli/nerve`: Same detection and injection logic

### Limitations
- Simulator only — DYLD env vars are stripped on real devices
- App must be launched through `nerve run` / `simctl launch`, not Xcode Cmd+R
