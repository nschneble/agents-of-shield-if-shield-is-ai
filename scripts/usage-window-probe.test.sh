#!/usr/bin/env bash
# usage-window-probe.test.sh — producer-side test for the probe the
# custodian's usage-window gate reads.
#
# The real script on a sealed PATH with a stub curl: no network, no
# keychain, no token. Every shape, every reason.
# Background: docs/test-suites.md#usage-window-probe
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
probe="$here/usage-window-probe.sh"
consumer="$here/looper-custodian-cron.test.sh"

# three arms; deleting one silently defeats it — docs/test-suites.md
die_setup() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_setup "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_setup "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_setup "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

[ -x "$probe" ] || die_setup "$probe is missing or not executable"
command -v python3 >/dev/null 2>&1 \
  || die_setup "python3 is not installed and the probe parses with it"
command -v perl >/dev/null 2>&1 \
  || die_setup "perl is not installed and it bounds the probe's keychain read"

fails=0
observed=""
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else
    printf 'FAIL  %s\n' "$1"; fails=$((fails + 1))
    [ -n "$observed" ] && printf '%s\n' "$observed" | sed 's/^/      /'
  fi
  observed=""
}

# --- the captured header block ------------------------------------------
# CRLF and the proxy preamble are as captured; see the doc section
capture() {
  awk '{ printf "%s\r\n", $0 }' <<'HDRS'
HTTP/1.1 200 Connection Established

HTTP/2 200 
date: Fri, 21 Aug 2026 02:23:51 GMT
content-type: application/json
anthropic-ratelimit-unified-status: allowed
anthropic-ratelimit-unified-5h-status: allowed
anthropic-ratelimit-unified-5h-reset: 1787289600
anthropic-ratelimit-unified-5h-utilization: 0.86
anthropic-ratelimit-unified-7d-status: allowed
anthropic-ratelimit-unified-7d-reset: 1787522400
anthropic-ratelimit-unified-7d-utilization: 0.74
anthropic-ratelimit-unified-representative-claim: five_hour
anthropic-ratelimit-unified-fallback-percentage: 0.5
anthropic-ratelimit-unified-fallback: available
anthropic-ratelimit-unified-reset: 1787289600
anthropic-ratelimit-unified-overage-disabled-reason: out_of_credits
anthropic-ratelimit-unified-overage-status: rejected
request-id: req_011CeF6gp3bNoX69sypVXXSi
strict-transport-security: max-age=31536000; includeSubDomains; preload
anthropic-organization-id: c12a17cc-f55d-4c8c-8ef3-c8cbc248c006
anthropic-workspace-id: wrkspc_01XebAqmHsXp3XxjH68RnTdG
traceresponse: 00-0d5608da48e953967dee35f10798b6da-3c08e4ecb4d9b2d4-01
server: cloudflare
vary: Accept-Encoding
content-security-policy: default-src 'none'; frame-ancestors 'none'
cf-cache-status: DYNAMIC
x-robots-tag: none
cf-ray: a2e62d9779fd896f-BOS

HDRS
}

window() { # utilization, status, reset — a bare `null` status stays unquoted
  local s='"'$2'"'
  [ "$2" = null ] && s=null
  printf '{"utilization": %s, "status": %s, "reset": %s}' "$1" "$s" "$3"
}
ok_line() { # source, five_hour, weekly, representative
  printf '{"read_ok": true, "source": "%s", "five_hour": %s, "weekly": %s, "representative": %s}' \
    "$1" "$2" "$3" "$4"
}
FIVE_H=$(window 0.86 allowed 1787289600)
WEEKLY=$(window 0.74 allowed 1787522400)
GOLDEN_FILE=$(ok_line file "$FIVE_H" "$WEEKLY" '"five_hour"')
GOLDEN_KC=$(ok_line keychain "$FIVE_H" "$WEEKLY" '"five_hour"')

TOKEN=tok-fixture-not-a-real-token
NOW=$(date +%s)
FRESH_MS=$(( (NOW + 3600) * 1000 ))
PAST_MS=$(( (NOW - 3600) * 1000 ))
# read at the case, not here: a slow run would age this into plain expiry
near_ms() { printf '%s' "$(( ($(date +%s) + 55) * 1000 ))"; }

# --- case harness --------------------------------------------------------
case_n=0
setup_case() {
  case_n=$((case_n + 1))
  case_dir="$temp_dir/case-$case_n"
  case_bin="$case_dir/bin"
  mkdir -p "$case_bin" "$case_dir/home" "$case_dir/calls" \
    || die_setup "cannot create $case_dir"
  capture > "$case_dir/headers"
  stub curl 'cat "$PROBE_HEADERS"'
  seal
}

# unlinked means ABSENT: this seal is what keeps the real curl out
seal() { # extra-tool...
  local t p
  for t in env bash python3 cat id "$@"; do
    p=$(command -v "$t") || die_setup "$t is not installed; every case needs it"
    ln -sf "$p" "$case_bin/$t" || die_setup "cannot link $t into $case_bin"
  done
}

# rm first: `>` through seal()'s symlink truncates the real binary
stub() { # name, body
  rm -f "$case_bin/$1" || die_setup "cannot clear the $1 slot in $case_bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$CALLS/%s"\n%s\n' \
    "$1" "$2" > "$case_bin/$1" || die_setup "cannot write the $1 stub"
  [ -f "$case_bin/$1" ] && [ ! -L "$case_bin/$1" ] \
    || die_setup "the $1 stub is not a plain file; it would run the real tool"
  chmod +x "$case_bin/$1" || die_setup "cannot install the $1 stub"
}

creds() { # dir, token, expires-ms
  mkdir -p "$1" || die_setup "cannot create $1"
  printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":%s}}\n' "$2" "$3" \
    > "$1/.credentials.json"
}

hdrs() { # sed-expr — a variant of the capture, refusing a no-op edit
  capture | sed "$1" > "$case_dir/headers.new" \
    || die_setup "sed failed on '$1'"
  cmp -s "$case_dir/headers" "$case_dir/headers.new" \
    && die_setup "header edit '$1' matched nothing, so the case tests the capture"
  mv "$case_dir/headers.new" "$case_dir/headers"
}

run_probe() { # VAR=VAL...
  env -i PATH="$case_bin" HOME="$case_dir/home" CALLS="$case_dir/calls" \
    PROBE_HEADERS="$case_dir/headers" "$@" \
    "$probe" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  out=$(cat "$case_dir/out")
}

eq() { # want
  [ "$out" = "$1" ] && return 0
  observed="want: $1
got:  $out"
  return 1
}

# the probe's own promise: the token is never printed, on any arm
quiet() {
  grep -q -e "$TOKEN" -e Bearer "$case_dir/out" "$case_dir/err" && return 1
  return 0
}

emits() { # label, want
  [ "$rc" -eq 0 ] && r=0 || r=1
  check "$1: exits 0 (got $rc)" "$r"
  eq "$2"; check "$1: emits the contract line, byte for byte" $?
  [ "$(wc -l < "$case_dir/out")" -eq 1 ]
  check "$1: emits exactly one line" $?
  quiet; check "$1: printed neither the token nor Bearer" $?
}

seen=""
unread() { # label, reason, bare|dumps
  local want
  case "$3" in
    bare)  want='{"read_ok":false,"reason":"'$2'"}' ;;
    dumps) want='{"read_ok": false, "reason": "'$2'"}' ;;
    *)     die_setup "unknown emit shape '$3'" ;;
  esac
  seen="$seen $2"
  emits "$1" "$want"
}

calls() { # tool
  local f="$case_dir/calls/$1"
  if [ -f "$f" ]; then wc -l < "$f" | tr -d ' '; else echo 0; fi
}

# --- FILE: the dotfile fallback, security(1) absent ----------------------
setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
run_probe
emits "FILE" "$GOLDEN_FILE"
OK_LINE=$out
[ "$(calls curl)" = 1 ] && r=0 || r=1
check "FILE: probed exactly once (curl called $(calls curl)x)" "$r"

# whole argv: `--max-time 200` contains `--max-time 20`
# `--`: the recorded argv starts with -sS, which grep reads as a flag
REQUEST_ARGV="-sS --max-time 20 -D - -o /dev/null https://api.anthropic.com/v1/messages -H Authorization: Bearer $TOKEN -H anthropic-beta: oauth-2025-04-20 -H anthropic-version: 2023-06-01 -H content-type: application/json -d {\"model\":\"claude-haiku-4-5\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\".\"}]}"
grep -qxF -- "$REQUEST_ARGV" "$case_dir/calls/curl" \
  || observed="want: $REQUEST_ARGV
got:  $(cat "$case_dir/calls/curl")"
grep -qxF -- "$REQUEST_ARGV" "$case_dir/calls/curl"
check "FILE: one headers-only max_tokens:1 call, whole argv pinned" $?

# --- FILE: the second dotfile location, and the order of the two ---------
setup_case
creds "$case_dir/home/.config/claude" "$TOKEN" "$FRESH_MS"
run_probe
emits "FILE-CONFIG" "$GOLDEN_FILE"

setup_case
creds "$case_dir/home/.claude" tok-dot-claude "$FRESH_MS"
creds "$case_dir/home/.config/claude" tok-dot-config "$FRESH_MS"
run_probe
grep -qF -- 'Bearer tok-dot-claude' "$case_dir/calls/curl" \
  || observed=$(cat "$case_dir/calls/curl")
grep -qF -- 'Bearer tok-dot-claude' "$case_dir/calls/curl"
check "FILE-ORDER: ~/.claude wins over ~/.config/claude" $?

# --- KEYCHAIN: security(1) present, and the source it reports ------------
setup_case
seal perl
creds "$case_dir/home/kc" "$TOKEN" "$FRESH_MS"
stub security 'cat "$HOME/kc/.credentials.json"'
run_probe USER=fixture
emits "KEYCHAIN" "$GOLDEN_KC"
grep -qF -- 'find-generic-password -s Claude Code-credentials -a fixture -w' \
  "$case_dir/calls/security"
check "KEYCHAIN: read the Claude Code-credentials item for \$USER" $?

# USER is unset under launchd; id(1) is what heals it
setup_case
seal perl
creds "$case_dir/home/kc" "$TOKEN" "$FRESH_MS"
stub security 'cat "$HOME/kc/.credentials.json"'
run_probe
emits "KEYCHAIN-NO-USER" "$GOLDEN_KC"
grep -qF -- "-a $(id -un) -w" "$case_dir/calls/security" \
  || observed=$(cat "$case_dir/calls/security")
grep -qF -- "-a $(id -un) -w" "$case_dir/calls/security"
check "KEYCHAIN-NO-USER: healed an unset USER with id -un" $?

setup_case
creds "$case_dir/home/kc" "$TOKEN" "$FRESH_MS"
stub security 'cat "$HOME/kc/.credentials.json"'
run_probe USER=fixture
emits "KEYCHAIN-NO-PERL" "$GOLDEN_KC"
[ "$(calls security)" = 1 ] && r=0 || r=1
check "KEYCHAIN-NO-PERL: read it unbounded rather than not at all" "$r"

# --- every way the read fails ------------------------------------------
setup_case
run_probe
unread "NO-CREDENTIALS" no_credentials bare
BARE_LINE=$out
[ "$(calls curl)" = 0 ] && r=0 || r=1
check "NO-CREDENTIALS: never probed (curl called $(calls curl)x)" "$r"

setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
stub python3 'exit 1'
run_probe
unread "PARSE-FAILED" parse_failed bare

setup_case
mkdir -p "$case_dir/home/.claude"
printf '{"claudeAiOauth":{"expiresAt":%s}}\n' "$FRESH_MS" \
  > "$case_dir/home/.claude/.credentials.json"
run_probe
unread "NO-ACCESS-TOKEN" no_access_token bare

# not-JSON takes this arm too: the extractor prints an empty token
setup_case
mkdir -p "$case_dir/home/.claude"
printf 'not json at all\n' > "$case_dir/home/.claude/.credentials.json"
run_probe
unread "NO-ACCESS-TOKEN-MALFORMED" no_access_token bare

setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$PAST_MS"
run_probe
unread "TOKEN-EXPIRED" token_expired bare

# 55s of life is inside the 60s skew: refuse, do not probe
setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$(near_ms)"
run_probe
unread "TOKEN-NEAR-EXPIRY" token_expired bare
[ "$(calls curl)" = 0 ] && r=0 || r=1
check "TOKEN-NEAR-EXPIRY: never probed (curl called $(calls curl)x)" "$r"

setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
stub curl 'exit 7'
run_probe
unread "PROBE-FAILED" probe_failed bare

# --- the gate on the headers themselves ---------------------------------
setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
hdrs '/unified-5h-utilization/d'
run_probe
unread "NO-5H-UTILIZATION" no_ratelimit_headers dumps
DUMPS_LINE=$out

setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
: > "$case_dir/headers"
run_probe
unread "NO-HEADERS" no_ratelimit_headers dumps

# --- status: forwarded verbatim, from the 5h header and no other --------
setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
hdrs 's/^anthropic-ratelimit-unified-5h-status: allowed/anthropic-ratelimit-unified-5h-status: allowed_warning/'
run_probe
emits "STATUS-ALLOWED-WARNING" \
  "$(ok_line file "$(window 0.86 allowed_warning 1787289600)" "$WEEKLY" '"five_hour"')"

setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
hdrs 's/^anthropic-ratelimit-unified-5h-status: allowed/anthropic-ratelimit-unified-5h-status: rejected/'
run_probe
emits "STATUS-REJECTED" \
  "$(ok_line file "$(window 0.86 rejected 1787289600)" "$WEEKLY" '"five_hour"')"

# an absent status is null, never a fabricated default
setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
hdrs '/^anthropic-ratelimit-unified-5h-status/d'
run_probe
emits "STATUS-ABSENT" \
  "$(ok_line file "$(window 0.86 null 1787289600)" "$WEEKLY" '"five_hour"')"

# --- representative: the server's claim, never a local selection --------
setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
hdrs 's/^anthropic-ratelimit-unified-7d-utilization: 0.74/anthropic-ratelimit-unified-7d-utilization: 0.99/'
run_probe
emits "CLAIM-NOT-MAX" \
  "$(ok_line file "$FIVE_H" "$(window 0.99 allowed 1787522400)" '"five_hour"')"

setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
hdrs 's/representative-claim: five_hour/representative-claim: synthetic_unobserved_claim/'
run_probe
emits "CLAIM-PASSTHROUGH" \
  "$(ok_line file "$FIVE_H" "$WEEKLY" '"synthetic_unobserved_claim"')"

setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
hdrs '/representative-claim/d'
run_probe
emits "CLAIM-ABSENT" "$(ok_line file "$FIVE_H" "$WEEKLY" null)"

# --- a window present but unreadable is read_ok with a null field -------
# the gate is 5h-utilization's PRESENCE; garbage past it still reads ok
setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
hdrs 's/^anthropic-ratelimit-unified-5h-utilization: 0.86/anthropic-ratelimit-unified-5h-utilization: not-a-number/'
run_probe
emits "UTILIZATION-GARBAGE" \
  "$(ok_line file "$(window null allowed 1787289600)" "$WEEKLY" '"five_hour"')"

setup_case
creds "$case_dir/home/.claude" "$TOKEN" "$FRESH_MS"
hdrs 's/^anthropic-ratelimit-unified-5h-reset: 1787289600/anthropic-ratelimit-unified-5h-reset: 1787289600.5/'
run_probe
emits "RESET-FRACTIONAL" \
  "$(ok_line file "$(window 0.86 allowed null)" "$WEEKLY" '"five_hour"')"

# --- every reason in the source has a case above ------------------------
declared=$( { grep -o 'emit_unreadable "[a-z_]*"' "$probe" | sed 's/.*"\(.*\)"/\1/'
              grep -o '"reason":"[a-z_][a-z_]*"' "$probe" | sed 's/.*:"\(.*\)"/\1/'
            } | sort -u )
covered=$(printf '%s\n' "$seen" | tr ' ' '\n' | grep -v '^$' | sort -u)
[ -n "$declared" ] || observed="(no reason literal found in $probe)"
[ "$covered" = "$declared" ] || observed="declared: $(printf '%s' "$declared" | tr '\n' ' ')
covered:  $(printf '%s' "$covered" | tr '\n' ' ')"
[ -n "$declared" ] && [ "$covered" = "$declared" ]
check "REASONS: every reason the source can emit has a case here" $?

# --- the whitespace asymmetry between the three emitters ----------------
printf '%s' "$OK_LINE" | grep -q '": '
check "SHAPES: the success line carries json.dumps spacing" $?
printf '%s' "$BARE_LINE" | grep -q ' '
[ "$?" -ne 0 ]
check "SHAPES: emit_unreadable's printf line carries no space at all" $?
printf '%s' "$DUMPS_LINE" | grep -q '": '
check "SHAPES: the no_ratelimit_headers line carries json.dumps spacing" $?

# --- the seam the consumer's fixtures were captured across --------------
# nothing else in the repo compares the two
paths() { python3 -c '
import json,sys
def walk(o,p=""):
    if isinstance(o,dict):
        for k,v in o.items(): walk(v,p+"."+k)
    else: print(p)
try: walk(json.loads(sys.stdin.read()))
except Exception: pass
'; }
fixture() { # variable-name — the consumer suite'"'"'s captured line
  sed -n "s/^$1='\(.*\)'$/\1/p" "$consumer" | head -n 1
}
for pair in "CAPTURED_OK:$OK_LINE" "CAPTURED_UNREAD:$BARE_LINE"; do
  name=${pair%%:*}; emitted=${pair#*:}
  fx=$(fixture "$name")
  if [ -z "$fx" ]; then
    observed="(no $name= line in $consumer)"
    check "SEAM: $name is readable from the consumer suite" 1
    continue
  fi
  want=$(printf '%s' "$emitted" | paths | sort)
  got=$(printf '%s' "$fx" | paths | sort)
  [ -n "$want" ] && [ "$want" = "$got" ] || observed="probe:    $(printf '%s' "$want" | tr '\n' ' ')
$name: $(printf '%s' "$got" | tr '\n' ' ')"
  [ -n "$want" ] && [ "$want" = "$got" ]
  check "SEAM: $name carries the key paths the probe emits today" $?
done

echo
if [ "$fails" -eq 0 ]; then echo "all usage-window-probe tests passed"; exit 0
else echo "$fails usage-window-probe test(s) FAILED"; exit 1; fi
