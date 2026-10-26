#!/usr/bin/env bash
#
# Put the nested submodules on the commits the design is built from and apply the patches in this
# directory (README.md has the table of what each one changes).
#
# A recursive clone checks out parcore b3879a0 -> libstf 7afc162 -> Coyote 590af08 (master) ->
# network 1197a9d. The design needs Coyote's dev/tcp branch, so this script checks out
# parcore/libstf/coyote at 003c7344 and its network submodule at 20633d0 (the commit 003c7344
# pins), and then applies
#     parcore  0012
#     libstf   0006 0013
#     Coyote   0010 0011
#     network  0009 0001 0002
#
# Idempotent: a submodule already on its base stays there and a patch already in the tree is
# reported as applied. It never resets, stashes or reverts anything. It stops on a submodule that
# sits on any other commit, on a checkout it would have to make over local changes, and on a patch
# that neither applies nor is already applied.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PARCORE=parcore
LIBSTF=parcore/libstf
COYOTE=parcore/libstf/coyote
NETWORK=parcore/libstf/coyote/hw/services/network

PARCORE_BASE=b3879a07fddb5505901cc3bbed4923ab5b4d1811   # pinned by this repository
LIBSTF_BASE=7afc162a27558eb2ff99f7f03419de7aa08ed46a    # pinned by parcore
COYOTE_PIN=590af082ab70faaba4dd258455d5677c866b63b5     # pinned by libstf (master)
COYOTE_BASE=003c734429605651d4ccdd93414dcc807dbb40af    # on dev/tcp
COYOTE_BRANCH=dev/tcp
NETWORK_PIN=1197a9dfa172b34c50ad5ee0a418a53fdddff146    # pinned by Coyote 590af08
NETWORK_BASE=20633d038e0e2b371d14d716a3fe21914283e99b   # pinned by Coyote 003c7344
NETWORK_BRANCH=coyote-TCP-RDMA

die() { echo "apply.sh: ERROR: $*" >&2; exit 1; }

in_sm() { local sm=$1; shift; git -C "${REPO_ROOT}/${sm}" "$@"; }

head_of() {
    local top
    top="$(in_sm "$1" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "${top}" ] && [ "${top}" -ef "${REPO_ROOT}/$1" ] \
        || die "$1 is not checked out. Run 'git submodule update --init --recursive' from ${REPO_ROOT} first."
    in_sm "$1" rev-parse HEAD
}

# on_base <path> <base>: the submodule must sit on <base>
on_base() {
    local sm=$1 base=$2 head
    head="$(head_of "${sm}")"
    [ "${head}" = "${base}" ] || die "${sm} is on ${head}, expected ${base}.
  Run 'git submodule update --init --recursive' from ${REPO_ROOT}, then this script again."
}

# movable <path> <pin> <base> <branch>: on <base> already, or on <pin> without local changes
movable() {
    local sm=$1 pin=$2 base=$3 branch=$4 head
    head="$(head_of "${sm}")"
    [ "${head}" = "${base}" ] && return 0
    [ "${head}" = "${pin}" ] || die "${sm} is on ${head}, expected ${pin} (as cloned) or ${base} (${branch}).
  Run 'git submodule update --init --recursive' from ${REPO_ROOT}, then this script again."
    in_sm "${sm}" diff --quiet --ignore-submodules=all HEAD -- \
        || die "${sm} has local changes on ${pin}; not checking out ${base} over them."
}

# move <path> <base> <branch>: check out <base>, fetching <branch> first if the commit is missing
move() {
    local sm=$1 base=$2 branch=$3
    if [ "$(head_of "${sm}")" = "${base}" ]; then
        echo "apply.sh: ${sm} is on ${base:0:8} (${branch})."
        return 0
    fi
    if ! in_sm "${sm}" cat-file -e "${base}^{commit}" 2>/dev/null; then
        in_sm "${sm}" fetch -q origin "${branch}" || die "cannot fetch ${branch} into ${sm}"
        in_sm "${sm}" cat-file -e "${base}^{commit}" 2>/dev/null \
            || die "${base} is not on ${branch} of ${sm}'s origin"
    fi
    in_sm "${sm}" -c advice.detachedHead=false -c submodule.recurse=false checkout -q --detach "${base}"
    echo "apply.sh: ${sm} checked out at ${base:0:8} (${branch})."
}

# apply_in <path> <patch>...: already applied -> skip; applies cleanly -> apply; otherwise stop
apply_in() {
    local sm=$1 p; shift
    for p in "$@"; do
        [ -f "${SCRIPT_DIR}/${p}" ] || die "patch not found: ${SCRIPT_DIR}/${p}"
        if in_sm "${sm}" apply --check --reverse --whitespace=nowarn "${SCRIPT_DIR}/${p}" >/dev/null 2>&1; then
            echo "apply.sh: ${p} already applied to ${sm} -- nothing to do."
        elif in_sm "${sm}" apply --check --whitespace=nowarn "${SCRIPT_DIR}/${p}" >/dev/null 2>&1; then
            in_sm "${sm}" apply --whitespace=nowarn "${SCRIPT_DIR}/${p}"
            echo "apply.sh: applied ${p} to ${sm}."
        else
            die "${p} neither applies nor is already applied to ${sm}.
  Inspect it with: git -C ${sm} diff --stat; git -C ${sm} apply --check ${SCRIPT_DIR}/${p}"
        fi
    done
}

# every check first, so that a refusal changes nothing
on_base "${PARCORE}" "${PARCORE_BASE}"
on_base "${LIBSTF}" "${LIBSTF_BASE}"
movable "${COYOTE}" "${COYOTE_PIN}" "${COYOTE_BASE}" "${COYOTE_BRANCH}"
movable "${NETWORK}" "${NETWORK_PIN}" "${NETWORK_BASE}" "${NETWORK_BRANCH}"

move "${COYOTE}" "${COYOTE_BASE}" "${COYOTE_BRANCH}"
move "${NETWORK}" "${NETWORK_BASE}" "${NETWORK_BRANCH}"

apply_in "${PARCORE}" 0012-parcore-decoder-value-count-once.patch
apply_in "${LIBSTF}"  0006-libstf-stream-profiler-input-register.patch 0013-libstf-huge-page-cap.patch
apply_in "${COYOTE}"  0010-coyote-tcp-management-ports.patch 0011-coyote-rx-buffer-fifo-1mib.patch
apply_in "${NETWORK}" 0009-toe-window-1mib.patch 0001-toe-rx-window-clamp.patch 0002-toe-seed-ephemeral-port-cursor.patch

for sm in "${PARCORE}" "${LIBSTF}" "${COYOTE}" "${NETWORK}"; do
    echo "apply.sh: ${sm} @ $(in_sm "${sm}" rev-parse --short=8 HEAD):$(in_sm "${sm}" diff --shortstat --ignore-submodules=all)"
done
