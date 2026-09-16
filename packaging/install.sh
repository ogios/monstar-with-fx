#!/usr/bin/env bash
# Build and install Monstar on this machine using makepkg.
#
# This wraps the Arch packaging template (packaging/arch/monstar-git.PKGBUILD.in),
# generating a PKGBUILD in a temp dir and letting makepkg fetch deps, build,
# package, and install. Unlike the template's default, the source is pointed at
# this repository's working tree so the installed binary matches HEAD.
#
# Usage:
#   ./packaging/install.sh              build + install (makepkg -si; sudo on install)
#   ./packaging/install.sh --no-install build + package only (makepkg -s)
#
# Options:
#   --no-install   Stop after building the .pkg.tar.zst (no system install)
#   -h|--help      Show this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

INSTALL=1

die() { echo "error: $*" >&2; exit 1; }

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-install)
      INSTALL=0
      shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      die "unknown option: $1 (see --help)"
      ;;
  esac
done

# -- Preflight -------------------------------------------------------------
command -v makepkg >/dev/null 2>&1 \
  || die "makepkg not found (install base-devel) -- this script targets Arch Linux"
command -v pacman >/dev/null 2>&1 \
  || die "pacman not found -- this script targets Arch Linux"

# -- Generate PKGBUILD in an isolated dir ----------------------------------
PKGDIR="$(mktemp -d)"
trap 'rm -rf "$PKGDIR"' EXIT

echo "==> Generating PKGBUILD from packaging/arch/monstar-git.PKGBUILD.in"
sed 's/@VERSION@/0/' packaging/arch/monstar-git.PKGBUILD.in > "$PKGDIR/PKGBUILD"

# Point the source at this repository's working tree so makepkg builds the
# checked-out HEAD (a local file:// git source, unlike the default GitHub
# fetch). Do NOT add #branch=HEAD: makepkg treats it as a literal branch name
# and resolves it to the unpacked tip, not the worktree's commit.
sed -i \
  "s|source=('monstar::git+https://.*')|source=('monstar::git+file://${REPO_ROOT}')|" \
  "$PKGDIR/PKGBUILD"

# arch pkgdesc is injected after pkgdesc; also disable the debug split so the
# install is the bare ReleaseFast binary, not a monstar-git-debug package.
sed -i "s|^pkgdesc=.*|&\noptions=('!debug')|" "$PKGDIR/PKGBUILD"

grep '^pkgver\|^source\|^sha256\|^options' "$PKGDIR/PKGBUILD" >&2

# -- Build (and optionally install) ----------------------------------------
echo "==> Running makepkg in ${PKGDIR}"
if [[ "$INSTALL" -eq 1 ]]; then
  (cd "$PKGDIR" && makepkg -si) || die "makepkg -si failed"
else
  (cd "$PKGDIR" && makepkg -s) || die "makepkg -s failed"
fi

echo "✅ monstar package built in ${PKGDIR}"
[[ "$INSTALL" -eq 1 ]] && echo "   installed via pacman"
