# GSD Core Installer — OpenCode / GitHub Copilot CLI / Both

Installs GSD Core + context tooling (Billion Context, LeanCTX, RTK) for one
or both harnesses. Each harness: own config, own model routing, own
verification, own rollback. Shared tools installed once. Neither harness is
a prerequisite for the other.

## Quick start

```bash
./install.sh                      # interactive (detects harnesses)
./install.sh --harness opencode   # or: copilot | both
./install.sh --dry-run            # preview, changes nothing
./install.sh --rollback           # undo last run (per harness)

--profile economy|balanced|quality|custom   # Copilot model profiles
--recommend-models                # recommendations only, no writes
--yes                             # noninteractive defaults
```

## Why each component

| Component | Layer | Measured result | Verdict |
|---|---|---|---|
| GSD Core | workflow | 35 agents / 72 commands / 72 skills | the product; staged upstream-only, never patched |
| Billion Context | conversation history | 99.9% prompt-cache hit | single compressor; native compaction stays off |
| RTK | shell tool boundary | −34.1% output in execution (153.2K tok saved, 1,301 cmds) | keep global; no overlap with bili |
| LeanCTX | code retrieval, on demand | −40.3% exposure, −78.7% tool bytes, −54% tool calls @ +288 tok fixed | register MCP; use via task instruction |
| Routing in `opencode.jsonc` | config | survives all GSD updates | user-owned; upstream touches only `mcp` |

Why not one tool? Each works at a different layer — history (bili), shell
output (RTK), file retrieval (LeanCTX). Two compressors at one layer =
double compression + cache thrash. That is why native compaction stays off.

## Evidence (Phases 5–8, local models, MEASURED)

| Phase | Finding | Number |
|---|---|---|
| 5–6 | 14 planning benchmarks; RTK planning vs execution | 0.05% vs **34.1%** |
| 5–6 | version-confounded arm → update policy | pin only on reproducible regression |
| 7 | LeanCTX auto-injected rules block, no spontaneous use | 2,837 tok/session → `inject_rules=false` |
| 7 | bili version pin removed, auto-update restored | 0.1.197 → latest |
| 8 | bili upgrade validated live | 0.1.199, 99.9% cache hit, no regression |
| 8 | RTK five-point check | all PASS |
| 8 | LeanCTX benchmark, 2.02 MB / 162 files, 5 keyed questions | −40.3% exposure, 5/5 accuracy both arms |
| 8 | overhead ladder | bare 5,302 → +GSD 12,493 → gsd plugins **−459** → +lean-ctx +288 |
| 8 | maintainability audit | 10/10 SUPPORTED; absolute-path fragility fixed here |

Conclusion: four components, each with a distinct measured role — the stack
is final. This installer encodes exactly that configuration.

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
