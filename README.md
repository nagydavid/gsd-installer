# GSD Core Installer — OpenCode / GitHub Copilot CLI

Modular installer for GSD Core plus the shared context tooling
(Billion Context, LeanCTX, RTK). Three equally supported modes:

1. **OpenCode only**
2. **GitHub Copilot CLI only**
3. **Both**

Neither harness is ever a prerequisite for the other. Each harness gets
independent configuration, agent registration, model routing,
thinking-effort settings, verification, backups, and rollback. Shared tools
are installed once; their integrations are configured per harness.

## Usage

```bash
./install.sh                      # interactive: detects harnesses, asks
./install.sh --harness opencode   # OpenCode only
./install.sh --harness copilot    # Copilot CLI only
./install.sh --harness both       # both, side by side

--profile economy|balanced|quality|custom   # Copilot model profiles
--profile-file <path>                       # custom profile JSON
--recommend-models                          # recommendations only, no writes
--recommend-only                            # OpenCode: never rewrite routing
--dry-run                                   # print actions, change nothing
--yes                                       # accept defaults noninteractively
--rollback                                  # undo last run (per harness)
```

If exactly one harness is detected it is selected by default. If both are
detected all three choices are offered. If neither is detected the installer
explains prerequisites and exits without changing anything.

## Why each component exists

The stack looks like four overlapping tools. It isn't — each one operates at
a different layer, and every layer was measured before it was kept.

| Component | Layer | Why it is needed |
|---|---|---|
| **GSD Core** | Workflow | The product itself: spec-driven planning/execution (35 agents, 72 commands, 72 skills). Kept fully upstream-managed — the installer only *stages* it with the official adapter and never forks or patches it. |
| **Billion Context** | Conversation history | The single compression authority. OpenCode's native compaction is disabled (`compaction.auto=false`): native compaction discards whole context ranges and breaks the provider prompt cache. Billion Context replaces consumed tool output with summaries while keeping the stable prefix byte-identical — production prompt-cache hit rate measured at **99.9%**. Two compressors would double-compress and thrash the cache, so native compaction stays off. |
| **RTK** | Shell tool boundary | Rewrites/compresses shell command output *before* it enters the conversation. Measured **34.1% shell-output reduction in execution workloads** (production: 1,301 commands, 153.2K tokens saved); negligible in planning, but free to keep. Distinct layer from Billion Context (command output vs conversation history) — verified no duplicate compression. |
| **LeanCTX** | Code retrieval (on demand) | Selective retrieval for large repositories. Benchmark on a 2 MB / 162-file fixture: **−40.3% context exposure, −78.7% tool-output bytes, −54% tool calls, same 5/5 retrieval accuracy**. Fixed cost is only **+288 tokens/request** (MCP schemas). It never triggers spontaneously, so the recommended posture is: MCP registered, instruction injection off, one task-level instruction when a task needs it. |
| **Model routing in `opencode.jsonc`** | Configuration | Model assignments live in user-owned config, not in agent files. GSD updates regenerate the catalog but touch only `mcp` entries — routing and permissions survive every upstream update. |

### Why each setting the installer writes

| Setting | Purpose |
|---|---|
| `plugins: ["billion-context"]` (OpenCode) | Registers the compression authority exactly once. |
| `mcp.gsd` (OpenCode) | Exposes GSD tools to agents via the upstream MCP server. |
| `mcp.lean-ctx` (OpenCode) / `mcpServers.lean-ctx` (Copilot) | On-demand selective retrieval; PATH-resolved command, no hardcoded absolute paths. |
| RTK `preToolUse` hook (Copilot) | Gives Copilot CLI the same shell-output compression OpenCode gets from its wrapper (`rtk hook copilot`). |
| `subagents.agents.<role>` + `model`/`autoTier` (Copilot) | Per-GSD-role model and thinking-effort routing; additive so existing entries are never overwritten. |
| `compaction.auto=false` (preserved, never enabled) | Keeps exactly one compressor in the stack. |

## Evidence from the optimization phases (5–8)

All numbers below are **MEASURED** with local models only; evidence labels
VERIFIED / MEASURED / INFERRED were applied per finding.

- **Phases 5–6 — 14 planning benchmarks** (arms: GSD-only, +RTK, +RTK+LeanCTX,
  full stack, +Billion Context, LeanCTX+Bili; standard vs chunked planning):
  RTK is negligible in planning (0.05% of exposure) but decisive in execution
  (34.1%). Billion Context established as the single compression authority.
  A version-confounded arm comparison taught the update policy: *only a
  reproducible functional regression justifies pinning a version.*
- **Phase 7 — context integration & cleanup**: fixed-overhead ladder measured;
  LeanCTX's auto-injected AGENTS.md rules block measured at **2,837
  tokens/session with zero spontaneous use** → disable via the supported knob
  `inject_rules = false` (no custom hooks needed). Billion Context version
  stabilization: the 0.1.197 pin was removed and auto-update restored through
  supported channels.
- **Phase 8 — finalization**: Billion Context 0.1.197 → latest stable
  (0.1.199) upgrade validated live (99.9% prompt-cache hit, no regression,
  native compaction still off). RTK verified on all five checks (interception,
  exit codes, error passthrough, output recovery, no duplicate compression).
  LeanCTX large-repository benchmark (2.02 MB fixture, 162 files, 5 keyed
  questions, two arms, isolated sessions): on-demand LeanCTX −40.3% exposure
  at +288 fixed tokens. Overhead ladder: bare OpenCode 5,302 → +GSD catalog
  12,493 → GSD MCP+plugins **net −459** (they compress roster injection) →
  +LeanCTX MCP +288. The only safe global cut found was the 2.8K rules block.
- **Maintainability audit**: all 10 investigated mechanisms classified
  SUPPORTED; the one fragile item (absolute binary path for the LeanCTX MCP
  command) is fixed in this installer — commands are PATH-resolved.

**Conclusion of the phases:** the four-component stack is final. Each
component has a distinct measured role; further optimization has diminishing
returns. This installer encodes exactly that final configuration.

## What each mode does

| Step | OpenCode | Copilot CLI |
|---|---|---|
| GSD staging | `npx @opengsd/gsd-core@latest --opencode --global` (upstream installer) | `npx @opengsd/gsd-core@latest --copilot --global` |
| Global agents | `~/.config/opencode/agents/gsd-*.md` (upstream) | `~/.copilot/agents/gsd-*.md` (upstream) |
| Model routing | **Preserved** — `opencode.jsonc` `agent` block is never rewritten | `copilot config model` + `autoTier` + `subagents.agents.<role>` per profile |
| Thinking effort | upstream agent frontmatter (untouched) | `effortLevel` per role in `settings.json` |
| Billion Context | `plugins` entry (additive) | not applicable upstream — documented, not forced |
| LeanCTX | `mcp.lean-ctx` entry (PATH-resolved) | `mcp-config.json` `mcpServers.lean-ctx` |
| RTK | already global via OpenCode shell wrapper (untouched) | `preToolUse` hook `rtk hook copilot` in `~/.copilot/hooks/` |
| Verification | staging + JSONC validity + integration entries | staging + instructions marker + hook/settings/mcp JSON validity |
| Rollback | restores pre-install `opencode.jsonc`, upstream `--uninstall` | restores settings, removes created hook, upstream `--uninstall` |

All config-file edits are **additive-only** (`lib/jsonc-merge.cjs`):
existing values, routing maps, permissions, and MCP servers are preserved;
a preservation check aborts the write if anything existing would change.

## Model profiles (Copilot)

Profiles map GSD role groups to GitHub's official model categories
(Lightweight / Versatile / Powerful) with per-role `effortLevel`
(`low|medium|high|xhigh|max`). Models are resolved from the **live**
official pricing page (docs.github.com) at run time, falling back to the
bundled `data/pricing-snapshot.json` when offline.

- `economy` — cheapest per role, Auto tier `efficiency`
- `balanced` — mid-tier per role, Auto tier `balance` (recommended)
- `quality` — flagship planning/verification, Auto tier `intelligence`
- `custom` — your own JSON (see `profiles/balanced.json` as template)

OpenCode recommendations are provider-aware only; GitHub Copilot pricing is
never assumed for other OpenCode providers, and existing OpenCode routing is
preserved by default.

## Isolation guarantees

- Config roots: `~/.config/opencode` vs `~/.copilot` (override with
  `OPENCODE_CONFIG_DIR` / `COPILOT_CONFIG_DIR`).
- Backups + manifests live inside each harness's own config dir
  (`backups/gsd-installer/`), so rollback for one harness can never see or
  touch the other's state.
- Installing one harness never modifies the other's configuration;
  installing both preserves existing settings in each.
- Shared tool state is recorded once in
  `~/.local/share/gsd-installer/shared-state.json`; tools already present
  are never reinstalled.

## Tests

```bash
./tests/run-tests.sh
```

41 checks across a fully sandboxed fake-harness environment (restricted
PATH, throwaway config dirs): OpenCode-only, Copilot-only, both, harness
isolation, idempotence, rollback scope, neither-installed UX, dry-run, and
recommend-only. Real user configuration is never touched.

## Layout

```
install.sh              entry point + arg parsing + harness choice
lib/common.sh           logging, prompts, run wrapper, backups, manifests, JSONC merge
lib/detect.sh           symmetric harness detection
lib/shared.sh           shared tools (install once)
lib/models.sh           pricing retrieval, profiles, per-harness model recommendations
lib/jsonc-merge.cjs     additive-only JSONC merge with preservation check
lib/parse-pricing.py    official GitHub pricing table parser
lib/opencode.sh         OpenCode install/configure/verify/rollback
lib/copilot.sh          Copilot install/configure/verify/rollback
profiles/*.json         economy | balanced | quality
data/pricing-snapshot.json  offline fallback for official pricing
tests/run-tests.sh      mode validation suite
```
