#!/usr/bin/env bash
#
# Re-apply the out-of-tree TOE patches (0001 receive-window clamp, 0002 seeded ephemeral-port
# cursor, 0007 receive buffer in card memory) to the nested network submodule.
#
# Idempotent: run it as often as you like. It never resets, stashes or reverts anything --
# every check is a dry run (`git apply --check`, or a throw-away index), so a working tree that
# already carries a patch is left exactly as it is. 0001 and 0002 touch disjoint files and apply in
# either order; 0007 rewrites lines 0001 added (rx_sar_table.cpp) and goes on top of both.
# 0006 (StreamProfiler input register) goes to parcore/libstf instead of the network submodule.
#
# See README.md in this directory for what the clamp does and why it lives here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SUBMODULE_REL="parcore/libstf/coyote/hw/services/network"
SUBMODULE="${REPO_ROOT}/${SUBMODULE_REL}"

PATCHES=(
    "${SCRIPT_DIR}/0001-toe-rx-window-clamp.patch"
    "${SCRIPT_DIR}/0002-toe-seed-ephemeral-port-cursor.patch"
    "${SCRIPT_DIR}/0007-toe-rx-ddr-buffer.patch"
)
LIBSTF_REL="parcore/libstf"
LIBSTF="${REPO_ROOT}/${LIBSTF_REL}"
LIBSTF_PATCHES=(
    "${SCRIPT_DIR}/0006-libstf-stream-profiler-input-register.patch"
)
BUNDLE="${SCRIPT_DIR}/oasis-cmake-defined-guard.bundle"

EXPECTED_SHA="e9edcc4b2b48b161b17cd60148515130ebeed66a"
EXPECTED_BRANCH="oasis/cmake-defined-guard"

die() { echo "apply.sh: ERROR: $*" >&2; exit 1; }

# --- the submodule has to be there at all -----------------------------------------------------
[ -d "${SUBMODULE}" ] || die "submodule not found at ${SUBMODULE}
  Run 'git submodule update --init --recursive' from ${REPO_ROOT} first."

git -C "${SUBMODULE}" rev-parse --git-dir >/dev/null 2>&1 \
  || die "${SUBMODULE} is not a git repository (submodule not initialised?)"

for PATCH in "${PATCHES[@]}"; do
    [ -f "${PATCH}" ] || die "patch not found: ${PATCH}"
done

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

# --- (b) how much of the list is in the tree already, as a stack ----------------------------------
# A later patch may rewrite lines an earlier one added (0007 does, in 0001's rx_sar_table.cpp hunk);
# then the earlier patch no longer reverse-applies on its own even though it is in the tree. So first
# find the longest applied PREFIX: rebuild HEAD + patches 1..k in a throw-away index (the real index
# and the working tree are not touched) and compare it with the working tree, for k = all .. 1.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
PATCH_FILES=()
while IFS= read -r f; do PATCH_FILES+=("$f"); done < <(
    for PATCH in "${PATCHES[@]}"; do git -C "${SUBMODULE}" apply --numstat "${PATCH}" | cut -f3; done | sort -u)
APPLIED_PREFIX=0
for ((k = ${#PATCHES[@]}; k > 0; k--)); do
    export GIT_INDEX_FILE="${TMP_DIR}/index"
    rm -f "${GIT_INDEX_FILE}"
    ok=1
    git -C "${SUBMODULE}" read-tree HEAD || ok=0
    for ((j = 0; j < k && ok; j++)); do
        git -C "${SUBMODULE}" apply --cached "${PATCHES[j]}" >/dev/null 2>&1 || ok=0
    done
    if [ "${ok}" = 1 ] && git -C "${SUBMODULE}" diff --quiet -- "${PATCH_FILES[@]}"; then
        APPLIED_PREFIX=$k
    fi
    unset GIT_INDEX_FILE
    [ "${APPLIED_PREFIX}" = 0 ] || break
done

# --- (c) per patch: already applied -> skip; applies cleanly -> apply; otherwise stop ------------
for ((i = 0; i < ${#PATCHES[@]}; i++)); do
    PATCH="${PATCHES[i]}"
    NAME="${PATCH##*/}"
    if [ "${i}" -lt "${APPLIED_PREFIX}" ] || git -C "${SUBMODULE}" apply --check --reverse "${PATCH}" >/dev/null 2>&1; then
        echo "apply.sh: ${NAME} already applied to ${SUBMODULE_REL} -- nothing to do."
        continue
    fi

    if ! git -C "${SUBMODULE}" apply --check "${PATCH}" >/dev/null 2>&1; then
        die "${NAME} neither applies nor is already applied to ${SUBMODULE_REL}.
  The working tree is in some third state -- inspect it by hand:
      git -C ${SUBMODULE_REL} diff --stat
      git -C ${SUBMODULE} apply --check ${PATCH}
  Patches before this one in the list may have been applied; nothing else has been modified."
    fi

    git -C "${SUBMODULE}" apply "${PATCH}"
    echo "apply.sh: applied ${NAME} to ${SUBMODULE_REL}."
done
git -C "${SUBMODULE}" diff --stat

# --- libstf patches (0006): same per-patch logic against parcore/libstf -------------------------
git -C "${LIBSTF}" rev-parse --git-dir >/dev/null 2>&1 || die "${LIBSTF} is not a git repository"
for PATCH in "${LIBSTF_PATCHES[@]}"; do
    NAME="${PATCH##*/}"
    [ -f "${PATCH}" ] || die "patch not found: ${PATCH}"
    if git -C "${LIBSTF}" apply --check --reverse "${PATCH}" >/dev/null 2>&1; then
        echo "apply.sh: ${NAME} already applied to ${LIBSTF_REL} -- nothing to do."
        continue
    fi
    git -C "${LIBSTF}" apply --check "${PATCH}" >/dev/null 2>&1 \
      || die "${NAME} neither applies nor is already applied to ${LIBSTF_REL} (expected HEAD 31d98eb)."
    git -C "${LIBSTF}" apply "${PATCH}"
    echo "apply.sh: applied ${NAME} to ${LIBSTF_REL}."
done
git -C "${LIBSTF}" diff --stat -- hardware/src/hdl/util
