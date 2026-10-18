# GSD Installer — OpenCode · GitHub Copilot CLI · Both

One command installs [GSD Core](https://github.com/OpenGSD/gsd-core) plus a
measured, token-efficient context stack — Billion Context, RTK, LeanCTX — into
OpenCode, GitHub Copilot CLI, or both.

- **Maximum token efficiency** — every component justified by benchmark numbers, not vibes
- **Minimum maintenance** — additive-only config edits, upstream-managed GSD, no custom patches
- **Full upstream compatibility** — GSD Core is staged exactly as upstream ships it, never modified

Each harness gets its own config, model routing, verification, and rollback.
Shared tools install once. Neither harness is a prerequisite for the other.

## Quick start

One line on macOS or Linux (needs `bash`, `curl`, `node`; `npm` for GSD
staging; `python3` optional for live pricing):

```bash
curl -fsSL https://raw.githubusercontent.com/nagydavid/gsd-installer/main/dist/install.sh | bash
```

Preview first, or pick a harness explicitly:

```bash
curl -fsSL https://raw.githubusercontent.com/nagydavid/gsd-installer/main/dist/install.sh | bash -s -- --harness both --dry-run
```

Or clone and run:

```bash
git clone https://github.com/nagydavid/gsd-installer && cd gsd-installer
./install.sh                      # interactive (detects harnesses)
./install.sh --harness opencode   # or: copilot | both
./install.sh --dry-run            # preview, changes nothing
./install.sh --rollback           # undo last run (per harness)
```

| Flag | Effect |
|---|---|
| `--harness opencode\|copilot\|both` | skip the interactive choice |
| `--dry-run` | print planned actions, write nothing |
| `--rollback` | restore the last run's backups (per-harness scope) |
| `--profile economy\|balanced\|quality\|custom` | Copilot model profiles |
| `--recommend-models` | pricing recommendations only, no writes |
| `--yes` | noninteractive defaults |

Pin a version: replace `main` in the URL with a tag or commit SHA.
Rollback after a curl install (manifests live in your config dirs, so no
local copy is needed):

```bash
curl -fsSL https://raw.githubusercontent.com/nagydavid/gsd-installer/main/dist/install.sh | bash -s -- --rollback --harness opencode
```

## What changes on your machine

| Path | Change |
|---|---|
| `~/.config/opencode/opencode.jsonc` | `mcp.gsd`, `mcp.lean-ctx`, `plugins: ["billion-context"]` added — existing routing, permissions, and MCP entries preserved byte-for-byte |
| `~/.copilot/config.json` | `model` + `autoTier` + per-role `subagents.agents.<role>` effort (Copilot only) |
| `~/.copilot/mcp-config.json` | `mcpServers.lean-ctx` added (existing servers preserved) |
| `~/.copilot/hooks/gsd-rtk.json` | RTK `preToolUse` hook (created only if absent) |
| `~/.config/opencode/` (or `~/.copilot/`) | GSD catalog staged by the upstream installer: 35 agents, 29 compact personas, 72 commands, 72 skills |
| `~/.config/opencode/backups/…` | timestamped backups + manifest written before every edit |

Everything is additive. A preservation check aborts the write if any existing
value would change. `compaction.auto=false` is preserved — exactly one
compressor (Billion Context) runs per session.

## Why these four components

| Component | Layer | Verdict |
|---|---|---|
| GSD Core | workflow | the product; staged upstream-only, never patched |
| Billion Context | conversation history | single compressor; native compaction stays off |
| RTK | shell tool boundary | keep global; no overlap with bili |
| LeanCTX | code retrieval, on demand | register MCP; use via task instruction |

Why not one tool? Each works at a different layer — history (bili), shell
output (RTK), file retrieval (LeanCTX). Two compressors at one layer = double
compression + cache thrash. That is why native compaction stays off.

## Measured context reduction

All figures are MEASURED in the Phase 5–8 benchmark program (OpenCode V2,
identical fixtures per arm, deterministic answer keys) — not estimates.

| Component | How it was tested | Reduction |
|---|---|---|
| Billion Context | 14 planning benchmarks (Phases 5–6) | **−57–77%** context exposure |
| RTK | production execution workload (Phase 7) + live `rtk gain` | **−34.1%** shell output benchmark; live machine **−40.9%** (2,146 commands, 265K tokens saved); 0.05% in planning |
| LeanCTX (on-demand) | 2.02 MB / 162-file repo benchmark, 5 keyed questions (Phase 8) | **−40.3%** exposure · −78.7% tool bytes · −54% tool calls · −5.3% latency, 5/5 accuracy |
| LeanCTX rules block | fixed-overhead measurement (Phase 7) | **−2,837 tok/session** removed via `inject_rules=false` |
| GSD MCP + plugins | fixed-overhead ladder (Phase 8) | **−459 tok/request** (they compress roster injection) |

Fixed-overhead ladder (first-request input tokens, bench lane):

| Layer | Tokens |
|---|---|
| bare OpenCode | 5,302 |
| + GSD catalog (64 agents / 72 commands / 73 skills) | 12,493 |
| + gsd MCP + gsd/rtk plugins | 12,034 (net −459) |
| + lean-ctx MCP | 12,322 (+288) |

Scale caveat: LeanCTX is net-negative at 144 KB (native grep is already
selective there); its benefit appears at ≥2 MB repositories. Fixed cost of
keeping its MCP registered: +288 tok/request.

Update policy from the same program: pin a version only on a reproducible
functional regression (bili 0.1.197 pin was removed once 0.1.199 validated
non-degrading: 99.9% cache hit, no regression). Maintainability audit:
10/10 mechanisms SUPPORTED; the one fragile item (absolute binary path) is
fixed in this installer.

## What each setting does

| Setting | Purpose |
|---|---|
| `plugins: ["billion-context"]` | registers the compressor once |
| `mcp.gsd` | GSD tools for agents (`gsd-mcp-server --no-prompts`) |
| `mcp.lean-ctx` / `mcpServers.lean-ctx` | on-demand retrieval, spawn-safe (see Troubleshooting) |
| RTK `preToolUse` hook (Copilot) | shell compression, same as OpenCode's wrapper |
| `subagents.agents.<role>`, `model`, `autoTier` (Copilot) | per-role model + thinking effort |
| `compaction.auto=false` (preserved) | exactly one compressor |

All edits go through `lib/jsonc-merge.cjs`: additive-only merge with a
preservation check that aborts if anything existing would change.

## What each mode does

| Step | OpenCode | Copilot CLI |
|---|---|---|
| GSD staging | `npx @opengsd/gsd-core@latest --opencode --global` | `npx @opengsd/gsd-core@latest --copilot --global` |
| Model routing | preserved, never rewritten | profile → `model` + `autoTier` + per-role `effortLevel` |
| Verification | staging + JSONC + integration entries | staging + instructions marker + hook/settings/mcp validity |
| Rollback | restore pre-install jsonc + upstream `--uninstall` | restore settings, remove created hook + upstream `--uninstall` |

## Copilot model profiles

Models resolved from the **live** official GitHub pricing page, snapshot
fallback offline. OpenCode routing is never rewritten; GitHub pricing is
never assumed for other providers.

| Profile | Default | Planning/verification | Execution | Auto tier |
|---|---|---|---|---|
| economy | cheapest lightweight | versatile | lightweight | efficiency |
| balanced | mid versatile | powerful | versatile | balance |
| quality | flagship powerful | powerful (high effort) | powerful (median) | intelligence |
| custom | your JSON (`--profile-file`) | — | — | — |

## Verify your install

```bash
# OpenCode: GSD catalog + integration entries
ls ~/.config/opencode/agents | head          # gsd-*.agent.md files present
grep -E '"gsd"|"lean-ctx"|billion-context' ~/.config/opencode/opencode.jsonc

# lean-ctx entry must be spawn-safe (absolute path unless in a standard bin dir)
grep -A4 '"lean-ctx"' ~/.config/opencode/opencode.jsonc

# Copilot: hook + mcp entry
cat ~/.copilot/hooks/gsd-rtk.json
grep lean-ctx ~/.copilot/mcp-config.json
```

## Troubleshooting

**`mcp connect failed … NotFound: ChildProcess.spawn (lean-ctx mcp)`** — the
registered command isn't on the PATH that the OpenCode process sees (common
with npm-global or nvm prefixes, or after a brew node upgrade). Re-run the
installer: it resolves `lean-ctx` via `command -v`, then `$(npm config get
prefix)/bin`, `~/.npm-global/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, and
registers the absolute path. If the binary is absent everywhere it disables
the stale entry — install `lean-ctx-bin` and re-run to enable it.

**Billion Context not compressing** — check the daemon (`bili doctor`) and
that `plugins` contains exactly one `billion-context` entry (no duplicates).

**Something broke** — `./install.sh --rollback --harness <name>` restores the
pre-run config from that harness's own backup dir.

## Isolation

- Config roots: `~/.config/opencode` vs `~/.copilot` (override:
  `OPENCODE_CONFIG_DIR` / `COPILOT_CONFIG_DIR`).
- Backups + manifests inside each harness's own dir → rollback can never
  touch the other harness.
- Shared tool state recorded once (`~/.local/share/gsd-installer/`);
  present tools are never reinstalled.

## Tests

```bash
./tests/run-tests.sh   # 41 checks, fully sandboxed, real config untouched
```

Modes: opencode-only · copilot-only · both · isolation · idempotence ·
rollback scope · neither-installed UX · dry-run · recommend-only.

## Layout

```
dist/install.sh         generated single-file installer (the curl entry)
tools/bundle.sh         regenerates dist/install.sh after source edits
install.sh              entry + args + harness choice
lib/common.sh           logging, prompts, backups, manifests
lib/detect.sh           symmetric harness detection
lib/shared.sh           shared tools (install once)
lib/models.sh           pricing, profiles, recommendations
lib/jsonc-merge.cjs     additive-only merge + preservation check
lib/parse-pricing.py    official GitHub pricing parser
lib/opencode.sh         OpenCode install/configure/verify/rollback
lib/copilot.sh          Copilot install/configure/verify/rollback
profiles/*.json         economy | balanced | quality
data/pricing-snapshot.json  offline pricing fallback
tests/run-tests.sh      validation suite
```

## License

MIT — see [LICENSE](LICENSE).
