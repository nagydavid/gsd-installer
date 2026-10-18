#!/usr/bin/env bash
# detect.sh — harness detection. A harness counts as present when its binary
# is on PATH or its config directory exists. Detection is symmetric:
# neither harness is ever a prerequisite for the other.

HAVE_OPENCODE=0
HAVE_COPILOT=0

detect_harnesses() {
  if command -v opencode >/dev/null 2>&1 || [[ -d "$(opencode_config_dir)" ]]; then
    HAVE_OPENCODE=1
  fi
  if command -v copilot >/dev/null 2>&1 || [[ -d "$(copilot_config_dir)" ]]; then
    HAVE_COPILOT=1
  fi
}
