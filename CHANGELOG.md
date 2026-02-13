# Changelog - Discord Orchestration

## 2026-02-13 - OpenClaw SubAgent Soft Disable

**Status:** SOFT DISABLED  
**Reason:** Issue #10467 - OpenClaw `sessions_spawn` stability problems

### Architecture Change
- **Discord orchestration:** MANDATORY (was: PRIMARY)
- **OpenClaw `sessions_spawn`:** DISABLED (was: FALLBACK ONLY)
  
### Impact
- Cookie (orchestrator) uses Discord workers ONLY
- `sessions_spawn` tool: DEPRECATED — use triggers deprecation warning
- If Discord unavailable: HALT and report to Derrick (no fallback)

### Files Modified
- README.md: Architecture section updated
- SOUL.md: Orchestrator directives clarified
- CHANGELOG.md: This entry

### Verification
```bash
# Verify no legacy references
grep -r "sessions_spawn" README.md SOUL.md CHANGELOG.md 2>/dev/null || echo "✅ Clean"
```
