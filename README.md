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
