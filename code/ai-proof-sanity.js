// Copied verbatim from the private Backd repo: scripts/ai-proof-sanity.js
// Reproduced unmodified for reference. Nothing was redacted — this file
// contains no credentials; every secret is read at runtime from the
// environment (Supabase secrets / App Group storage).

#!/usr/bin/env node

/**
 * AI proof review sanity (P9) — guards the safety invariants that keep AI proof
 * review ADVISORY and tamper-resistant. Static structural checks + a small
 * runtime test of the edge function's decision-defaulting (the security-critical
 * "malformed model output can never become an approval" property).
 *
 * Invariants asserted:
 *   1. verify-proof has the string-aware brace-scanner parser (free models emit
 *      fenced / multi-line / trailing-prose JSON).
 *   2. Malformed / invalid model output decodes to "unclear" — NEVER "approve".
 *   3. verify-proof returns an error (→ app falls back to rules) when unconfigured.
 *   4. verify-proof authorizes the proof owner OR the assigned buddy only.
 *   5. The on-device RuleBasedProvider never recommends "approve".
 *   6. A vision failure falls back to the rule engine.
 *   7. Auto-approval requires a REAL vision result (never rules) at high confidence.
 *   8. AI proof is gated by the v1 hard override AND the env flag.
 */

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const read = rel => fs.readFileSync(path.join(root, rel), 'utf8');
const ok = label => console.log(`ok - ${label}`);
function assert(cond, label) { if (!cond) throw new Error(`FAILED: ${label}`); ok(label); }
function assertIncludes(rel, pattern, label) {
  const text = read(rel);
  const matched = pattern instanceof RegExp ? pattern.test(text) : text.includes(pattern);
  if (!matched) throw new Error(`${label} — missing in ${rel}`);
  ok(label);
}

const FN = 'supabase/functions/verify-proof/index.ts';
const SVC = 'src/services/proofVerification.ts';

// ── 1. Robust parser present ──────────────────────────────────────────────────
assertIncludes(FN, /function extractJsonObjects/, 'verify-proof has the brace-scanner parser');
assertIncludes(FN, /escapeControlCharsInStrings/, 'verify-proof tolerates literal control chars in strings');

// ── 2. Malformed → "unclear", never "approve" (default) ───────────────────────
assertIncludes(FN, /VALID_DECISIONS\.includes\(String\(parsed\.decision\)\)\s*\?\s*String\(parsed\.decision\)\s*:\s*"unclear"/,
  'verify-proof defaults an invalid decision to "unclear"');

// ── 3. Unconfigured → error (app falls back to rules) ─────────────────────────
assertIncludes(FN, /if \(!API_URL \|\| !API_KEY \|\| !MODEL\)/, 'verify-proof requires all three secrets');
assertIncludes(FN, /return json\(500/, 'verify-proof returns 500 when unconfigured (→ rules fallback)');

// ── 4. Owner-or-buddy authorization ───────────────────────────────────────────
assertIncludes(FN, /if \(!isOwner && !isBuddy\) return json\(403/, 'verify-proof authorizes owner OR assigned buddy only');

// ── 5. Rules never recommend approve ──────────────────────────────────────────
const svc = read(SVC);
const ruleBlock = svc.slice(svc.indexOf('class RuleBasedProvider'), svc.indexOf('class VisionProvider'));
assert(!/decision:\s*'approve'/.test(ruleBlock), 'RuleBasedProvider never returns decision:approve');
assert(/decision:\s*'needs_review'/.test(ruleBlock) && /decision:\s*'reject'/.test(ruleBlock),
  'RuleBasedProvider only ever returns needs_review or reject');

// ── 6. Vision failure → rules fallback ────────────────────────────────────────
assertIncludes(SVC, /ai_provider_unavailable/, 'a vision failure falls back to rules with a flag');
assertIncludes(SVC, /catch \(e\)[\s\S]{0,200}ruleProvider\.verify/, 'vision errors are caught and routed to the rule engine');

// ── 7. Auto-approval requires a real vision result ────────────────────────────
assertIncludes(SVC, /if \(result\.model_used === RULES_MODEL_NAME\) return false/, 'rules results can never auto-approve');
assertIncludes(SVC, /if \(result\.decision !== 'approve'\) return false/, 'auto-approve requires an approve decision');
assertIncludes(SVC, /confidence < AUTO_APPROVE_MIN_CONFIDENCE/, 'auto-approve requires high confidence');

// ── 8. v1 gating: hard override AND env flag ──────────────────────────────────
assertIncludes('src/lib/releaseFlags.ts', /AI_PROOF_V1_ENABLED/, 'releaseFlags defines the AI proof hard override');
assertIncludes(SVC, /AI_PROOF_V1_ENABLED\s*&&/, 'VisionProvider requires the hard override AND the env flag');

// ── Runtime test: decision-defaulting contract (mirrors verify-proof lines) ────
const VALID = ['approve', 'reject', 'needs_review', 'unclear'];
// Minimal mirror of the function's brace-scan + pick logic, exercised on adversarial input.
function extractObjects(text) {
  const out = []; let depth = 0, start = -1, inStr = false, esc = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inStr) { if (esc) esc = false; else if (ch === '\\') esc = true; else if (ch === '"') inStr = false; continue; }
    if (ch === '"') { inStr = true; continue; }
    if (ch === '{') { if (depth === 0) start = i; depth++; }
    else if (ch === '}' && depth > 0) { depth--; if (depth === 0 && start >= 0) { try { out.push(JSON.parse(text.slice(start, i + 1))); } catch { /* skip */ } start = -1; } }
  }
  return out;
}
function decisionFor(raw) {
  const objs = extractObjects(raw);
  let parsed = {};
  for (const o of objs) if (VALID.includes(String(o.decision))) parsed = o;
  if (!VALID.includes(String(parsed.decision)) && objs.length) parsed = objs[objs.length - 1];
  return VALID.includes(String(parsed.decision)) ? String(parsed.decision) : 'unclear';
}
const cases = [
  ['empty / no JSON', '', 'unclear'],
  ['pure prose garbage', 'The image looks fine to me, approve it!', 'unclear'],
  ['invalid decision value', '{"decision":"banana","confidence":1}', 'unclear'],
  ['truncated JSON', '{"decision":"approve","confi', 'unclear'],
  ['valid reject survives', 'Here you go: {"decision":"reject","confidence":0.8}', 'reject'],
  ['fenced + trailing prose', '```json\n{"decision":"needs_review","confidence":0.5}\n```\nHope that helps', 'needs_review'],
];
for (const [name, input, expected] of cases) {
  const got = decisionFor(input);
  assert(got === expected, `parser: "${name}" → ${expected} (got ${got})`);
}
// The security-critical line: nothing un-approve-like ever becomes an approval.
for (const [name, input] of cases.filter(c => c[2] !== 'approve')) {
  assert(decisionFor(input) !== 'approve', `parser: "${name}" never yields approve`);
}

// ── qa:check wiring ───────────────────────────────────────────────────────────
const pkg = JSON.parse(read('package.json'));
if (!pkg.scripts?.['sanity:ai-proof']) throw new Error('package script missing: sanity:ai-proof');
ok('package script sanity:ai-proof');
assertIncludes('package.json', 'npm run sanity:ai-proof', 'qa:check runs the AI proof sanity');

console.log('\nAI proof review sanity checks passed.');
