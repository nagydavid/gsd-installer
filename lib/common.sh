#!/usr/bin/env bash
# common.sh — logging, prompts, run wrapper, backups, manifests, JSON(C) merge

C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'

log()  { echo "${C_GREEN}[install]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[warn]${C_RESET} $*" >&2; }
die()  { echo "${C_RED}[error]${C_RESET} $*" >&2; exit 1; }
section() { echo; echo "${C_DIM}── $* ──${C_RESET}"; }

# run <desc> <cmd...>  — respects --dry-run
run() {
  local desc="$1"; shift
  if $DRY_RUN; then log "[dry-run] $desc: $*"; return 0; fi
  log "$desc"
  "$@"
}

prompt_choice() { # <question> <opt1> <opt2> ... ; sets CHOICE (1-based)
  local q="$1"; shift
  if $ASSUME_YES; then CHOICE=1; log "$q [auto-selected: $1]"; return 0; fi
  echo "$q"
  local i=1
  for opt in "$@"; do echo "  $i. $opt"; i=$((i+1)); done
  local input
  echo -n "> " >&2
  if input=$(read -r </dev/tty 2>/dev/null); then :; else read -r input; fi
  [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input < i )) || { echo "Invalid choice."; prompt_choice "$q" "$@"; return 0; }
  CHOICE="$input"
}

# ---------------------------------------------------------------- config roots
opencode_config_dir() { echo "${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"; }
copilot_config_dir()  { echo "${COPILOT_CONFIG_DIR:-${COPILOT_HOME:-$HOME/.copilot}}"; }

# ---------------------------------------------------------------- backups + manifests
# Backups and manifests live inside the harness's own config dir, so a
# rollback for one harness can never see (or touch) the other harness's state.
installer_backup_root() { # <configdir>
  echo "$1/backups/gsd-installer"
}

manifest_path() { # <configdir>
  local root; root="$(installer_backup_root "$1")"
  echo "$root/manifest.json"
}

INSTALL_TS="$(date -u +%Y%m%dT%H%M%SZ)"

backup_file() { # <configdir> <file>  — copy-if-exists, record in manifest
  local cfg="$1" file="$2"
  [[ -f "$file" ]] || return 0
  local root rel dest
  root="$(installer_backup_root "$cfg")"
  rel="${file#"$cfg"/}"
  [[ "$rel" == "$file" ]] && rel="$(basename "$file")"
  dest="$root/$INSTALL_TS/files/$rel"
  mkdir -p "$(dirname "$dest")"
  cp -p "$file" "$dest"
  manifest_record "$cfg" "$INSTALL_TS" backup "$file" "$dest"
}

manifest_record() { # <configdir> <ts> <kind> <file> <stored>
  local cfg="$1" ts="$2" kind="$3" file="$4" stored="${5:-}"
  local mf; mf="$(manifest_path "$cfg")"
  mkdir -p "$(dirname "$mf")"
  [[ -f "$mf" ]] || echo '{"runs":{}}' > "$mf"
  node -e '
    const fs=require("fs");
    const [mf,ts,kind,file,stored]=process.argv.slice(1);
    const o=JSON.parse(fs.readFileSync(mf,"utf8"));
    o.runs[ts]=o.runs[ts]||[];
    o.runs[ts].push({kind,file,stored});
    fs.writeFileSync(mf,JSON.stringify(o,null,2));
  ' "$mf" "$ts" "$kind" "$file" "$stored"
}

manifest_latest_ts() { # <configdir> — newest run timestamp or empty
  local mf; mf="$(manifest_path "$1")"
  [[ -f "$mf" ]] || { echo ""; return 0; }
  node -e '
    const fs=require("fs");
    const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const ts=Object.keys(o.runs).sort();
    console.log(ts.length?ts[ts.length-1]:"");
  ' "$mf"
}

# ---------------------------------------------------------------- JSON(C) merge
# Additive-only merge for JSONC/JSON config files: never overwrites existing
# values, so existing model routing / permissions / MCP entries survive.
jsonc_merge() { # <file> <spec-json>  — prints result JSON; writes only if changed & valid
  node "$INSTALLER_ROOT/lib/jsonc-merge.cjs" --file "$1" --spec "$2"
}
