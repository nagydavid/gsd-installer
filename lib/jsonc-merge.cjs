#!/usr/bin/env node
// jsonc-merge.cjs — additive-only merge for JSONC/JSON config files.
// Never overwrites existing values; existing model routing, permissions,
// MCP entries, and plugin lists are preserved. Writes only when changed,
// and only after the merged document re-parses cleanly.
//
// Usage: node jsonc-merge.cjs --file <path> --spec <json>
// Spec: {
//   "setIfAbsent": [ { "path": "mcp.gsd", "value": {...} } ],
//   "arrayAdd":    [ { "path": "plugins", "value": "billion-context", "match": "billion-context" } ],
//   "repairMcp":   [ { "path": "mcp.lean-ctx", "action": "repair"|"disable", "value": {...} } ],
//   "checkUnchanged": ["agent"]
// }
// match: string compared against array string items or object "name"/"command" fields.
// repairMcp: if the entry's command[0] is not usable on THIS machine (absolute
// path missing, or bare name not on PATH): action=repair replaces the entry
// (or sets it when absent), action=disable sets enabled:false. Resolvable
// entries are always preserved.
// Prints: {"changed":bool,"actions":[...],"unchangedOk":bool,"error":...}
'use strict';
const fs = require('fs');

function arg(name) {
  const i = process.argv.indexOf(name);
  if (i === -1 || i === process.argv.length - 1) { fail(`missing ${name}`); }
  return process.argv[i + 1];
}
function fail(msg) {
  console.log(JSON.stringify({ changed: false, actions: [], unchangedOk: true, error: msg }));
  process.exit(2);
}

// Comment stripper that is string-aware (handles //, /* */, escapes).
function stripJsonc(s) {
  let out = '', i = 0, inStr = false, esc = false;
  while (i < s.length) {
    const c = s[i], n = s[i + 1];
    if (inStr) {
      out += c;
      if (esc) { esc = false; i++; continue; }
      if (c === '\\') { esc = true; i++; continue; }
      if (c === '"') inStr = false;
      i++; continue;
    }
    if (c === '"') { inStr = true; out += c; i++; continue; }
    if (c === '/' && n === '/') { while (i < s.length && s[i] !== '\n') i++; continue; }
    if (c === '/' && n === '*') { i += 2; while (i < s.length && !(s[i] === '*' && s[i + 1] === '/')) i++; i += 2; continue; }
    out += c; i++;
  }
  return out.replace(/,(\s*[}\]])/g, '$1'); // strip trailing commas
}

function parse(file) {
  const raw = fs.readFileSync(file, 'utf8');
  return JSON.parse(stripJsonc(raw));
}

function getAt(doc, path, create) { // returns {parent, key} for terminal segment; auto-creates missing intermediate objects
  const segs = path.split('.');
  let cur = doc;
  for (let k = 0; k < segs.length - 1; k++) {
    if (cur == null || typeof cur !== 'object') return null;
    if (cur[segs[k]] === undefined) { if (!create) return null; cur[segs[k]] = {}; }
    cur = cur[segs[k]];
  }
  if (cur == null || typeof cur !== 'object') return null;
  return { parent: cur, key: segs[segs.length - 1] };
}

function arrayItemMatches(item, match) {
  if (typeof item === 'string') return item === match;
  if (item && typeof item === 'object') {
    return item.name === match || item.command === match || item.id === match;
  }
  return false;
}

const file = arg('--file');
const spec = JSON.parse(arg('--spec'));
let doc;
try { doc = parse(file); } catch (e) { fail(`cannot parse ${file}: ${e.message}`); }

const before = JSON.stringify(doc);
const actions = [];

for (const op of spec.setIfAbsent || []) {
  const loc = getAt(doc, op.path, true);
  if (!loc) { actions.push(`skip ${op.path} (parent missing)`); continue; }
  if (loc.parent[loc.key] === undefined) {
    loc.parent[loc.key] = op.value;
    actions.push(`set ${op.path}`);
  } else {
    actions.push(`preserve ${op.path} (already present)`);
  }
}

for (const op of spec.arrayAdd || []) {
  const loc = getAt(doc, op.path, true);
  if (!loc) { actions.push(`skip ${op.path} (parent missing)`); continue; }
  let arr = loc.parent[loc.key];
  if (arr === undefined) { arr = loc.parent[loc.key] = []; }
  if (!Array.isArray(arr)) { actions.push(`skip ${op.path} (not an array)`); continue; }
  const match = op.match !== undefined ? op.match : op.value;
  if (arr.some((it) => arrayItemMatches(it, match))) {
    actions.push(`preserve ${op.path} (contains ${match})`);
  } else {
    arr.push(op.value);
    actions.push(`add ${match} → ${op.path}`);
  }
}

function commandUsable(cmd0) {
  if (typeof cmd0 !== 'string' || cmd0 === '') return false;
  if (cmd0.startsWith('/')) return fs.existsSync(cmd0);
  for (const d of (process.env.PATH || '').split(':')) {
    try { fs.accessSync(`${d}/${cmd0}`, fs.constants.X_OK); return true; } catch (e) { /* keep looking */ }
  }
  return false;
}

for (const op of spec.repairMcp || []) {
  const loc = getAt(doc, op.path, false);
  const present = loc && loc.parent[loc.key] !== undefined;
  if (!present) {
    if (op.action === 'repair') {
      const loc2 = getAt(doc, op.path, true);
      if (loc2) { loc2.parent[loc2.key] = op.value; actions.push(`set ${op.path}`); }
      else actions.push(`skip ${op.path} (parent missing)`);
    } else {
      actions.push(`skip ${op.path} (not present)`);
    }
    continue;
  }
  const entry = loc.parent[loc.key];
  const cmd0 = entry && Array.isArray(entry.command) ? entry.command[0] : null;
  if (commandUsable(cmd0)) {
    actions.push(`preserve ${op.path} (command resolves)`);
  } else if (op.action === 'disable') {
    if (entry && entry.enabled === false) {
      actions.push(`preserve ${op.path} (already disabled)`);
    } else {
      entry.enabled = false;
      actions.push(`disabled ${op.path} (command "${cmd0}" not usable here)`);
    }
  } else {
    loc.parent[loc.key] = op.value;
    actions.push(`repaired ${op.path} (command "${cmd0}" not usable here)`);
  }
}

const after = JSON.stringify(doc);
const changed = after !== before;

let unchangedOk = true;
for (const path of spec.checkUnchanged || []) {
  const seg = path.split('.')[0];
  const b = JSON.stringify(JSON.parse(before)[seg] ?? null);
  const a = JSON.stringify(JSON.parse(after)[seg] ?? null);
  if (b !== a) { unchangedOk = false; actions.push(`CHANGED ${seg} — merge violated preservation`); }
}

if (unchangedOk && changed) {
  try { JSON.parse(after); } catch (e) { fail(`merged document invalid: ${e.message}`); }
  fs.writeFileSync(file, JSON.stringify(doc, null, 2) + '\n');
}

console.log(JSON.stringify({ changed, actions, unchangedOk }));
process.exit(unchangedOk ? 0 : 1);
