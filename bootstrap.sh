#!/usr/bin/env bash
# bootstrap.sh — one-line installer for macOS and Linux:
#
#   curl -fsSL https://raw.githubusercontent.com/nagydavid/gsd-installer/main/bootstrap.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/nagydavid/gsd-installer/main/bootstrap.sh | bash -s -- --harness both
#
# Fetches the repo (git if available, otherwise the GitHub tarball) into a
# temp dir and runs install.sh there with any passed-through flags.
# Pin a ref with: GSD_INSTALLER_VERSION=v1.0.0 curl -fsSL .../bootstrap.sh | bash
set -euo pipefail

REPO="nagydavid/gsd-installer"
REF="${GSD_INSTALLER_VERSION:-main}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gsd-installer.XXXXXX" 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

say() { echo "[bootstrap] $*"; }

fetch() { # git first, tarball fallback (tarball needs no git at all)
  if command -v git >/dev/null 2>&1 &&
     git clone --depth 1 --branch "$REF" "https://github.com/$REPO.git" "$TMP/repo" >/dev/null 2>&1; then
    return 0
  fi
  say "git unavailable or ref not a branch — downloading tarball…"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/${GSD_INSTALLER_VERSION:+tags/}$REF" \
    | tar xz -C "$TMP"
  mv "$TMP"/gsd-installer-* "$TMP/repo"
}

for tool in curl node; do
  command -v "$tool" >/dev/null 2>&1 || { say "missing prerequisite: $tool"; exit 1; }
done

fetch
say "running installer (ref: $REF)"
"$TMP/repo/install.sh" "$@"
