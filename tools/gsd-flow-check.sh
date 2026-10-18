#!/usr/bin/env bash
# gsd-flow-check.sh — read-only audit of GSD flow runs from OpenCode's session DB.
#
# Usage:
#   gsd-flow-check.sh                 # all gsd-* sessions from the last 7 days
#   gsd-flow-check.sh ses_xxxx        # one flow by session-id prefix
#   gsd-flow-check.sh "" 30           # all gsd flows from the last 30 days
# Env: OPENCODE_DB (default ~/.local/share/opencode/opencode.db)
#      OPENCODE_CONFIG_DIR (default ~/.config/opencode) — for routing conformance
set -uo pipefail

DB_PATH="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
CFG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
[ -f "$DB_PATH" ] || { echo "No OpenCode DB at $DB_PATH — set OPENCODE_DB to override."; exit 2; }
command -v sqlite3 >/dev/null || { echo "sqlite3 required (preinstalled on macOS)."; exit 2; }
DB="file:$DB_PATH?mode=ro"

PREFIX="${1:-}"; DAYS="${2:-7}"
CUTOFF=$(( ( $(date +%s) - DAYS*86400 ) * 1000 ))
if [ -n "$PREFIX" ]; then
  WHERE="(s.id LIKE '${PREFIX}%' OR s.parent_id IN (SELECT id FROM session_v2 WHERE id LIKE '${PREFIX}%'))"
else
  WHERE="(s.agent LIKE 'gsd%' OR s.parent_id IN (SELECT id FROM session_v2 WHERE agent LIKE 'gsd%') OR s.id IN (SELECT parent_id FROM session_v2 WHERE agent LIKE 'gsd%' AND parent_id IS NOT NULL)) AND s.time_created > ${CUTOFF}"
fi

echo "== GSD flow audit — DB: $DB_PATH"
if [ -n "$PREFIX" ]; then echo "   scope: session prefix $PREFIX"; else echo "   scope: gsd-* sessions, last ${DAYS} days"; fi

echo; echo "== 1. Flow sessions (parent = orchestrator, children = spawned agents)"
sqlite3 -header -column "$DB" "
SELECT substr(s.id,1,14) AS id, substr(s.parent_id,1,14) AS parent, s.agent,
       json_extract(s.model,'\$.providerID')||'/'||json_extract(s.model,'\$.id') AS model,
       s.tokens_input AS tin, s.tokens_cache_read AS tcache, s.tokens_output AS tout,
       s.tokens_reasoning AS trea, round(s.cost,3) AS cost,
       datetime(s.time_created/1000,'unixepoch','localtime') AS started,
       round((s.time_updated-s.time_created)/1000.0,0) AS secs
FROM session_v2 s WHERE $WHERE ORDER BY s.time_created;"

echo; echo "== 2. Totals"
sqlite3 -header -column "$DB" "
SELECT count(*) AS sessions, sum(s.tokens_input) AS input, sum(s.tokens_cache_read) AS cache_read,
       sum(s.tokens_input)+sum(s.tokens_cache_read) AS exposure,
       round(sum(s.tokens_cache_read)*1.0/max(1,sum(s.tokens_input)+sum(s.tokens_cache_read)),4) AS cache_hit_rate,
       sum(s.tokens_output) AS output, sum(s.tokens_reasoning) AS reasoning, round(sum(s.cost),4) AS cost
FROM session_v2 s WHERE $WHERE;"

echo; echo "== 3. Routing conformance (DB model vs opencode.jsonc agent map)"
if command -v node >/dev/null && [ -f "$CFG_DIR/opencode.jsonc" ]; then
  OPENCODE_DB="$DB_PATH" GSD_CHECK_WHERE="$WHERE" node - "$CFG_DIR/opencode.jsonc" <<'EOF'
const fs = require("fs");
const { execFileSync } = require("child_process");
const raw = fs.readFileSync(process.argv[2], "utf8");
// string-aware comment strip (keeps URLs inside strings intact)
let out = "", i = 0, inStr = false, esc = false;
while (i < raw.length) {
  const c = raw[i];
  if (inStr) {
    out += c;
    if (esc) esc = false;
    else if (c === "\\") esc = true;
    else if (c === '"') inStr = false;
    i++; continue;
  }
  if (c === '"') { inStr = true; out += c; i++; continue; }
  if (c === "/" && raw[i+1] === "/") { while (i < raw.length && raw[i] !== "\n") i++; continue; }
  if (c === "/" && raw[i+1] === "*") { i += 2; while (i < raw.length && !(raw[i] === "*" && raw[i+1] === "/")) i++; i += 2; continue; }
  out += c; i++;
}
const j = JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
const map = {};
for (const [k, v] of Object.entries(j.agent || {})) if (v && v.model) map[k] = v.model;
const db = process.env.OPENCODE_DB || (process.env.HOME + "/.local/share/opencode/opencode.db");
const where = process.env.GSD_CHECK_WHERE;
const rows = execFileSync("sqlite3", ["-json", "file:" + db + "?mode=ro",
  `SELECT DISTINCT s.agent AS agent, json_extract(s.model,'$.providerID')||'/'||json_extract(s.model,'$.id') AS model FROM session_v2 s WHERE ${where} AND s.model IS NOT NULL;`
]).toString().trim();
if (!rows) { console.log("(no gsd sessions found)"); process.exit(0); }
let mismatches = 0, unmanaged = 0;
for (const r of JSON.parse(rows)) {
  const agent = r.agent || "(no agent recorded)";
  if (!r.model || r.model === "null/null" || r.model === "null") { console.log(`INFO     ${agent} -> no model request recorded`); continue; }
  const base = agent.replace(/\.compact$/, "");
  const expected = map[base];
  if (!expected) { unmanaged++; console.log(`INFO     ${agent} -> ${r.model} (no jsonc entry; inherits default)`); continue; }
  if (expected === r.model) console.log(`MATCH    ${agent} -> ${r.model}`);
  else { mismatches++; console.log(`MISMATCH ${agent} -> ${r.model} (expected ${expected})`); }
}
console.log(`routing: ${mismatches} mismatch(es), ${unmanaged} agent(s) not in map`);
EOF
else
  echo "skipped (node or $CFG_DIR/opencode.jsonc not found)"
fi

echo; echo "== 4. Tool usage across the flow"
sqlite3 -header -column "$DB" "
SELECT json_extract(c.value,'\$.name') AS tool, count(*) AS calls,
       sum(length(coalesce(json_extract(c.value,'\$.state.content'),''))) AS out_bytes
FROM session_message m JOIN session_v2 s ON s.id = m.session_id,
     json_each(json_extract(m.data,'\$.content')) c
WHERE $WHERE AND json_extract(c.value,'\$.type')='tool'
GROUP BY tool ORDER BY calls DESC;"

echo; echo "== 5. Integration markers"
sqlite3 -header -column "$DB" "
SELECT
 (SELECT count(*) FROM session_message m JOIN session_v2 s ON s.id=m.session_id,
    json_each(json_extract(m.data,'\$.content')) c
  WHERE $WHERE AND json_extract(c.value,'\$.type')='tool'
    AND json_extract(c.value,'\$.name') IN ('compress','decompress','search_context','acp_status')) AS bili_folds,
 (SELECT count(*) FROM session_message m JOIN session_v2 s ON s.id=m.session_id,
    json_each(json_extract(m.data,'\$.content')) c
  WHERE $WHERE AND json_extract(c.value,'\$.type')='tool'
    AND json_extract(c.value,'\$.state.content') LIKE '%rtk recall%') AS rtk_intercepts,
 (SELECT count(*) FROM session_message m JOIN session_v2 s ON s.id=m.session_id,
    json_each(json_extract(m.data,'\$.content')) c
  WHERE $WHERE AND json_extract(c.value,'\$.type')='tool'
    AND json_extract(c.value,'\$.name') LIKE 'ctx_%') AS leanctx_calls,
 (SELECT count(*) FROM session_message m JOIN session_v2 s ON s.id=m.session_id,
    json_each(json_extract(m.data,'\$.content')) c
  WHERE $WHERE AND json_extract(c.value,'\$.type')='tool'
    AND json_extract(c.value,'\$.name') IN ('read','grep','glob')) AS native_reads;"

echo; echo "== 6. Verdicts"
N=$(sqlite3 "$DB" "SELECT count(*) FROM session_v2 s WHERE $WHERE;")
CH=$(sqlite3 "$DB" "SELECT round(sum(s.tokens_cache_read)*1.0/max(1,sum(s.tokens_input)+sum(s.tokens_cache_read)),3) FROM session_v2 s WHERE $WHERE;")
BL=$(sqlite3 "$DB" "SELECT count(*) FROM session_message m JOIN session_v2 s ON s.id=m.session_id, json_each(json_extract(m.data,'\$.content')) c WHERE $WHERE AND json_extract(c.value,'\$.type')='tool' AND json_extract(c.value,'\$.name') IN ('compress','decompress','search_context','acp_status');")
BA=$(sqlite3 "$DB" "SELECT count(*) FROM session_message m JOIN session_v2 s ON s.id=m.session_id, json_each(json_extract(m.data,'\$.content')) c WHERE $WHERE AND json_extract(c.value,'\$.type')='tool' AND json_extract(c.value,'\$.name') IN ('bash','shell');")
RT=$(sqlite3 "$DB" "SELECT count(*) FROM session_message m JOIN session_v2 s ON s.id=m.session_id, json_each(json_extract(m.data,'\$.content')) c WHERE $WHERE AND json_extract(c.value,'\$.type')='tool' AND json_extract(c.value,'\$.state.content') LIKE '%rtk recall%';")
[ "$N" -gt 0 ] && echo "PASS  flow found: $N session(s)" || echo "REVIEW  no gsd sessions in scope (widen days or pass a session prefix)"
awk -v c="$CH" 'BEGIN{exit !(c>=0.5)}' && echo "PASS  prompt cache active (hit rate $CH)" || echo "REVIEW  low cache hit rate ($CH) — check provider caching / session churn"
[ "$BL" -gt 0 ] && echo "PASS  Billion Context active ($BL fold/search calls)" || echo "REVIEW  no bili compression calls seen — check plugins entry + daemon (bili doctor)"
if [ "$BA" -gt 0 ]; then [ "$RT" -gt 0 ] && echo "PASS  RTK intercepting shell ($RT/$BA shell calls)" || echo "INFO  no RTK marker in shell output — normal if outputs were small (RTK filters only large outputs); verify plugin/hook if big outputs passed unfiltered"; fi
echo "INFO  lean-ctx calls: $(sqlite3 "$DB" "SELECT count(*) FROM session_message m JOIN session_v2 s ON s.id=m.session_id, json_each(json_extract(m.data,'\$.content')) c WHERE $WHERE AND json_extract(c.value,'\$.type')='tool' AND json_extract(c.value,'\$.name') LIKE 'ctx_%';") (on-demand by design — 0 is normal)"
