#!/usr/bin/env bash
# install.sh — modular GSD Core + context-tooling installer.
# Modes: OpenCode only | GitHub Copilot CLI only | Both.
# Neither harness is ever a prerequisite for the other; harness state is
# fully isolated (own config dir, own backups/manifest, own rollback).
set -euo pipefail

INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$INSTALLER_ROOT/lib/common.sh"
source "$INSTALLER_ROOT/lib/detect.sh"
source "$INSTALLER_ROOT/lib/shared.sh"
source "$INSTALLER_ROOT/lib/models.sh"
source "$INSTALLER_ROOT/lib/opencode.sh"
source "$INSTALLER_ROOT/lib/copilot.sh"

DRY_RUN=false
ASSUME_YES=false
RECOMMEND_ONLY=false
HARNESS=""
PROFILE=""
PROFILE_FILE=""
MODE="install"

usage() {
  cat <<'EOF'
Usage: ./install.sh [mode] [options]

Modes:
  (default)            install / configure the selected harness(es)
  --recommend-models   print model recommendations only (no changes)
  --rollback           undo the last installer run for the selected harness(es)

Harness selection:
  --harness opencode|copilot|both   noninteractive selection
  (interactive mode detects installed harnesses and asks)

Profiles (Copilot model routing; OpenCode routing is always preserved):
  --profile economy|balanced|quality|custom
  --profile-file <path>             used with --profile custom

Other:
  --recommend-only      OpenCode: recommendations only, never rewrite routing
  --dry-run             print actions, change nothing
  --yes                 accept defaults noninteractively
  --help                this text

Config roots (override for tests or custom layouts):
  OPENCODE_CONFIG_DIR   default ~/.config/opencode
  COPILOT_CONFIG_DIR    default ~/.copilot
EOF
}

# ---------------------------------------------------------------- arg parsing
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  a="${args[$i]}"
  case "$a" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=true ;;
    --yes|-y) ASSUME_YES=true ;;
    --recommend-only) RECOMMEND_ONLY=true ;;
    --recommend-models) MODE="recommend" ;;
    --rollback) MODE="rollback" ;;
    --harness)
      i=$((i+1)); [[ $i -lt ${#args[@]} ]] || die "--harness requires opencode|copilot|both"
      HARNESS="${args[$i]}"
      case "$HARNESS" in opencode|copilot|both) : ;; *) die "invalid --harness '$HARNESS' (expected opencode|copilot|both)" ;; esac ;;
    --profile)
      i=$((i+1)); [[ $i -lt ${#args[@]} ]] || die "--profile requires economy|balanced|quality|custom"
      PROFILE="${args[$i]}"
      case "$PROFILE" in economy|balanced|quality|custom) : ;; *) die "invalid --profile '$PROFILE'" ;; esac ;;
    --profile-file)
      i=$((i+1)); [[ $i -lt ${#args[@]} ]] || die "--profile-file requires a path"
      PROFILE_FILE="${args[$i]}"
      [[ -f "$PROFILE_FILE" ]] || die "--profile-file not found: $PROFILE_FILE"
      PROFILE=custom ;;
    *) die "unknown argument: $a (see --help)" ;;
  esac
  i=$((i+1))
done

# ---------------------------------------------------------------- harness choice
detect_harnesses

resolve_harness() {
  if [[ -n "$HARNESS" ]]; then
    # Noninteractive: explicit choice is honored even if detection disagrees.
    case "$HARNESS" in
      opencode) WANT_OPENCODE=1; WANT_COPILOT=0 ;;
      copilot)  WANT_OPENCODE=0; WANT_COPILOT=1 ;;
      both)     WANT_OPENCODE=1; WANT_COPILOT=1 ;;
    esac
    if [[ "$HARNESS" == "opencode" && $HAVE_OPENCODE -eq 0 ]]; then
      warn "OpenCode was not detected on this machine."
      log "Prerequisites: install OpenCode (https://opencode.ai) or set OPENCODE_CONFIG_DIR."
      die "cannot configure OpenCode here."
    fi
    if [[ "$HARNESS" == "copilot" && $HAVE_COPILOT -eq 0 ]]; then
      warn "GitHub Copilot CLI was not detected on this machine."
      log "Prerequisites: install the Copilot CLI (https://docs.github.com/en/copilot) or set COPILOT_CONFIG_DIR."
      die "cannot configure Copilot CLI here."
    fi
    return 0
  fi

  # Interactive
  case "$((HAVE_OPENCODE + HAVE_COPILOT))" in
    2)
      prompt_choice "Which harness do you want to configure?" \
        "OpenCode" "GitHub Copilot CLI" "Both"
      case "$CHOICE" in 1) WANT_OPENCODE=1; WANT_COPILOT=0 ;; 2) WANT_OPENCODE=0; WANT_COPILOT=1 ;; 3) WANT_OPENCODE=1; WANT_COPILOT=1 ;; esac ;;
    1)
      if (( HAVE_OPENCODE )); then
        log "Detected harness: OpenCode (only harness found — selected by default)"
        WANT_OPENCODE=1; WANT_COPILOT=0
      else
        log "Detected harness: GitHub Copilot CLI (only harness found — selected by default)"
        WANT_OPENCODE=0; WANT_COPILOT=1
      fi ;;
    0)
      cat <<'EOF'
No supported harness was detected.

Prerequisites (install ONE of, then re-run):
  OpenCode:          https://opencode.ai  (binary 'opencode' on PATH)
  GitHub Copilot CLI: https://docs.github.com/en/copilot (binary 'copilot' on PATH)

Supported installation options:
  1. Install OpenCode, then: ./install.sh --harness opencode
  2. Install Copilot CLI,  then: ./install.sh --harness copilot
  3. Install both,         then: ./install.sh --harness both
EOF
      die "nothing to configure." ;;
  esac
}

WANT_OPENCODE=0
WANT_COPILOT=0
resolve_harness

# ---------------------------------------------------------------- modes
if [[ "$MODE" == "rollback" ]]; then
  (( WANT_OPENCODE )) && opencode_rollback
  (( WANT_COPILOT )) && copilot_rollback
  log "Rollback complete (scoped to the selected harness(es) only)."
  exit 0
fi

if [[ "$MODE" == "recommend" ]]; then
  (( WANT_COPILOT )) && { copilot_models; copilot_recommend_profile; }
  (( WANT_OPENCODE )) && opencode_models
  exit 0
fi

# ---------------------------------------------------------------- install flow
section "GSD installer  (harness: $( (( WANT_OPENCODE && WANT_COPILOT )) && echo "OpenCode + Copilot CLI" || (( WANT_OPENCODE )) && echo "OpenCode" || echo "Copilot CLI" )$( $DRY_RUN && echo '  [DRY RUN]' ))"

# Shared tools: installed once, never duplicated, integrations configured per harness.
ensure_shared_tools "$HARNESS"

if (( WANT_OPENCODE )); then
  section "OpenCode"
  opencode_install
  opencode_configure
  opencode_models
  if ! $DRY_RUN; then opencode_verify || die "OpenCode verification failed"; fi
fi

if (( WANT_COPILOT )); then
  section "GitHub Copilot CLI"
  copilot_install
  copilot_configure
  copilot_models
  if [[ -z "$PROFILE" ]] && ! $ASSUME_YES && ! $DRY_RUN; then
    prompt_choice "Copilot model profile?" "balanced (recommended)" "economy" "quality" "custom (via --profile-file)"
    case "$CHOICE" in 1) PROFILE=balanced ;; 2) PROFILE=economy ;; 3) PROFILE=quality ;; 4) PROFILE=custom ;; esac
  fi
  copilot_apply_profile
  if ! $DRY_RUN; then copilot_verify || die "Copilot verification failed"; fi
fi

section "Done"
log "Harness(es) configured: $( (( WANT_OPENCODE && WANT_COPILOT )) && echo "OpenCode + Copilot CLI" || (( WANT_OPENCODE )) && echo "OpenCode" || echo "Copilot CLI" )"
log "Backups + manifest: $( (( WANT_OPENCODE )) && echo "$(installer_backup_root "$(opencode_config_dir)")" )$( (( WANT_COPILOT )) && echo " $(installer_backup_root "$(copilot_config_dir)")" )"
log "Rollback: ./install.sh --rollback --harness opencode|copilot|both"
