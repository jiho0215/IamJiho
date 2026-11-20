#!/bin/bash
# bin/git-hooks install | verify: the content-addressed hook dir, its manifest, and every verify reason.
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS DEVFW_SESSION_ID DEVFW_CONFIG DEVFW_CORE_DIR CDPATH
for v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_'); do unset "$v"; done
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_fixture.sh"

inst() {  # inst <state-dir> [extra args...]: install from the real plugin; sets IRC, IOUT, IERR, IDIR
  local s="$1"; shift
  IRC=0
  "$GITHOOKS" install --core-dir "$CORE" --state-dir "$s" "$@" >"$TMP/.iout" 2>"$TMP/.ierr" || IRC=$?
  IOUT=$(tr -d '\r' < "$TMP/.iout"); IERR=$(tr -d '\r' < "$TMP/.ierr")
  IDIR=$(jq -r '.dir // empty' <<<"$IOUT" 2>/dev/null | tr -d '\r')
}
ver() {  # ver <dir>: sets VRC and VREASON
  VRC=0
  VOUT=$("$GITHOOKS" verify --dir "$1" 2>"$TMP/.verr") || VRC=$?
  VREASON=$(jq -r '.reason // empty' <<<"$VOUT" 2>/dev/null | tr -d '\r')
}
want_reason() {  # want_reason <name> <reason>
  [ "$VRC" -eq 5 ] && [ "$VREASON" = "$2" ] && return 0
  fail "$1: verify rc=$VRC reason '$VREASON', want 5 '$2'"; return 1
}
plugin_copy() {  # plugin_copy <dest>: the files a hook dir runs, copied from the real plugin
  mkdir -p "$1/hooks" && cp -r "$PLUGIN/bin" "$1/bin" && cp -r "$PLUGIN/hooks/git" "$1/hooks/git"
}

# in_same_inputs_same_dir
inst "$TMP/s1"; J1="$IOUT"; R1=$IRC
inst "$TMP/s1"; J2="$IOUT"
if [ "$R1" -eq 0 ] && [ "$IRC" -eq 0 ] && [ -n "$J1" ] && [ "$J1" = "$J2" ] \
   && [[ "$(jq -r .hash <<<"$J1" | tr -d '\r')" =~ ^[0-9a-f]{16}$ ]] \
   && [ "$(jq -r .hash <<<"$J1" | tr -d '\r')" = "$(basename "$IDIR")" ]; then ok in_same_inputs_same_dir
else fail "in_same_inputs_same_dir: '$J1' vs '$J2' (rc $R1/$IRC, $IERR)"; fi
[ "$(ls -A "$TMP/s1/git-hooks" | wc -l)" -eq 1 ] || fail "in_same_inputs_same_dir: git-hooks/ holds $(ls -A "$TMP/s1/git-hooks")"

# in_absolute_lf
r=0
[[ "$HK" =~ ^([A-Za-z]:)?/ ]] || { fail "in_absolute_lf: dir not absolute: $HK"; r=1; }
for f in pre-push reference-transaction pre-commit plugin-root scope.env managed.tsv manifest; do
  [ -f "$HK/$f" ] || { fail "in_absolute_lf: $f missing"; r=1; continue; }
  ! grep -q $'\r' "$HK/$f" || { fail "in_absolute_lf: $f has a CR"; r=1; }
done
for f in pre-push reference-transaction pre-commit; do
  [ -x "$HK/$f" ] || { fail "in_absolute_lf: $f is not executable"; r=1; }
  [ "$(head -1 "$HK/$f")" = '#!/bin/bash' ] || { fail "in_absolute_lf: $f first line"; r=1; }
  # the shim sources the dispatcher into its own bash process (Task 5b: one process per hook run, not sh + bash)
  grep -qx ". \"\$r/hooks/git/dispatch.sh\" $f \"\$d\" \"\$@\"" "$HK/$f" || { fail "in_absolute_lf: $f source line"; r=1; }
  cmp -s "$HK/$f" "$PLUGIN/hooks/git/$f" || { fail "in_absolute_lf: $f differs from the plugin template"; r=1; }
  [ "$(sed "s/ $f / NAME /" "$PLUGIN/hooks/git/$f")" = "$(sed "s/ pre-push / NAME /" "$PLUGIN/hooks/git/pre-push")" ] \
    || { fail "in_absolute_lf: template $f differs from pre-push by more than the name"; r=1; }
done
[[ "$(cat "$HK/plugin-root")" =~ ^([A-Za-z]:)?/ ]] || { fail "in_absolute_lf: plugin-root not absolute"; r=1; }
[ "$r" -eq 1 ] || ok in_absolute_lf

# in_scope_env_exact: the fixed keys, absolute values, defaults
WANT_ENV="DEVFW_HK_CORE=$(mp "$CORE")
DEVFW_HK_CONFIG=$(mp "$CORE")/orchestrator.json
DEVFW_HK_CONFIG_HASH=$(git hash-object --no-filters "$(mp "$CORE/orchestrator.json")" | tr -d '\r')
DEVFW_HK_PLAN_REPO=acme/core
DEVFW_HK_PLAN_PATH=docs/plan
DEVFW_HK_PLAN_BRANCH=main
DEVFW_HK_ALLOW_FORCE=false
DEVFW_HK_STATE=$(mp "$TMP/state")
DEVFW_HK_BIN=$(mp "$PLUGIN")/bin"
[ "$(cat "$HK/scope.env")" = "$WANT_ENV" ] && ok in_scope_env_exact \
  || fail "in_scope_env_exact: got
$(cat "$HK/scope.env")
want
$WANT_ENV"
[ "$(cat "$HK/managed.tsv")" = "acme/core	main	squash
acme/api	main	squash" ] && ok in_managed_tsv_default || fail "in_managed_tsv_default: $(cat "$HK/managed.tsv")"

# in_managed_tsv_precedence: repos.<x>.default > plan.default > main; mergeMethod default squash; lowercase slugs;
# a plan repo also listed under repos is one line; config values flow into scope.env
printf '%s\n' '{"plan":{"repo":"Acme/Core","default":"trunk","path":"docs/p","branch":"plan"},
 "hooks":{"pushGuard":{"allowForce":true}},
 "repos":{"api":{"github":"Acme/API","default":"dev","mergeMethod":"rebase"},"web":{"github":"acme/web"},
          "core":{"github":"acme/core","mergeMethod":"merge"}}}' > "$TMP/cfg-prec.json"
inst "$TMP/s-prec" --config "$TMP/cfg-prec.json"
if [ "$IRC" -eq 0 ] && [ "$(cat "$IDIR/managed.tsv")" = "acme/api	dev	rebase
acme/web	trunk	squash
acme/core	trunk	merge" ] && grep -qx 'DEVFW_HK_PLAN_REPO=acme/core' "$IDIR/scope.env" \
   && grep -qx 'DEVFW_HK_PLAN_PATH=docs/p' "$IDIR/scope.env" && grep -qx 'DEVFW_HK_PLAN_BRANCH=plan' "$IDIR/scope.env" \
   && grep -qx 'DEVFW_HK_ALLOW_FORCE=true' "$IDIR/scope.env" \
   && grep -qx "DEVFW_HK_CONFIG=$(mp "$TMP/cfg-prec.json")" "$IDIR/scope.env"; then ok in_managed_tsv_precedence
else fail "in_managed_tsv_precedence: rc=$IRC $IERR; $(cat "$IDIR/managed.tsv" "$IDIR/scope.env" 2>&1)"; fi
printf '%s\n' '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api"}}}' > "$TMP/cfg-pd.json"
inst "$TMP/s-pd" --config "$TMP/cfg-pd.json"
[ "$IRC" -eq 0 ] && [ "$(cat "$IDIR/managed.tsv")" = "acme/core	main	squash
acme/api	main	squash" ] && ok in_managed_tsv_plan_line || fail "in_managed_tsv_plan_line: $(cat "$IDIR/managed.tsv" 2>&1)"

# in_verify_ok
ver "$HK"; [ "$VRC" -eq 0 ] && [ -z "$VOUT" ] && ok in_verify_ok || fail "in_verify_ok: rc=$VRC $VOUT"

# in_tamper_detected (and a re-install over the tampered dir refuses)
inst "$TMP/s-tamper"; T1="$IDIR"
printf x >> "$T1/pre-push"
ver "$T1"; want_reason in_tamper_detected "manifest mismatch: pre-push" && ok in_tamper_detected
inst "$TMP/s-tamper"
[ "$IRC" -eq 5 ] && grep -q "failed verify: manifest mismatch: pre-push" <<<"$IERR" && [ -z "$IOUT" ] \
  && ok in_install_over_tampered || fail "in_install_over_tampered: rc=$IRC out='$IOUT' err='$IERR'"

# in_manifest_rewritten: an edited shim whose manifest line was rewritten to match -> the dir name is no longer
# the content hash
inst "$TMP/s-man"; T2="$IDIR"
printf '\n# edited\n' >> "$T2/pre-commit"
NEW=$(git hash-object --no-filters "$(mp "$T2/pre-commit")" | tr -d '\r')
sed -i "s/^[0-9a-f]* pre-commit\$/$NEW pre-commit/" "$T2/manifest"
ver "$T2"; want_reason in_manifest_rewritten "manifest mismatch: manifest" && ok in_manifest_rewritten

# in_config_changed
cp "$CORE/orchestrator.json" "$TMP/orch.bak"
printf '%s\n' '{"plan":{"repo":"acme/core"},"repos":{}}' > "$CORE/orchestrator.json"
ver "$HK"; want_reason in_config_changed "config changed" && ok in_config_changed
cp "$TMP/orch.bak" "$CORE/orchestrator.json"
ver "$HK"; [ "$VRC" -eq 0 ] || fail "in_config_changed: restored config does not verify: $VREASON"

# in_verify_missing_dir
inst "$TMP/s-gone"; rm -rf "$IDIR"
ver "$IDIR"; want_reason in_verify_missing_dir "missing dir" && ok in_verify_missing_dir

# in_plugin_missing_blocks: plugin-root names a removed dir -> the shim blocks git work, loudly
inst "$TMP/s-noplug"; NP="$IDIR"
mkdir -p "$TMP/removed"; rm -rf "$TMP/removed"
printf '%s\n' "$(mp "$TMP/removed")" > "$NP/plugin-root"
HK="$NP" expect in_plugin_missing_blocks block "plugin not found" hk git -C "$W" push origin HEAD:refs/heads/t/41-x \
  && ok in_plugin_missing_blocks
ver "$NP"; want_reason in_verify_plugin_not_found "plugin not found" && ok in_verify_plugin_not_found

# in_plugin_file_changed: install from a scratch plugin copy, then edit the copy under the "running session"
plugin_copy "$TMP/plug"
"$TMP/plug/bin/git-hooks" install --core-dir "$CORE" --state-dir "$TMP/s-plug" >"$TMP/.iout" 2>"$TMP/.ierr" \
  || fail "in_plugin_file_changed: install from the copy: $(cat "$TMP/.ierr")"
PD=$(jq -r .dir < "$TMP/.iout" | tr -d '\r')
ver "$PD"; [ "$VRC" -eq 0 ] || fail "in_plugin_file_changed: fresh copy install does not verify: $VREASON"
printf '# edited under a running session\n' >> "$TMP/plug/hooks/git/_git-lib.sh"
ver "$PD"; want_reason in_plugin_file_changed "plugin changed since session start: hooks/git/_git-lib.sh" \
  && ok in_plugin_file_changed
# a new session from the edited plugin gets a NEW dir (the old one keeps telling the old session)
"$TMP/plug/bin/git-hooks" install --core-dir "$CORE" --state-dir "$TMP/s-plug" >"$TMP/.iout" 2>"$TMP/.ierr" \
  || fail "in_plugin_edit_new_dir: re-install: $(cat "$TMP/.ierr")"
PD2=$(jq -r .dir < "$TMP/.iout" | tr -d '\r')
[ -n "$PD2" ] && [ "$PD2" != "$PD" ] && [ -d "$PD" ] && ok in_plugin_edit_new_dir \
  || fail "in_plugin_edit_new_dir: '$PD2' vs '$PD'"
# in_plugin_rule_added: a rules file that appears after install is a plugin change too
mkdir -p "$TMP/plug/hooks/git/rules"; printf 'gk_pre_push() { return 0; }\n' > "$TMP/plug/hooks/git/rules/pre-push.sh"
ver "$PD2"; want_reason in_plugin_rule_added "plugin changed since session start: hooks/git/rules/pre-push.sh" \
  && ok in_plugin_rule_added
# ...and an install that includes it lists it in the manifest
"$TMP/plug/bin/git-hooks" install --core-dir "$CORE" --state-dir "$TMP/s-plug" >"$TMP/.iout" 2>"$TMP/.ierr"
PD3=$(jq -r .dir < "$TMP/.iout" | tr -d '\r')
grep -q ' hooks/git/rules/pre-push.sh$' "$PD3/manifest" 2>/dev/null && ok in_manifest_lists_rules \
  || fail "in_manifest_lists_rules: $(cat "$PD3/manifest" 2>&1)"

# in_concurrent_install: same inputs started at once -> one dir, nothing nested, no temp dir left
r=0
for round in 1 2 3 4 5; do
  S="$TMP/s-conc$round"
  ( "$GITHOOKS" install --core-dir "$CORE" --state-dir "$S" > "$TMP/c$round.a" 2>&1; echo "rc=$?" >> "$TMP/c$round.a" ) &
  ( "$GITHOOKS" install --core-dir "$CORE" --state-dir "$S" > "$TMP/c$round.b" 2>&1; echo "rc=$?" >> "$TMP/c$round.b" ) &
  wait
  A=$(tr -d '\r' < "$TMP/c$round.a"); B=$(tr -d '\r' < "$TMP/c$round.b")
  DA=$(head -1 <<<"$A" | jq -r .dir 2>/dev/null | tr -d '\r'); DB=$(head -1 <<<"$B" | jq -r .dir 2>/dev/null | tr -d '\r')
  if ! grep -qx 'rc=0' <<<"$A" || ! grep -qx 'rc=0' <<<"$B" || [ -z "$DA" ] || [ "$DA" != "$DB" ]; then
    fail "in_concurrent_install round $round: [$A] [$B]"; r=1; continue
  fi
  [ -z "$(find "$DA" -mindepth 1 -type d)" ] || { fail "in_concurrent_install round $round: nested dir $(find "$DA" -mindepth 1 -type d)"; r=1; }
  [ "$(ls -A "$S/git-hooks" | wc -l)" -eq 1 ] || { fail "in_concurrent_install round $round: git-hooks/ holds $(ls -A "$S/git-hooks")"; r=1; }
done
[ "$r" -eq 1 ] || ok in_concurrent_install

# in_bad_merge_method
printf '%s\n' '{"plan":{"repo":"acme/core"},"repos":{"api":{"github":"acme/api","mergeMethod":"fast"}}}' > "$TMP/cfg-bad.json"
inst "$TMP/s-bad" --config "$TMP/cfg-bad.json"
[ "$IRC" -eq 2 ] && grep -qF 'repos.api.mergeMethod must be merge, squash or rebase' <<<"$IERR" \
  && [ -z "$(ls -A "$TMP/s-bad/git-hooks" 2>/dev/null)" ] && ok in_bad_merge_method \
  || fail "in_bad_merge_method: rc=$IRC err='$IERR' dir=$(ls -A "$TMP/s-bad/git-hooks" 2>&1)"

# in_usage: missing or bad arguments, a missing config
inst "$TMP/s-u" --bogus; [ "$IRC" -eq 2 ] || fail "in_usage: unknown arg rc=$IRC"
IRC=0; "$GITHOOKS" install --state-dir "$TMP/s-u" >/dev/null 2>&1 || IRC=$?; [ "$IRC" -eq 2 ] || fail "in_usage: no --core-dir rc=$IRC"
inst "$TMP/s-u" --config "$TMP/nope.json"; [ "$IRC" -eq 2 ] && grep -q 'config not found' <<<"$IERR" || fail "in_usage: missing config rc=$IRC $IERR"
IRC=0; "$GITHOOKS" verify >/dev/null 2>&1 || IRC=$?; [ "$IRC" -eq 2 ] || fail "in_usage: verify without --dir rc=$IRC"
IRC=0; "$GITHOOKS" frob >/dev/null 2>&1 || IRC=$?; [ "$IRC" -eq 2 ] && ok in_usage || fail "in_usage: unknown subcommand rc=$IRC"

fx_done
