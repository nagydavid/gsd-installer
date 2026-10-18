# GSD Core Installer — OpenCode / GitHub Copilot CLI / Both

Installs GSD Core + context tooling (Billion Context, LeanCTX, RTK) for one
or both harnesses. Each harness: own config, own model routing, own
verification, own rollback. Shared tools installed once. Neither harness is
a prerequisite for the other.

## Quick start

One line on macOS or Linux (needs `bash`, `curl`, `node`; `git` optional —
falls back to the GitHub tarball; `python3` optional for live model pricing):

```bash
curl -fsSL https://raw.githubusercontent.com/nagydavid/gsd-installer/main/bootstrap.sh | bash
# explicit mode / preview:
curl -fsSL https://raw.githubusercontent.com/nagydavid/gsd-installer/main/bootstrap.sh | bash -s -- --harness both --dry-run
# pin a ref:
GSD_INSTALLER_VERSION=main curl -fsSL https://raw.githubusercontent.com/nagydavid/gsd-installer/main/bootstrap.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/nagydavid/gsd-installer && cd gsd-installer
./install.sh                      # interactive (detects harnesses)
./install.sh --harness opencode   # or: copilot | both
./install.sh --dry-run            # preview, changes nothing
./install.sh --rollback           # undo last run (per harness)

--profile economy|balanced|quality|custom   # Copilot model profiles
--recommend-models                # recommendations only, no writes
--yes                             # noninteractive defaults
```

Rollback after a curl install (manifests live in your config dirs, so no
local copy is needed):

```bash
curl -fsSL https://raw.githubusercontent.com/nagydavid/gsd-installer/main/bootstrap.sh | bash -s -- --rollback --harness opencode
```

## Why each component

| Component | Layer | Verdict |
|---|---|---|
| GSD Core | workflow | the product; staged upstream-only, never patched |
| Billion Context | conversation history | single compressor; native compaction stays off |
| RTK | shell tool boundary | keep global; no overlap with bili |
| LeanCTX | code retrieval, on demand | register MCP; use via task instruction |
| Routing in `opencode.jsonc` | config | user-owned; survives all GSD updates |

Why not one tool? Each works at a different layer — history (bili), shell
output (RTK), file retrieval (LeanCTX). Two compressors at one layer =
double compression + cache thrash. That is why native compaction stays off.

## Measured context reduction per component

| Component | How it was tested | Reduction |
|---|---|---|
| Billion Context | 14 planning benchmarks (Phases 5–6) | **−57–77%** context exposure |
| RTK | production execution workload, 1,301 shell commands | **−34.1%** shell output (153.2K tokens saved); 0.05% in planning |
| LeanCTX (on-demand) | 2.02 MB / 162-file repo benchmark, 5 keyed questions (Phase 8) | **−40.3%** exposure · −78.7% tool bytes · −54% tool calls |
| LeanCTX rules block | fixed-overhead measurement (Phase 7) | **−2,837 tok/session** removed via `inject_rules=false` |
| GSD MCP + plugins | fixed-overhead ladder (Phase 8) | **−459 tok/request** (they compress roster injection) |

Scale caveat: LeanCTX is net-negative at 144 KB (native grep is already
selective there); its benefit appears at ≥2 MB repositories. Fixed cost of
keeping its MCP registered: +288 tok/request.

Fixed-overhead ladder (first-request input tokens, bench lane):

| Layer | Tokens |
|---|---|
| bare OpenCode | 5,302 |
| + GSD catalog (64 agents / 72 commands / 73 skills) | 12,493 |
| + gsd MCP + gsd/rtk plugins | 12,034 (net −459) |
| + lean-ctx MCP | 12,322 (+288) |

Update policy from the same program: pin a version only on a reproducible
functional regression (bili 0.1.197 pin was removed once 0.1.199 validated
non-degrading: 99.9% cache hit, no regression). Maintainability audit:
10/10 mechanisms SUPPORTED; the one fragile item (absolute binary path) is
fixed in this installer.

## What each setting does

| Setting | Purpose |
|---|---|
| `plugins: ["billion-context"]` | registers the compressor once |
| `mcp.gsd` | GSD tools for agents |
| `mcp.lean-ctx` / `mcpServers.lean-ctx` | on-demand retrieval (PATH-resolved) |
| RTK `preToolUse` hook (Copilot) | shell compression, same as OpenCode's wrapper |
| `subagents.agents.<role>`, `model`, `autoTier` (Copilot) | per-role model + thinking effort |
| `compaction.auto=false` (preserved) | exactly one compressor |

All edits are **additive-only** (`lib/jsonc-merge.cjs`): existing routing,
permissions, and MCP entries are preserved; a preservation check aborts the
write if anything existing would change.

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
bootstrap.sh            curl one-liner entry (fetch + run install.sh)
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
