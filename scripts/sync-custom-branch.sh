#!/usr/bin/env bash
# Allow users to run this file with `sh scripts/sync-custom-branch.sh ...`.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

# Rebase the personal customization branch onto the fork's synced main branch.
#
# Typical usage after the weekly GitHub Actions upstream sync:
#   sh scripts/sync-custom-branch.sh
#
# Defaults:
#   ORIGIN_REMOTE=origin
#   UPSTREAM_REMOTE=upstream
#   MAIN_BRANCH=main
#   CUSTOM_BRANCH=custom/personal
#
# Useful flags:
#   --no-verify   Skip npm install/typecheck/build
#   --no-push     Do not push the rebased custom branch

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"
CUSTOM_BRANCH="${CUSTOM_BRANCH:-custom/personal}"
RUN_VERIFY=1
RUN_PUSH=1

usage() {
  cat <<USAGE
Sync personal branch with latest fork main

Usage:
  $0 [options]

Options:
  --no-verify   Skip npm install/typecheck/build
  --no-push     Do not push ${CUSTOM_BRANCH} after rebase
  -h, --help    Show this help

Environment overrides:
  ORIGIN_REMOTE=${ORIGIN_REMOTE}
  UPSTREAM_REMOTE=${UPSTREAM_REMOTE}
  MAIN_BRANCH=${MAIN_BRANCH}
  CUSTOM_BRANCH=${CUSTOM_BRANCH}
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-verify) RUN_VERIFY=0; shift ;;
    --no-push) RUN_PUSH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

cd "$ROOT_DIR"

require_clean_worktree() {
  if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    echo "Working tree is not clean. Commit or stash your changes before syncing." >&2
    git status --short >&2
    exit 1
  fi
}

current_branch() {
  git branch --show-current
}

cleanup_message() {
  cat >&2 <<'MSG'

Sync stopped before completion.
If a rebase conflict is in progress, use one of:
  git status
  git add <resolved-files>
  git rebase --continue

or abort it with:
  git rebase --abort
MSG
}
trap cleanup_message ERR

require_clean_worktree

START_BRANCH="$(current_branch)"

echo "==> Fetching remotes"
git fetch "$ORIGIN_REMOTE" "$MAIN_BRANCH"
git fetch "$UPSTREAM_REMOTE" "$MAIN_BRANCH"

echo "==> Updating local ${MAIN_BRANCH} from ${ORIGIN_REMOTE}/${MAIN_BRANCH}"
git checkout "$MAIN_BRANCH"
git pull --ff-only "$ORIGIN_REMOTE" "$MAIN_BRANCH"

echo "==> Checking fork main includes upstream main"
if ! git merge-base --is-ancestor "$UPSTREAM_REMOTE/$MAIN_BRANCH" "$MAIN_BRANCH"; then
  cat >&2 <<MSG
${MAIN_BRANCH} does not include ${UPSTREAM_REMOTE}/${MAIN_BRANCH} yet.
The weekly GitHub Actions sync may not have run or may have failed.

You can either:
  1. Run the GitHub Actions workflow manually on GitHub, then rerun this script; or
  2. Manually update main locally:
       git checkout ${MAIN_BRANCH}
       git merge --ff-only ${UPSTREAM_REMOTE}/${MAIN_BRANCH}
       git push ${ORIGIN_REMOTE} ${MAIN_BRANCH}
MSG
  exit 1
fi

echo "==> Rebasing ${CUSTOM_BRANCH} onto ${MAIN_BRANCH}"
git checkout "$CUSTOM_BRANCH"
git rebase "$MAIN_BRANCH"

if [[ "$RUN_VERIFY" -eq 1 ]]; then
  echo "==> Installing/updating dependencies"
  npm install

  echo "==> Running typecheck"
  npm run typecheck

  echo "==> Running build"
  npm run build
fi

if [[ "$RUN_PUSH" -eq 1 ]]; then
  echo "==> Pushing ${CUSTOM_BRANCH} with --force-with-lease"
  git push --force-with-lease "$ORIGIN_REMOTE" "$CUSTOM_BRANCH"
fi

trap - ERR

echo "==> Done"
echo "Started on: ${START_BRANCH}"
echo "Current branch: $(current_branch)"
git status --short
