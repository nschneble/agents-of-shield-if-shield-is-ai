#!/usr/bin/env bash
# usage-window-probe.sh — reads the real Claude Code rate-limit window via
# anthropic-ratelimit-unified-* response headers (not ccusage, not the
# Console Usage API). Emits one JSON line; read_ok:false means unguarded,
# never 0%. Costs one max_tokens:1 haiku call; call only at wave boundaries
#
# Emits one JSON line the looper usage-window guard can parse:
#   {"read_ok":true,"source":"keychain",
#    "five_hour":{"utilization":0.06,"status":"allowed","reset":1784258400},
#    "weekly":{"utilization":0.01,"status":"allowed","reset":1784498400},
#    "representative":"five_hour"}
# On failure: {"read_ok":false,"reason":"<why>"}, exit 0.
set -uo pipefail

emit_unreadable() { printf '{"read_ok":false,"reason":"%s"}\n' "$1"; exit 0; }

# 1. locate OAuth credentials: macOS keychain, else a dotfile fallback
cred_json=""
source="keychain"
# USER is often unset under launchd/cron; heal it before set -u can abort
kc_user="${USER:-$(id -un 2>/dev/null || echo "")}"
if command -v security >/dev/null 2>&1 && [ -n "$kc_user" ]; then
  # a locked keychain can block on a GUI prompt; perl alarm caps that at 8s
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

# 2. extract access token + expiry, check freshness
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
# refresh is the client's job; degrade rather than fire a doomed probe
if [ "${exp_ms:-0}" -le $((now_ms + 60000)) ]; then emit_unreadable "token_expired"; fi

# 3. probe /v1/messages, capture response headers only
hdrs=$(curl -sS --max-time 20 -D - -o /dev/null https://api.anthropic.com/v1/messages \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"."}]}' \
  2>/dev/null) || emit_unreadable "probe_failed"

# 4. parse the unified rate-limit headers into the guard's JSON
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
