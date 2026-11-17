#!/bin/bash
# push-guard: PreToolUse hook (v6). Blocks, per `git push` in a managed repo: force / delete (unless
# hooks.pushGuard.allowForce), a push to the repo's default branch, a t/<n>-... push with no claim, and a push
# of a t/<n>-... branch while issue <n> carries `needs-ack`.
# Rules: (1) no DEVFW_CORE_DIR, or no `push` in the command -> allow. Scope, with no network and nothing that
# can fail: a parsed push whose remote (the push's, else the branch's upstream remote, else origin) has a raw
# URL naming a managed repo; an opaque segment mentioning push is in scope when HOOK_CWD is managed. RESIDUAL,
# accepted: an opaque command run from an unmanaged cwd that pushes elsewhere is not seen. A parser failure on
# a push-looking command blocks. (2) fail closed. (3) force/del blocks. (4) destination: the refspec's dst, or
# the current branch (HEAD / no refspec; detached blocks); refs/tags/* and other non-branch refs skip 5-7.
# (5) default branch blocks. (6) t/<n>-... needs `hook_claim_ok`. (7) the issue must not be `needs-ack`.
# Network calls (claim fetch, gh) are bounded by DEVFW_HOOK_NET_TIMEOUT (20s); a timeout blocks.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_v6-hook.sh"
hook_init push-guard
[ -n "$HOOK_CORE" ] || exit 0
[ "$HOOK_TOOL" = Bash ] || exit 0
CMD=$(hook_field .tool_input.command)
grep -Eiq '\bpush\b' <<<"$CMD" || exit 0

PARSED=$(node "$(devfw_path "$HOOK_LIB_DIR/../../bin/hook-parse")" <<<"$CMD" | tr -d '\r') || PARSED=""
if [ -z "$PARSED" ] || ! jq -e . >/dev/null 2>&1 <<<"$PARSED"; then
  hook_fail_closed
  hook_block "cannot read this push command exactly; write it as: git push <remote> <branch>"
fi

# _abs <path>: absolute against HOOK_CWD when relative.
_abs() {
  case "$1" in
    /*|[A-Za-z]:*|\*) printf '%s\n' "$1" ;;
    *) if [ -n "$HOOK_CWD" ]; then printf '%s/%s\n' "$HOOK_CWD" "$1"; else printf '%s\n' "$1"; fi ;;
  esac
}

# _resolve <push-json>: sets P_DIR, P_REMOTE, P_REPO (managed owner/name or empty). Returns 1 on any error.
_resolve() {
  local d r br
  d=$(jq -r '.dir // empty' <<<"$1" | tr -d '\r') || return 1
  r=$(jq -r '.remote // empty' <<<"$1" | tr -d '\r') || return 1
  if [ -n "$d" ]; then P_DIR=$(_abs "$d"); else P_DIR="${HOOK_CWD:-.}"; fi
  if [ -z "$r" ]; then
    br=$(git -C "$(devfw_path "$P_DIR")" symbolic-ref -q --short HEAD 2>/dev/null) || br=""
    [ -z "$br" ] || r=$(git -C "$(devfw_path "$P_DIR")" config --get "branch.$br.remote" 2>/dev/null) || r=""
    r="${r//$'\r'/}"
    { [ -n "$r" ] && [ "$r" != . ]; } || r=origin
  fi
  P_REMOTE="$r"
  P_REPO=$(hook_repo_for_remote "$P_DIR" "$r") || return 1
  P_REPO="${P_REPO//$'\r'/}"
}

# Scope pass.
INSCOPE=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if _resolve "$p"; then [ -z "$P_REPO" ] || INSCOPE+=("$p"); else INSCOPE+=("$p"); fi
done < <(jq -c '.pushes[]' <<<"$PARSED" | tr -d '\r')
OPAQUE_HIT=0
if [ "$(jq -r '[.opaque[] | select(test("push";"i"))] | length' <<<"$PARSED" | tr -d '\r')" -gt 0 ]; then
  # R15 (mirrors R9): an opaque push is in scope when cwd is managed, a cd / -C argument is non-literal
  # (unknowable dir), or the command text names a managed repo's slug or URL.
  rc=0; orepo=$(hook_repo_of "${HOOK_CWD:-.}") || rc=1
  if [ "$rc" -ne 0 ] || [ -n "$orepo" ]; then OPAQUE_HIT=1; fi
  grep -Eq '(^|[;&|({[:space:]])cd[[:space:]]+[^;&|]*[$`(]' <<<"$CMD" && OPAQUE_HIT=1
  grep -Eq '(^|[[:space:]])-C[[:space:]]*[^;&|[:space:]]*[$`(]' <<<"$CMD" && OPAQUE_HIT=1
  rc=0; mrepos=$(hook_managed_repos) || rc=1
  if [ "$rc" -ne 0 ]; then OPAQUE_HIT=1; fi
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if [[ "${CMD,,}" == *"${m,,}"* ]]; then OPAQUE_HIT=1; fi
  done <<<"$mrepos"
fi
[ "${#INSCOPE[@]}" -gt 0 ] || [ "$OPAQUE_HIT" -eq 1 ] || exit 0

hook_fail_closed
[ "$OPAQUE_HIT" -eq 0 ] || hook_block "cannot read this push command exactly; write it as: git push <remote> <branch>"

PLAN_REPO=$(hook_cfg '.plan.repo') || hook_block "cannot read the config; not allowing a push"
ALLOW_FORCE=$(hook_cfg '.hooks.pushGuard.allowForce' false) || hook_block "cannot read the config; not allowing a push"
NET="${DEVFW_HOOK_NET_TIMEOUT:-20}"
export HOOK_NET_TIMEOUT="$NET"

_default_of() {  # _default_of <owner/name>: that repo's default branch (config), else main
  local d
  # the slug reaches jq through the environment ($ENV), never spliced into the filter text
  d=$(HOOK_SLUG="${1,,}" hook_cfg '[(.repos // {}) | .[] | select((.github // "") | ascii_downcase == $ENV.HOOK_SLUG) | .default][0], .plan.default' 2>/dev/null | head -1) || d=""
  printf '%s\n' "${d:-main}"
}

_current_branch() {
  git -C "$(devfw_path "$1")" symbolic-ref -q --short HEAD 2>/dev/null | tr -d '\r'
}

# _bare_dst <dir> <remote>: the branch a push with NO refspec updates, honouring push.default. Prints it, or
# blocks when it cannot be known. simple / current / unset -> the current branch. Sets BARE_DST (never call it
# inside $( ... ): hook_block must exit the hook).
_bare_dst() {
  local d br mode merge
  d=$(devfw_path "$1")
  br=$(_current_branch "$1") || br=""
  [ -n "$br" ] || hook_block "cannot tell what this push updates"
  if git -C "$d" config --get-all "remote.$2.push" >/dev/null 2>&1; then
    hook_block "cannot tell what this push updates; name the refspec"
  fi
  mode=$(git -C "$d" config --get push.default 2>/dev/null | tr -d '\r') || mode=""
  case "$mode" in
    matching) hook_block "cannot tell what this push updates; name the refspec" ;;
    upstream|tracking)
      merge=$(git -C "$d" config --get "branch.$br.merge" 2>/dev/null | tr -d '\r') || merge=""
      merge="${merge#refs/heads/}"
      [ -n "$merge" ] || hook_block "cannot tell what this push updates; name the refspec"
      BARE_DST="$merge" ;;
    *) BARE_DST="$br" ;;
  esac
}

_check_dst() {  # _check_dst <dir> <repo> <dst-branch> <remote>
  local dir="$1" repo="$2" b="$3" def n rc=0 out lab
  def=$(_default_of "$repo")
  [ "${b,,}" != "${def,,}" ] || hook_block "merge to $def goes through the merge gate, not a push"
  [[ "$b" =~ ^t/([1-9][0-9]*)- ]] || return 0
  n="${BASH_REMATCH[1]}"
  hook_claim_ok "$dir" "$b" "$4" || rc=$?
  [ "$rc" -ne 3 ] || hook_block "no claim for issue $n; run bin/claim first"
  [ "$rc" -eq 0 ] || hook_block "cannot verify the claim (fetch failed)"
  rc=0
  [ -n "$PLAN_REPO" ] || hook_block "cannot read issue $n"
  out=$(timeout "$NET" gh api "repos/$PLAN_REPO/issues/$n" 2>/dev/null) || rc=$?
  out="${out//$'\r'/}"
  [ "$rc" -eq 0 ] || hook_block "cannot read issue $n"
  lab=$(jq -r '[.labels[]?.name] | join("\n")' <<<"$out" 2>/dev/null | tr -d '\r') || hook_block "cannot read issue $n"
  if grep -qx 'needs-ack' <<<"$lab"; then
    hook_block "issue $n needs-ack: acknowledge the plan change (ack $n <plan-sha>: …) before pushing"
  fi
}

for p in "${INSCOPE[@]}"; do
  _resolve "$p" || hook_block "cannot resolve this push's repository"
  [ -n "$P_REPO" ] || continue
  force=$(jq -r '.force' <<<"$p" | tr -d '\r'); del=$(jq -r '.del' <<<"$p" | tr -d '\r')
  if [ "$force" = true ] || [ "$del" = true ]; then
    [ "$ALLOW_FORCE" = true ] || hook_block "force-push and remote branch deletion are off (hooks.pushGuard.allowForce)"
  fi
  mapfile -t specs < <(jq -r '.refspecs[]' <<<"$p" | tr -d '\r')
  if [ "${#specs[@]}" -eq 0 ]; then _bare_dst "$P_DIR" "$P_REMOTE"; specs=("$BARE_DST"); fi
  for s in "${specs[@]}"; do
    s="${s#+}"
    if [[ "$s" == *:* ]]; then dst="${s#*:}"; else dst="$s"; fi
    [ -n "$dst" ] || hook_block "cannot tell what this push updates"
    if [ "$dst" = HEAD ]; then   # HEAD names the current branch, whatever push.default says
      dst=$(_current_branch "$P_DIR") || dst=""
      [ -n "$dst" ] || hook_block "cannot tell what this push updates"
    fi
    case "$dst" in
      refs/tags/*) continue ;;
      refs/heads/*) dst="${dst#refs/heads/}" ;;
      refs/*) hook_block "unsupported destination $dst; push a branch or a tag" ;;
    esac
    case "$dst" in *\**|*\?*) hook_block "cannot tell what this push updates" ;; esac
    _check_dst "$P_DIR" "$P_REPO" "$dst" "$P_REMOTE"
  done
done
exit 0
