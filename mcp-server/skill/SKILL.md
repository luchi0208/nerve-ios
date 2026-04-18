---
name: nerve-debug
description: Debug iOS app issues using Nerve's runtime logging and inspection. Use when the user reports a bug, unexpected behavior, or asks to debug/investigate/fix an issue in an iOS app with Nerve MCP tools available. Requires nerve-mcp to be configured.
---

# Nerve Debug

Evidence-driven iOS debugging using runtime log injection and Nerve tools. Never guess — observe, confirm, then fix.

## Methodology

### Phase 1: Understand the bug
- Read the user's bug description carefully.
- Identify the relevant source files — read them to understand the data flow.
- Form a hypothesis about where the bug might be, but do NOT assume it is correct.

### Phase 2: Instrument with logs
- Add `print("[nerve] ...")` trace logs at key points in the suspected code path.
- Log variable values, function entry/exit, and conditional branches.
- Use descriptive prefixes: `[nerve:CartVM]`, `[nerve:SyncService]`, etc.
- Place multiple log points upfront to minimize build-run cycles.

Example:
```swift
print("[nerve:CartVM] calculateTotal called, items.count=\(items.count)")
for item in items {
    print("[nerve:CartVM] item=\(item.name) price=\(item.price) qty=\(item.quantity)")
}
print("[nerve:CartVM] total=\(total)")
```

### Phase 3: Build and reproduce
- Use `nerve_run` to build and launch the app on the simulator.
- Use `nerve_view` to see the current screen state.
- Try to navigate to the relevant screen using `nerve_tap`, `nerve_scroll`, etc.
- If you cannot reach the screen or reproduce the bug, ask the user for help:
  > "I've added logs and the app is running. Can you navigate to [screen] and reproduce the issue? Let me know when it happens."
- NEVER use `nerve_screenshot` — it bloats context. Use `nerve_view` for screen state.

### Phase 4: Read and analyze logs
- Use `nerve_console` with `filter="[nerve]"` to read your trace logs.
- Compare actual values against expected values.
- If logs are insufficient to pinpoint the root cause, add more targeted logs and rebuild (go back to Phase 2).

### Phase 5: Confirm root cause
- You must be able to state the root cause with evidence from the logs.
- "I can see in the logs that X is Y when it should be Z, because [reason]."
- Do NOT proceed to fix until root cause is confirmed with log evidence.

### Phase 6: Fix and verify
- Apply the fix.
- Keep the trace logs in place.
- Rebuild with `nerve_run`, reproduce the scenario again.
- Read `nerve_console` to confirm the fix — values should now be correct.
- Use `nerve_view` to confirm the UI reflects the fix.

### Phase 7: Clean up
- Remove all `print("[nerve...]")` trace logs you added.
- Do NOT remove any pre-existing logging in the code.

## Rules

1. **Never guess the root cause.** Always confirm with log evidence before fixing.
2. **Never use `nerve_screenshot`.** Use `nerve_view` only.
3. **Minimize build cycles.** Add multiple log points per iteration, not one at a time.
4. **Ask for human help when stuck.** If you can't navigate to the right screen or reproduce the bug, ask the user to do it while you watch the logs.
5. **Clean up after yourself.** Remove all injected trace logs after the fix is verified.
6. **Don't fix unrelated code.** Only fix the bug — no refactoring, no "improvements."

## Human-in-the-loop

When you need the user's help to reproduce:

1. Make sure logs are instrumented and the app is running.
2. Tell the user exactly what to do: "The app is running. Please [do X] and let me know when [Y] happens."
3. After the user confirms, read `nerve_console` with `filter="[nerve]"` to analyze.
4. If you need another round, say so — "I need more data. I've added logs to [area]. Can you try again?"

## Quick reference: Nerve tools used

| Tool | Purpose |
|------|---------|
| `nerve_run` | Build and launch app on simulator |
| `nerve_view` | See current screen elements (text-based) |
| `nerve_tap` | Tap buttons, rows, tabs |
| `nerve_scroll` | Scroll lists |
| `nerve_back` | Navigate back |
| `nerve_dismiss` | Dismiss modals/keyboard |
| `nerve_console` | Read app logs (use `filter="[nerve]"`) |
| `nerve_type` | Type text into fields |
| `nerve_navigate` | Auto-navigate to a known screen |
