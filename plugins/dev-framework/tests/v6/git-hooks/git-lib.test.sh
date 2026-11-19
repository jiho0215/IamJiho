#!/bin/bash
# hooks/git/_git-lib.sh as a library: the gk_* functions later tasks' rules call (gk_net, gk_managed,
# gk_default_of, gk_latched, gk_block, GK_SESSION, the git-hook scope_net).
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS DEVFW_SESSION_ID DEVFW_CONFIG DEVFW_CORE_DIR CDPATH
for v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_'); do unset "$v"; done
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_fixture.sh"

LIBS=". '$PLUGIN/bin/_lib.sh'; . '$PLUGIN/bin/_scope.sh'; . '$PLUGIN/hooks/git/_git-lib.sh'"
gl() {  # gl <snippet>: a fresh bash with the libs sourced and gk_init pre-push $HK; sets R (rc|stdout) and E (stderr)
  local out rc=0
  out=$(bash -c "$LIBS; gk_init pre-push '$HK'; $1" 2>"$TMP/.gle") || rc=$?
  R="$rc|${out//$'\r'/}"; E=$(tr -d '\r' < "$TMP/.gle")
}

# gl_net_assigns: stdout to the named var IN THIS SHELL, stderr to GK_NET_ERR, the command's exit code
gl 'gk_net o 5 sh -c "echo a; echo b >&2; exit 3"; rc=$?; echo "rc=$rc [$o] [$GK_NET_ERR]"'
[ "$R" = "0|rc=3 [a] [b]" ] && ok gl_net_assigns || fail "gl_net_assigns: $R"
gl 'gk_net o 1 sleep 3; echo "rc=$?"'
[ "$R" = "0|rc=124" ] && ok gl_net_timeout || fail "gl_net_timeout: $R"

# gl_net_no_timeout_blocks: no `timeout` binary -> block, never an unbounded call
mkdir -p "$TMP/notimeout"
for t in cat mktemp rm tr date mkdir jq cygpath awk; do
  p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$TMP/notimeout/$t" 2>/dev/null || cp "$p" "$TMP/notimeout/$t" 2>/dev/null
done
rc=0; out=$(PATH="$TMP/notimeout" "$BASH" -c "$LIBS; GK_HOOK=pre-push; gk_net o 5 echo hi; echo after" 2>"$TMP/.gle") || rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] && grep -q '^devfw pre-push: timeout not found' "$TMP/.gle" && ok gl_net_no_timeout_blocks \
  || fail "gl_net_no_timeout_blocks: rc=$rc out=$out err=$(cat "$TMP/.gle")"

# gl_scope_net_constant: the git hooks' scope_net bounds every call by 20 s, whatever the caller asks for
cat > "$TMP/fakebin/timeout" <<'STUB'
#!/bin/bash
echo "bound=$1"
STUB
chmod +x "$TMP/fakebin/timeout"
gl 'scope_net o 99 true; echo "$o"'
rm -f "$TMP/fakebin/timeout"
[ "$R" = "0|bound=20" ] && ok gl_scope_net_constant || fail "gl_scope_net_constant: $R"

# gl_managed: the three URL forms, any case, first matching argument; unmanaged and empty print nothing
gl 'gk_managed "" https://github.com/other/x.git git@github.com:Acme/API.git https://github.com/acme/core'
[ "$R" = "0|acme/api" ] && ok gl_managed_first_match || fail "gl_managed_first_match: $R"
gl 'gk_managed ssh://git@github.com/acme/core.git'
[ "$R" = "0|acme/core" ] || fail "gl_managed ssh form: $R"
gl 'gk_managed https://github.com/other/x.git "" https://github.com/acme/api-x.git; echo "rc=$?"'
[ "$R" = "0|rc=0" ] && ok gl_managed_none || fail "gl_managed_none: $R"

# gl_default_of
gl 'gk_default_of Acme/API; gk_default_of other/x'
[ "$R" = "0|main
main" ] || fail "gl_default_of fixture: $R"
printf '%s\n' '{"plan":{"repo":"acme/core","default":"trunk"},"repos":{"api":{"github":"acme/api","default":"dev"}}}' > "$TMP/cfg-d.json"
HKD=$("$GITHOOKS" install --core-dir "$CORE" --config "$TMP/cfg-d.json" --state-dir "$TMP/sd" | jq -r .dir | tr -d '\r')
R=$(bash -c "$LIBS; gk_init pre-push '$HKD'; gk_default_of acme/api; gk_default_of ACME/core; gk_default_of other/x" 2>&1 | tr -d '\r')
[ "$R" = "dev
trunk
main" ] && ok gl_default_of || fail "gl_default_of: $R"

# gl_session: a valid DEVFW_SESSION_ID is GK_SESSION; an invalid or missing one is empty
R=$(DEVFW_SESSION_ID=s-1_A bash -c "$LIBS; gk_init pre-push '$HK'; echo \"[\$GK_SESSION]\"" 2>&1 | tr -d '\r')
[ "$R" = "[s-1_A]" ] || fail "gl_session valid: $R"
R=$(DEVFW_SESSION_ID='../x' bash -c "$LIBS; gk_init pre-push '$HK'; echo \"[\$GK_SESSION]\"" 2>&1 | tr -d '\r')
[ "$R" = "[]" ] || fail "gl_session path-like: $R"
R=$(DEVFW_SESSION_ID="$(printf 'a%.0s' {1..65})" bash -c "$LIBS; gk_init pre-push '$HK'; echo \"[\$GK_SESSION]\"" 2>&1 | tr -d '\r')
[ "$R" = "[]" ] && ok gl_session || fail "gl_session too long: $R"

# gl_latched
mkdir -p "$TMP/state/latch"
R=$(DEVFW_SESSION_ID=s9 bash -c "$LIBS; gk_init pre-push '$HK'; gk_latched; echo \$?" 2>&1 | tr -d '\r')
[ "$R" = 1 ] || fail "gl_latched none: $R"
touch "$TMP/state/latch/s9"
R=$(DEVFW_SESSION_ID=s9 bash -c "$LIBS; gk_init pre-push '$HK'; gk_latched; echo \$?" 2>&1 | tr -d '\r')
[ "$R" = 0 ] || fail "gl_latched latched: $R"
R=$(bash -c "$LIBS; gk_init pre-push '$HK'; gk_latched; echo \$?" 2>&1 | tr -d '\r')
[ "$R" = 1 ] && ok gl_latched || fail "gl_latched no session: $R"

# gl_block_row: stderr line, exit 1, one JSON row with every field; empty repo/ref when not given
rm -f "$TMP/state/shadow/new.jsonl"
rc=0; DEVFW_SESSION_ID=s1 bash -c "$LIBS; gk_init pre-push '$HK'; gk_block 'why \"q\"' acme/api refs/heads/main; echo after" \
  >"$TMP/.glo" 2>"$TMP/.gle" || rc=$?
ROW=$(tail -1 "$TMP/state/shadow/new.jsonl" 2>/dev/null | tr -d '\r')
[ "$rc" -eq 1 ] && [ ! -s "$TMP/.glo" ] && [ "$(tr -d '\r' < "$TMP/.gle")" = 'devfw pre-push: why "q"' ] \
  && jq -e '.hook == "pre-push" and .reason == "why \"q\"" and .repo == "acme/api" and .ref == "refs/heads/main"
            and .session == "s1" and (.at | test("^[0-9-]{10}T[0-9:]{8}Z$"))' >/dev/null 2>&1 <<<"$ROW" \
  && ok gl_block_row || fail "gl_block_row: rc=$rc err=$(cat "$TMP/.gle") row=$ROW"
bash -c "$LIBS; gk_init reference-transaction '$HK'; gk_block plain" 2>/dev/null
ROW=$(tail -1 "$TMP/state/shadow/new.jsonl" 2>/dev/null | tr -d '\r')
jq -e '.hook == "reference-transaction" and .repo == "" and .ref == "" and .session == ""' >/dev/null 2>&1 <<<"$ROW" \
  && ok gl_block_row_minimal || fail "gl_block_row_minimal: $ROW"

# gl_init_normalises: a /c/-form hooks dir becomes the C:/ form
if command -v cygpath >/dev/null 2>&1; then
  R=$(bash -c "$LIBS; gk_init pre-push '$(cygpath -u "$HK")'; echo \"\$GK_HK|\$GK_PLAN_REPO|\$GK_STATE\"" 2>&1 | tr -d '\r')
  [ "$R" = "$HK|acme/core|$(mp "$TMP/state")" ] && ok gl_init_normalises || fail "gl_init_normalises: $R"
fi

fx_done
