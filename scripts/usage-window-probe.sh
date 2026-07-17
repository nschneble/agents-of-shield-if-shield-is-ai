#!/usr/bin/env bash
# usage-window-probe.sh — read the REAL Claude Code subscription rate-limit window.
#
# Emits one JSON line the looper usage-window guard can parse:
#   {"read_ok":true,"source":"keychain",
#    "five_hour":{"utilization":0.06,"status":"allowed","reset":1784258400},
#    "weekly":{"utilization":0.01,"status":"allowed","reset":1784498400},
#    "representative":"five_hour"}
# On any failure it emits {"read_ok":false,"reason":"<why>"} and exits 0 — the guard
# treats read_ok:false as "unguarded this wave, and say so" ([[feedback-task-tool-availability]]),
# never as 0%.
#
# The signal is a first-party observable: anthropic-ratelimit-unified-* response headers
# off a real /v1/messages call — the same window Claude Code's statusline renders and the
# host actually enforces. NOT ccusage (cost axis) and NOT the Console Usage/Cost API
# (historical org billing, wrong account type).
#
# The token is never printed. Cost: one max_tokens:1 haiku call per probe — a sliver of
# the very window it protects, so call it at the wave boundary, not in a tight loop.
set -uo pipefail

emit_unreadable() { printf '{"read_ok":false,"reason":"%s"}\n' "$1"; exit 0; }

# --- 1. Locate the OAuth credential blob -------------------------------------
# macOS: Keychain service "Claude Code-credentials". Other hosts: dotfile fallback.
cred_json=""
source="keychain"
# USER is often unset under launchd/cron — the exact headless context this guard runs in.
# Heal it so `set -u` can't abort before we reach the read_ok:false contract.
kc_user="${USER:-$(id -un 2>/dev/null || echo "")}"
if command -v security >/dev/null 2>&1 && [ -n "$kc_user" ]; then
  # A locked/ACL-gated keychain can block on a GUI prompt a headless run can't answer.
  # perl's alarm caps that at 8s (perl ships on macOS); fall back to a plain read otherwise.
  if command -v perl >/dev/null 2>&1; then
    cred_json=$(perl -e 'alarm shift; exec @ARGV' 8 \
      security find-generic-password -s "Claude Code-credentials" -a "$kc_user" -w 2>/dev/null || true)
  else
    cred_json=$(security find-generic-password -s "Claude Code-credentials" -a "$kc_user" -w 2>/dev/null || true)
  fi
fi
if [ -z "$cred_json" ]; then
  for f in "$HOME/.claude/.credentials.json" "$HOME/.config/claude/.credentials.json"; do
    if [ -f "$f" ]; then cred_json=$(cat "$f" 2>/dev/null || true); source="file"; break; fi
  done
fi
[ -z "$cred_json" ] && emit_unreadable "no_credentials"

# --- 2. Extract access token + expiry, check freshness -----------------------
parsed=$(printf '%s' "$cred_json" | python3 -c '
import json,sys
try:
    o=json.load(sys.stdin)["claudeAiOauth"]
    print(o.get("accessToken","") or "", int(o.get("expiresAt",0) or 0))
except Exception:
    print("", 0)
' 2>/dev/null) || emit_unreadable "parse_failed"
token=${parsed%% *}
exp_ms=${parsed##* }
[ -z "$token" ] && emit_unreadable "no_access_token"

now_ms=$(python3 -c 'import time;print(int(time.time()*1000))')
# Refresh is the Claude Code client's job, not ours. If the token is expired (or within
# 60s of it), degrade rather than fire a doomed probe.
if [ "${exp_ms:-0}" -le $((now_ms + 60000)) ]; then emit_unreadable "token_expired"; fi

# --- 3. Probe /v1/messages, capture response headers only --------------------
hdrs=$(curl -sS --max-time 20 -D - -o /dev/null https://api.anthropic.com/v1/messages \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"."}]}' \
  2>/dev/null) || emit_unreadable "probe_failed"

# --- 4. Parse the unified rate-limit headers into the guard's JSON -----------
printf '%s' "$hdrs" | SRC="$source" python3 -c '
import sys,os,json
h={}
for line in sys.stdin:
    line=line.rstrip()
    k,sep,v=line.partition(":")
    if not sep: continue
    k=k.strip().lower()
    if k.startswith("anthropic-ratelimit-unified-"): h[k]=v.strip()

def fnum(key):
    try: return float(h[key])
    except (KeyError,ValueError): return None
def inum(key):
    try: return int(h[key])
    except (KeyError,ValueError): return None
def window(prefix):
    return {"utilization":fnum(f"anthropic-ratelimit-unified-{prefix}-utilization"),
            "status":h.get(f"anthropic-ratelimit-unified-{prefix}-status"),
            "reset":inum(f"anthropic-ratelimit-unified-{prefix}-reset")}

if "anthropic-ratelimit-unified-5h-utilization" not in h:
    print(json.dumps({"read_ok":False,"reason":"no_ratelimit_headers"})); sys.exit(0)

print(json.dumps({
    "read_ok":True,
    "source":os.environ.get("SRC","keychain"),
    "five_hour":window("5h"),
    "weekly":window("7d"),
    "representative":h.get("anthropic-ratelimit-unified-representative-claim"),
}))
'
