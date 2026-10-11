#!/usr/bin/env bash
# autosave.sh - periodically snapshot oasis and celeris onto their remote branches.
#
# Every AUTOSAVE_INTERVAL seconds, for celeris and then oasis:
#   1. stage everything (git add -A), except files above AUTOSAVE_MAX_MB.
#      Submodules (parcore, coyote, libstf, celeris-in-oasis, ...) are ignored:
#      neither their content nor their pointers are ever auto-committed.
#   2. nothing staged -> abort (but retry a push that failed earlier)
#   3. HEAD is a previous autosave commit -> amend it (unless origin already has
#      commits on top of it), otherwise add a new commit
#   4. fetch origin/<branch> and merge it in, so we never overwrite what someone
#      else pushed. Any error or conflict aborts the merge and skips the push
#      (the commit stays local; it is retried on the next tick).
#   5. git push --force-with-lease the branch
#
# Usage:  scripts/autosave.sh           # loop forever; run under nohup/tmux
#         scripts/autosave.sh --once    # single pass, e.g. from cron
#
# Each repo is only ever touched while it is on its own branch (see the constants
# below): celeris on measure-bloom, oasis on measure-bloom-oasis. In any other
# state (other branch, detached HEAD) that repo is logged and skipped, and it
# resumes by itself once the branch is checked out again. Both are pushed.
#
# Env: AUTOSAVE_INTERVAL (seconds, 600)   AUTOSAVE_MAX_MB (5)
#      AUTOSAVE_LOG (<oasis>/autosave.log, covered by .gitignore's *.log)

MAGIC='[oasis-autosave]'
CELERIS_BRANCH=measure-bloom
OASIS_BRANCH=measure-bloom-oasis

log() { printf '%s %-8s %s\n' "$(date '+%F %T')" "$1" "${*:2}" >> "$LOG"; }

# Print a repo's git dir as an absolute path (submodules keep it under oasis/.git/modules).
gitdir() { git -C "$1" rev-parse --absolute-git-dir; }

# True if a non-autosave commit anywhere in oasis already records celeris at $2.
# Amending that celeris commit would leave such a commit pointing at a SHA that
# no longer exists on the remote.
referenced_by_manual_commit() {
  local sub=$1 sha=$2 c subj
  while read -r c subj; do
    [[ $subj == "$MAGIC"* ]] && continue
    [[ $(git -C "$OASIS" rev-parse -q --verify "$c:$sub" 2>/dev/null) == "$sha" ]] && return 0
  done < <(git -C "$OASIS" log --all -n 300 --format='%H %s')
  return 1
}

# Drop from the index what must not be auto-committed: oversized files (GitHub
# rejects > 100 MB, and a pushed blob stays in history even after deletion) and
# newly appearing embedded repos.
unstage_oversized() {
  local repo=$1 name meta path om nm os ns st size
  name=$(basename "$repo")
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r om nm os ns st <<<"${meta#:}"
    if [[ $nm == 160000 ]]; then   # a repo that is not a registered submodule yet
      [[ $om == 000000 ]] && git -C "$repo" reset -q -- "$path"
      continue
    fi
    [[ $st == D ]] && continue
    size=$(git -C "$repo" cat-file -s "$ns")
    if (( size > MAX_BYTES )); then
      git -C "$repo" reset -q -- "$path"
      log "$name" "SKIP $path: $((size / 1048576)) MB exceeds ${MAX_MB} MB limit"
    fi
  done < <(git -C "$repo" diff --cached --raw -z --no-renames)
}

# Run a git command that talks to the remote. Never prompt (no tty in the
# background) and never hang on a dead connection. Output is stdout+stderr.
remote_git() {  # remote_git <repo> <git args...>
  local repo=$1 ssh
  shift
  ssh=$(git -C "$repo" config --get core.sshCommand || echo ssh)
  LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$ssh -o BatchMode=yes -o ConnectTimeout=20" \
    timeout 120 git -C "$repo" "$@" 2>&1
}

# Refresh refs/remotes/origin/<branch>. Non-zero only on a real failure: a
# branch that was never pushed is not an error.
fetch_remote() {  # fetch_remote <repo> <branch>
  local repo=$1 branch=$2 name out rc
  name=$(basename "$repo")
  out=$(remote_git "$repo" fetch --no-recurse-submodules origin \
        "+refs/heads/$branch:refs/remotes/origin/$branch")
  rc=$?
  (( rc == 0 )) && return 0
  [[ $out == *"couldn't find remote ref"* ]] && return 0
  log "$name" "FETCH FAILED rc=$rc: $(tr '\n' ' ' <<<"$out" | cut -c1-300)"
  return $rc
}

# Merge the fetched origin/<branch> into HEAD so the push below cannot clobber
# work pushed from elsewhere. On any error or conflict the merge is aborted and
# non-zero is returned; the caller then does not push.
merge_remote() {  # merge_remote <repo> <branch>
  local repo=$1 branch=$2 name out rc gd remote
  local g=(git -C "$repo" -c commit.gpgsign=false)
  name=$(basename "$repo"); gd=$(gitdir "$repo")

  remote=$("${g[@]}" rev-parse -q --verify "refs/remotes/origin/$branch") || return 0
  # Already in HEAD: the push is a plain fast-forward.
  "${g[@]}" merge-base --is-ancestor "$remote" HEAD && return 0
  # A commit we made ourselves and have since amended away (our previous
  # autosave) is meant to be replaced, not merged. Anything not in our reflog
  # was pushed by somebody else.
  "${g[@]}" log -g --format=%H -n 1000 HEAD | grep -qx "$remote" && return 0

  out=$("${g[@]}" merge -q --no-edit --no-verify \
        -m "$MAGIC $(date '+%F %T') merge origin/$branch" "$remote" 2>&1)
  rc=$?
  if (( rc != 0 )); then
    if [[ -e $gd/MERGE_HEAD ]]; then
      "${g[@]}" merge --abort || log "$name" "ERROR merge --abort failed, resolve by hand"
    fi
    log "$name" "MERGE FAILED rc=$rc, aborted, not pushing: $(tr '\n' ' ' <<<"$out" | cut -c1-300)"
    return $rc
  fi
  log "$name" "merged origin/$branch -> $("${g[@]}" rev-parse --short HEAD)"
}

push() {  # push <repo> <branch>
  local repo=$1 branch=$2 name out rc
  name=$(basename "$repo")
  merge_remote "$repo" "$branch" || return
  out=$(remote_git "$repo" push --force-with-lease --no-verify \
        origin "HEAD:refs/heads/$branch")
  rc=$?
  if (( rc == 0 )); then
    log "$name" "pushed $branch @ $(git -C "$repo" rev-parse --short HEAD)"
  else
    log "$name" "PUSH FAILED rc=$rc: $(tr '\n' ' ' <<<"$out" | cut -c1-300)"
  fi
  return $rc
}

snapshot() {  # snapshot <repo>
  local repo=$1 name want branch gd p subj head amend=0 msg out
  name=$(basename "$repo"); want=${WANT[$repo]}
  local g=(git -C "$repo" -c commit.gpgsign=false)

  branch=$("${g[@]}" symbolic-ref -q --short HEAD) \
    || { log "$name" "SKIP detached HEAD"; return; }
  [[ $branch == "$want" ]] \
    || { log "$name" "SKIP on '$branch', only '$want' is autosaved"; return; }

  # Don't fight the user: skip while they are mid-rebase/merge/etc. or git is locked.
  gd=$(gitdir "$repo")
  for p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG index.lock; do
    [[ -e $gd/$p ]] && { log "$name" "SKIP $p present"; return; }
  done

  # Never stage submodules: leave every tracked gitlink out of the pathspec.
  local ex=() ent
  while IFS= read -r -d '' ent; do
    [[ $ent == 160000* ]] && ex+=(":(exclude,literal)${ent#*$'\t'}")
  done < <("${g[@]}" ls-files -z --stage)
  out=$("${g[@]}" add -A -- . "${ex[@]}" 2>&1) \
    || { log "$name" "ERROR git add failed: $out"; return; }
  unstage_oversized "$repo"

  subj=$("${g[@]}" log -1 --format=%s 2>/dev/null)
  head=$("${g[@]}" rev-parse HEAD)

  if "${g[@]}" diff --cached --quiet; then
    # Nothing to commit. Only retry a push that an earlier tick left behind.
    if [[ $subj == "$MAGIC"* && $head != "$("${g[@]}" rev-parse -q --verify "origin/$branch")" ]]; then
      log "$name" "no changes, retrying unpushed autosave commit"
      push "$repo" "$branch"
    else
      log "$name" "no changes @ ${head:0:7}"
    fi
    return
  fi

  fetch_remote "$repo" "$branch"; fetched=$?

  # Amend only a previous autosave commit that nobody else can depend on.
  if [[ $subj == "$MAGIC"* ]]; then
    amend=1
    for ref in origin/main origin/master; do   # already merged -> don't rewrite it
      "${g[@]}" merge-base --is-ancestor HEAD "$ref" 2>/dev/null && amend=0
    done
    if (( amend )) && [[ $repo != "$OASIS" ]] \
       && referenced_by_manual_commit "${repo#"$OASIS"/}" "$head"; then
      amend=0
    fi
    # Somebody pushed on top of it: keep it, so merging their work has it as base.
    if (( amend && fetched == 0 )); then
      remote=$("${g[@]}" rev-parse -q --verify "refs/remotes/origin/$branch")
      [[ -n $remote && $remote != "$head" ]] \
        && "${g[@]}" merge-base --is-ancestor HEAD "$remote" && amend=0
    fi
  fi

  msg="$MAGIC $(date '+%F %T')"
  if (( amend )); then
    out=$("${g[@]}" commit -q --no-verify --amend --date=now -m "$msg" 2>&1) \
      || { log "$name" "ERROR amend failed: $out"; return; }
    log "$name" "amended -> $("${g[@]}" rev-parse --short HEAD) ($("${g[@]}" diff --cached --shortstat HEAD~1 2>/dev/null | xargs))"
  else
    out=$("${g[@]}" commit -q --no-verify -m "$msg" 2>&1) \
      || { log "$name" "ERROR commit failed: $out"; return; }
    log "$name" "committed $("${g[@]}" rev-parse --short HEAD)"
  fi
  (( fetched == 0 )) && push "$repo" "$branch"
}

main() {
  local once=0 script_dir r
  [[ ${1:-} == --once ]] && once=1

  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  OASIS=$(git -C "$script_dir" rev-parse --show-toplevel) || exit 1
  LOG=${AUTOSAVE_LOG:-$OASIS/autosave.log}
  INTERVAL=${AUTOSAVE_INTERVAL:-600}
  MAX_MB=${AUTOSAVE_MAX_MB:-5}
  MAX_BYTES=$((MAX_MB * 1048576))
  REPOS=("$OASIS/celeris" "$OASIS")
  declare -gA WANT
  WANT[$OASIS/celeris]=$CELERIS_BRANCH
  WANT[$OASIS]=$OASIS_BRANCH

  exec >>"$LOG" 2>&1                         # stray errors end up in the log too
  # PID file rather than flock: child processes (sleep, a detached `git gc`)
  # would inherit a lock fd and keep the lock after this script is stopped.
  PIDFILE=$(gitdir "$OASIS")/autosave.pid
  if [[ -r $PIDFILE ]] && grep -qs autosave.sh "/proc/$(<"$PIDFILE")/cmdline"; then
    log main "already running as pid $(<"$PIDFILE"), exiting"; exit 1
  fi
  echo $$ > "$PIDFILE"
  trap 'rm -f "$PIDFILE"' EXIT

  log main "started pid=$$ interval=${INTERVAL}s" \
    "celeris->$CELERIS_BRANCH (now: $(git -C "$OASIS/celeris" branch --show-current))" \
    "oasis->$OASIS_BRANCH (now: $(git -C "$OASIS" branch --show-current))"
  trap 'log main "stopped"; exit 0' INT TERM   # runs EXIT trap, removes PID file

  while :; do
    for r in "${REPOS[@]}"; do snapshot "$r"; done
    (( once )) && exit 0
    sleep "$INTERVAL" & wait $!              # lets the trap fire immediately
  done
}

# Everything lives in main() and we exit before bash reads past this line, so
# editing or checking out a different version of this file while it runs is safe.
main "$@"
exit $?
