#!/bin/sh
set -eu

REPO_ROOT="${PERRY_RELEASE_SOURCE_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"

die() {
  echo "release source verification: $*" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "git is required"
[ -d "${REPO_ROOT}" ] || die "source root does not exist: ${REPO_ROOT}"
git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree 2>/dev/null | grep -qx true \
  || die "source root is not a Git worktree"
git -C "${REPO_ROOT}" rev-parse --verify HEAD >/dev/null 2>&1 \
  || die "source root has no checked-out revision"

STATUS="$(git -C "${REPO_ROOT}" status --porcelain=v1 --untracked-files=all)"
[ -z "${STATUS}" ] || die "signed packaging requires a clean worktree"

echo "verified clean release source at $(git -C "${REPO_ROOT}" rev-parse HEAD)"
