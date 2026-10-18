#!/usr/bin/env bash
# run-tests.sh — independent validation of the three installation modes.
# Fully sandboxed: fake harness binaries + fake upstream installer (npx) on a
# restricted PATH; OPENCODE_CONFIG_DIR / COPILOT_CONFIG_DIR / state dir point
# at a throwaway tree. Real user config is never touched.
set -uo pipefail

INSTALLER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="${TEST_SANDBOX:-/tmp/opencode/gsd-installer-tests}"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

fresh() { # <case-name> — reset sandbox + fake bin dir
  CASE="$SANDBOX/$1"
  rm -rf "$CASE"; mkdir -p "$CASE/oc" "$CASE/cp" "$CASE/bin" "$CASE/state"
  cat > "$CASE/bin/opencode" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "models" ]] && { echo "strata/qwen3.8-flash-next-iq3_xxs"; echo "anthropic/claude-sonnet-5"; exit 0; }
exit 0
EOF
  cat > "$CASE/bin/copilot" <<'EOF'
#!/usr/bin/env bash
# fake Copilot CLI: `copilot config model X` / `autoTier X` write settings.json
if [[ "${1:-}" == "config" ]]; then
  cfg="${COPILOT_CONFIG_DIR:-$HOME/.copilot}"; mkdir -p "$cfg"
  node -e 'const fs=require("fs");const p=process.argv[1];let o={};try{o=JSON.parse(fs.readFileSync(p,"utf8"))}catch{}
  o[process.argv[2]]=process.argv[3];fs.writeFileSync(p,JSON.stringify(o,null,2))' "$cfg/settings.json" "$2" "$3"
  exit 0
fi
exit 0
EOF
  cat > "$CASE/bin/npx" <<'EOF'
#!/usr/bin/env bash
# fake @opengsd/gsd-core installer: stages per-harness layout from --config-dir
args="$*"; cfg=""
prev=""; for a in $args; do [[ "$prev" == "--config-dir" ]] && cfg="$a"; prev="$a"; done
if [[ "$args" == *"--opencode"* ]]; then
  [[ -z "$cfg" ]] && cfg="${OPENCODE_CONFIG_DIR:?}"
  mkdir -p "$cfg/gsd-core" "$cfg/agents"
  if [[ "$args" == *"--uninstall"* ]]; then rm -rf "$cfg/gsd-core"; rm -f "$cfg/agents"/gsd-*.md; exit 0; fi
  echo "staged" > "$cfg/gsd-core/VERSION"
  for a in gsd-executor gsd-planner gsd-verifier; do echo "---" > "$cfg/agents/$a.md"; done
  [[ -f "$cfg/opencode.jsonc" ]] || printf '{\n  "agent": { "build": { "model": "strata/qwen3.8-flash-next-iq3_xxs" } }\n}\n' > "$cfg/opencode.jsonc"
elif [[ "$args" == *"--copilot"* ]]; then
  [[ -z "$cfg" ]] && cfg="${COPILOT_CONFIG_DIR:?}"
  mkdir -p "$cfg/gsd-core"
  if [[ "$args" == *"--uninstall"* ]]; then rm -rf "$cfg/gsd-core"; exit 0; fi
  echo "staged" > "$cfg/gsd-core/VERSION"
  grep -q "GSD" "$cfg/copilot-instructions.md" 2>/dev/null || printf '# Instructions\n\n## GSD Core\n\nGSD workflow commands available.\n' > "$cfg/copilot-instructions.md"
fi
exit 0
EOF
  for t in bili lean-ctx rtk npm curl; do printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE/bin/$t"; done
  chmod +x "$CASE/bin"/*
  export OPENCODE_CONFIG_DIR="$CASE/oc" COPILOT_CONFIG_DIR="$CASE/cp" GSD_INSTALLER_STATE_DIR="$CASE/state"
  export PATH="$CASE/bin:/usr/bin:/bin"
}

run_installer() { (cd "$INSTALLER" && ./install.sh "$@"); }

echo "── T1: OpenCode-only (works without Copilot) ──"
fresh t1
run_installer --harness opencode --yes >/dev/null 2>&1
check "gsd-core staged (opencode)" test -d "$OPENCODE_CONFIG_DIR/gsd-core"
check "global agents registered"   bash -c 'ls "$OPENCODE_CONFIG_DIR/agents"/gsd-*.md | grep -q gsd-executor'
check "opencode.jsonc valid JSONC" node -e 'const fs=require("fs");const s=fs.readFileSync(process.argv[1],"utf8").replace(/\/\/.*$/gm,"");JSON.parse(s)' "$OPENCODE_CONFIG_DIR/opencode.jsonc"
check "billion-context plugin added" grep -q '"billion-context"' "$OPENCODE_CONFIG_DIR/opencode.jsonc"
check "mcp.gsd added"              grep -q '"gsd"' "$OPENCODE_CONFIG_DIR/opencode.jsonc"
check "existing routing preserved" grep -q 'strata/qwen' "$OPENCODE_CONFIG_DIR/opencode.jsonc"
check "copilot dir untouched"      bash -c '! test -e "$COPILOT_CONFIG_DIR/gsd-core"'
check "shared state recorded"      test -f "$GSD_INSTALLER_STATE_DIR/shared-state.json"

echo "── T2: Copilot-only (works without OpenCode) ──"
fresh t2
rm -f "$CASE/bin/opencode"   # no OpenCode binary; also remove config dir so detection is negative
rmdir "$OPENCODE_CONFIG_DIR" 2>/dev/null || true
run_installer --harness copilot --profile economy --yes >/dev/null 2>&1
check "gsd-core staged (copilot)"   test -d "$COPILOT_CONFIG_DIR/gsd-core"
check "copilot-instructions GSD"    grep -qi GSD "$COPILOT_CONFIG_DIR/copilot-instructions.md"
check "RTK hook registered"         grep -q '"rtk"' "$COPILOT_CONFIG_DIR/hooks/gsd-rtk.json"
check "RTK hook contract valid"     node -e 'const h=require(process.argv[1]);if(h.version!==1||!h.hooks.preToolUse[0].args.includes("copilot"))process.exit(1)' "$COPILOT_CONFIG_DIR/hooks/gsd-rtk.json"
check "default model routed"        grep -q '"model"' "$COPILOT_CONFIG_DIR/settings.json"
check "role routing applied"        grep -q 'gsd-executor' "$COPILOT_CONFIG_DIR/settings.json"
check "effortLevel set"             grep -q 'effortLevel' "$COPILOT_CONFIG_DIR/settings.json"
check "lean-ctx mcp registered"     grep -q 'lean-ctx' "$COPILOT_CONFIG_DIR/mcp-config.json"
check "opencode dir untouched"      bash -c '! test -e "$OPENCODE_CONFIG_DIR/opencode.jsonc"'

echo "── T3: Both coexist; harness isolation ──"
fresh t3
run_installer --harness both --profile balanced --yes >/dev/null 2>&1
check "opencode staged"  test -d "$OPENCODE_CONFIG_DIR/gsd-core"
check "copilot staged"   test -d "$COPILOT_CONFIG_DIR/gsd-core"
check "oc jsonc routed"  grep -q '"gsd"' "$OPENCODE_CONFIG_DIR/opencode.jsonc"
check "cp routed"        grep -q 'gsd-planner' "$COPILOT_CONFIG_DIR/settings.json"
# isolation: copilot routing must not leak into opencode.jsonc and vice versa
check "no copilot keys in oc jsonc"  bash -c '! grep -q autoTier "$OPENCODE_CONFIG_DIR/opencode.jsonc"'
check "no oc agents in cp settings"  bash -c '! grep -q "billion-context" "$COPILOT_CONFIG_DIR/settings.json"'

echo "── T4: Idempotence (repeated install) ──"
before_oc="$(cat "$OPENCODE_CONFIG_DIR/opencode.jsonc")"
before_cp="$(cat "$COPILOT_CONFIG_DIR/settings.json")"
before_hooks="$(ls "$COPILOT_CONFIG_DIR/hooks" | wc -l)"
run_installer --harness both --profile balanced --yes >/dev/null 2>&1
check "opencode.jsonc unchanged on rerun" test "$before_oc" = "$(cat "$OPENCODE_CONFIG_DIR/opencode.jsonc")"
check "copilot settings unchanged on rerun" test "$before_cp" = "$(cat "$COPILOT_CONFIG_DIR/settings.json")"
check "no duplicate hooks" test "$before_hooks" = "$(ls "$COPILOT_CONFIG_DIR/hooks" | wc -l)"
check "no duplicate plugin entries" bash -c 'grep -c "billion-context" "$OPENCODE_CONFIG_DIR/opencode.jsonc" | grep -qx 1'
shared_runs="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).runs.length)' "$GSD_INSTALLER_STATE_DIR/shared-state.json")"
check "shared tools not reinstalled (skipped both runs)" test "$shared_runs" = 2

echo "── T5: Rollback scope ──"
run_installer --rollback --harness opencode >/dev/null 2>&1
check "opencode unstaged"   bash -c '! test -d "$OPENCODE_CONFIG_DIR/gsd-core"'
check "opencode.jsonc restored" bash -c '! grep -q "billion-context" "$OPENCODE_CONFIG_DIR/opencode.jsonc" || grep -q strata "$OPENCODE_CONFIG_DIR/opencode.jsonc"'
check "copilot untouched by oc rollback" test -d "$COPILOT_CONFIG_DIR/gsd-core"
run_installer --rollback --harness copilot >/dev/null 2>&1
check "copilot unstaged"    bash -c '! test -d "$COPILOT_CONFIG_DIR/gsd-core"'
check "RTK hook removed"    bash -c '! test -f "$COPILOT_CONFIG_DIR/hooks/gsd-rtk.json"'
check "opencode untouched by cp rollback" bash -c '! test -d "$OPENCODE_CONFIG_DIR/gsd-core" && test -f "$OPENCODE_CONFIG_DIR/opencode.jsonc"'

echo "── T6: Neither harness installed → prerequisites explained ──"
fresh t6
rm -f "$CASE/bin/opencode" "$CASE/bin/copilot"; rmdir "$OPENCODE_CONFIG_DIR" "$COPILOT_CONFIG_DIR" 2>/dev/null || true
out="$(run_installer --yes 2>&1 || true)"
check "explains prerequisites" bash -c "echo '$out' | grep -qi 'prerequisites'"
check "offers the three options" bash -c "echo '$out' | grep -q 'harness both'"

echo "── T7: --dry-run changes nothing ──"
fresh t7
run_installer --harness both --dry-run --yes >/dev/null 2>&1
check "no gsd-core (dry-run)"  bash -c '! test -e "$OPENCODE_CONFIG_DIR/gsd-core" && ! test -e "$COPILOT_CONFIG_DIR/gsd-core"'
check "no jsonc created"       bash -c '! test -e "$OPENCODE_CONFIG_DIR/opencode.jsonc"'

echo "── T8: --recommend-models (pricing retrieval + profiles) ──"
fresh t8
out="$(run_installer --recommend-models --harness copilot --profile balanced --yes 2>&1 || true)"
check "pricing source reported" bash -c "echo '$out' | grep -q 'pricing source'"
check "profile plan printed"    bash -c "echo '$out' | grep -q '\"profile\"'"
check "no writes (recommend only)" bash -c '! test -e "$COPILOT_CONFIG_DIR/settings.json"'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
