# keep identical to custodian-reap.sh's projection; a test diffs them
def gate_key: ([.wave, .kind, .agent, .verdict, (.blockers // 0), (.ran // null), (.task_tool_available // null), (.summary // ""), (if has("verified_by") then [.verified_by] else null end), (if has("outcome") then [.outcome] else null end)] | tojson);

def current: reduce .[] as $r ({}; .[$r.cite | tostring] = $r) | [.[]];
