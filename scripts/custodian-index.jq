# no // folds: unlike the reap guard, ingest must tell false from null
def exact_key: ([.wave, .kind, .agent, .verdict, .blockers, .ran, .task_tool_available, .summary, (if has("verified_by") then [.verified_by] else null end), (if has("outcome") then [.outcome] else null end)] + [.dispositions | select(. != null)] | tojson);

def log_path: (.cite // "") | tostring | sub(":[0-9]+$"; "");

def current: reduce .[] as $r ({}; .[$r.cite | tostring] = $r) | [.[]];

# a cite is a line number, no identity once a deletion shifts lines
def distinct: reduce .[] as $r ({}; .[[$r.repo, ($r | log_path), ($r | exact_key)] | tojson] = $r) | [.[]];
