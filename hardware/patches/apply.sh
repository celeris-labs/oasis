#!/usr/bin/env bash
#
# Re-apply the out-of-tree TOE receive-window clamp to the nested network submodule.
#
# Idempotent: run it as often as you like. It never resets, stashes or reverts anything --
# every check is a dry run (`git apply --check`), so a working tree that already carries the
# clamp is left exactly as it is.
#
# See README.md in this directory for what the clamp does and why it lives here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SUBMODULE_REL="parcore/libstf/coyote/hw/services/network"
SUBMODULE="${REPO_ROOT}/${SUBMODULE_REL}"

PATCH="${SCRIPT_DIR}/0001-toe-rx-window-clamp.patch"
BUNDLE="${SCRIPT_DIR}/oasis-cmake-defined-guard.bundle"

EXPECTED_SHA="e9edcc4b2b48b161b17cd60148515130ebeed66a"
EXPECTED_BRANCH="oasis/cmake-defined-guard"

die() { echo "apply.sh: ERROR: $*" >&2; exit 1; }

# --- the submodule has to be there at all -----------------------------------------------------
[ -d "${SUBMODULE}" ] || die "submodule not found at ${SUBMODULE}
  Run 'git submodule update --init --recursive' from ${REPO_ROOT} first."

git -C "${SUBMODULE}" rev-parse --git-dir >/dev/null 2>&1 \
  || die "${SUBMODULE} is not a git repository (submodule not initialised?)"

[ -f "${PATCH}" ] || die "patch not found: ${PATCH}"

# --- (a) the submodule must sit on the local-only commit the patch was cut against -------------
ACTUAL_SHA="$(git -C "${SUBMODULE}" rev-parse HEAD)"
if [ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]; then
    ACTUAL_BRANCH="$(git -C "${SUBMODULE}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    die "submodule HEAD is not the expected commit.
  path:     ${SUBMODULE_REL}
  expected: ${EXPECTED_SHA} (${EXPECTED_BRANCH})
  actual:   ${ACTUAL_SHA} (${ACTUAL_BRANCH})

  The two commits on '${EXPECTED_BRANCH}' exist nowhere but this machine and the bundle
  shipped beside this script. Restore them with:

      git -C ${SUBMODULE_REL} fetch ${BUNDLE} '${EXPECTED_BRANCH}:${EXPECTED_BRANCH}'
      git -C ${SUBMODULE_REL} checkout ${EXPECTED_BRANCH}
      bash hardware/patches/apply.sh"
fi

# --- (b) already applied? then stop, quietly and without touching the tree ---------------------
if git -C "${SUBMODULE}" apply --check --reverse "${PATCH}" >/dev/null 2>&1; then
    echo "apply.sh: patch already applied to ${SUBMODULE_REL} -- nothing to do."
    exit 0
fi

# --- (c) apply, but only if it applies cleanly -------------------------------------------------
if ! git -C "${SUBMODULE}" apply --check "${PATCH}" >/dev/null 2>&1; then
    die "patch neither applies nor is already applied to ${SUBMODULE_REL}.
  The working tree is in some third state -- inspect it by hand:
      git -C ${SUBMODULE_REL} diff -- hls/toe/rx_sar_table/rx_sar_table.cpp
      git -C ${SUBMODULE} apply --check ${PATCH}
  Nothing has been modified."
fi

git -C "${SUBMODULE}" apply "${PATCH}"
echo "apply.sh: applied ${PATCH##*/} to ${SUBMODULE_REL}."
git -C "${SUBMODULE}" diff --stat -- hls/toe/rx_sar_table/rx_sar_table.cpp
