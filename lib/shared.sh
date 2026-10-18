#!/usr/bin/env bash
# shared.sh — shared tools installed ONCE, independent of harness choice.
# Integrations (opencode.jsonc plugins/mcp, ~/.copilot hooks/mcp-config) are
# configured per-harness by the harness modules, never here.

shared_state_file() { echo "${GSD_INSTALLER_STATE_DIR:-$HOME/.local/share/gsd-installer}/shared-state.json"; }

resolve_lean_ctx() { # prints absolute path to a lean-ctx binary, or nothing; PATH first, then npm prefix / standard bin dirs
  local c; c="$(command -v lean-ctx 2>/dev/null || true)"
  [[ -n "$c" ]] && { echo "$c"; return 0; }
  command -v npm >/dev/null 2>&1 || return 0
  local pfx d
  pfx="$(npm config get prefix 2>/dev/null || true)"
  for d in "$pfx/bin" "$HOME/.npm-global/bin" /opt/homebrew/bin /usr/local/bin; do
    [[ -n "$d" && -x "$d/lean-ctx" ]] && { echo "$d/lean-ctx"; return 0; }
  done
  return 0
}

tool_present() { # <name>  — name is the npm package or binary probe
  case "$1" in
    billion-context) command -v bili >/dev/null 2>&1 || npm ls -g billion-context >/dev/null 2>&1 ;;
    lean-ctx-bin)    command -v lean-ctx >/dev/null 2>&1 ;;
    rtk)             command -v rtk >/dev/null 2>&1 ;;
  esac
}

ensure_shared_tools() { # <harness>
  section "Shared tools (install once)"
  local state; state="$(shared_state_file)"
  local record="{}"
  for pkg in billion-context lean-ctx-bin rtk; do
    local probe="$pkg"
    case "$pkg" in lean-ctx-bin) probe=lean-ctx ;; esac
    if tool_present "$probe"; then
      log "$pkg: already installed — skipping (shared tools are never installed twice)"
      record="$(node -e 'const a=JSON.parse(process.argv[1]);a[process.argv[2]]="present";console.log(JSON.stringify(a))' "$record" "$pkg")"
      continue
    fi
    case "$pkg" in
      billion-context|lean-ctx-bin)
        run "install $pkg (npm global)" npm install -g "$pkg" ;;
      rtk)
        if command -v cargo >/dev/null 2>&1; then
          run "install rtk (cargo)" cargo install rtk
        else
          warn "rtk not found and cargo unavailable — install rtk (https://github.com/rtk-ai/rtk) or re-run with it on PATH; RTK integration will be skipped."
          record="$(node -e 'const a=JSON.parse(process.argv[1]);a[process.argv[2]]="skipped";console.log(JSON.stringify(a))' "$record" "$pkg")"
          continue
        fi ;;
    esac
    record="$(node -e 'const a=JSON.parse(process.argv[1]);a[process.argv[2]]="installed";console.log(JSON.stringify(a))' "$record" "$pkg")"
  done
  if ! $DRY_RUN; then
    mkdir -p "$(dirname "$state")"
    node -e '
      const fs=require("fs");
      const [state,ts,rec,harness]=process.argv.slice(1);
      let o={runs:[]};
      try{o=JSON.parse(fs.readFileSync(state,"utf8"))}catch{}
      o.runs=o.runs||[];
      o.runs.push({ts,harness,tools:JSON.parse(rec)});
      fs.writeFileSync(state,JSON.stringify(o,null,2));
    ' "$state" "$INSTALL_TS" "$record" "$1"
    log "Shared tool state recorded: $state"
  fi
}
