#!/usr/bin/env node
/**
 * tools/ledger.cjs  -  ORIGIN Builder Ledger (append-only register)
 *
 * The ledger must be verifiable, not trusted. This tool is the deterministic check:
 *   node tools/ledger.cjs check            # validate schema / monotonic ids / unique handles / tier enums
 *   node tools/ledger.cjs check --evidence # also HEAD every evidence URL (expects 2xx/3xx)
 *   node tools/ledger.cjs add <entry.json> # append one entry, auto-assigning the next bld-NNNN id
 *
 * Rules enforced here (see docs/LEDGER.md):
 *   - append-only: ids monotonic, never renumbered
 *   - unique identity (by handle+surface)
 *   - every non-internal, still-reachable entry cites at least one evidence URL
 *   - tier must be one of the known tiers
 *   - "counted" entries must carry a receipt_ref; external counted entries must also carry a signing_key
 *     (the entry's own published key - the keeper never flips it on its own recording of someone's words)
 *   - link rot is first-class: an entry may set reachable=false (surface gone) and must then explain in note
 *   - superseded_by / supersedes must reference an existing id; superseded entries leave the identity set
 *
 * Zero deps. Node >= 18 (global fetch).
 */
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const LEDGER = path.join(ROOT, 'ledger.json');
const TIERS = ['internal', 'converged', 'in_dialogue', 'contacted', 'observed'];

function load() {
  if (!fs.existsSync(LEDGER)) { console.error('[fail] ledger.json not found at ' + LEDGER); process.exit(1); }
  return JSON.parse(fs.readFileSync(LEDGER, 'utf8'));
}

function check(verifyEvidence) {
  const L = load();
  const errs = [];
  const warn = [];

  if (L.schema !== 'origin-builder-ledger/1') errs.push('schema must be origin-builder-ledger/1, got ' + L.schema);
  if (!Array.isArray(L.entries)) { errs.push('entries must be an array'); return report(errs, warn); }

  const seenIds = new Set();
  const seenIdent = new Set();
  let prev = 0;
  for (const e of L.entries) {
    const tag = e.id || '(no id)';
    if (!/^bld-\d{4}$/.test(e.id || '')) errs.push(tag + ': id must match bld-NNNN');
    const n = parseInt((e.id || '').slice(4), 10);
    if (Number.isFinite(n)) {
      if (n <= prev) errs.push(tag + ': id not monotonic (prev ' + prev + ')');
      prev = Math.max(prev, n);
    }
    if (seenIds.has(e.id)) errs.push(tag + ': duplicate id');
    seenIds.add(e.id);

    if (!e.handle) errs.push(tag + ': missing handle');
    const ident = (e.handle || '') + '@' + (e.surface || '');
    if (!e.superseded_by) {   // superseded entries leave the live identity set
      if (seenIdent.has(ident)) errs.push(tag + ': duplicate identity ' + ident);
      seenIdent.add(ident);
    }

    if (!TIERS.includes(e.tier)) errs.push(tag + ': invalid tier "' + e.tier + '" (allowed: ' + TIERS.join(', ') + ')');
    if (typeof e.counted !== 'boolean') errs.push(tag + ': "counted" must be boolean');
    if (e.counted && !e.receipt_ref) errs.push(tag + ': counted=true requires a receipt_ref');
    if (e.counted && e.tier !== 'internal' && !e.signing_key) errs.push(tag + ": counted=true (external) requires signing_key (the entry's own published key)");
    if (!e.counted && e.receipt_ref) warn.push(tag + ': has receipt_ref but counted=false');
    if (!e.evidence || !Array.isArray(e.evidence)) errs.push(tag + ': evidence must be an array');

    const reachable = e.reachable !== false;
    if (reachable && e.tier !== 'internal') {
      const ev = (e.evidence || []).filter(u => /^https?:\/\//.test(u));
      if (ev.length === 0) errs.push(tag + ': non-internal entry needs >=1 http(s) evidence URL');
    }
    if (!reachable && !e.note) errs.push(tag + ': reachable=false requires a note explaining the surface is gone');
    if (e.tier === 'internal' && (e.evidence || []).length === 0) warn.push(tag + ': internal entry has no evidence link');
  }

  // reference validation (after the full id set is known)
  for (const e of L.entries) {
    for (const f of ['superseded_by', 'supersedes']) {
      if (e[f] && !seenIds.has(e[f])) errs.push((e.id || '') + ': ' + f + ' -> ' + e[f] + ' does not exist');
    }
  }

  report(errs, warn);

  if (verifyEvidence) {
    const urls = [...new Set(L.entries.filter(e => e.reachable !== false).flatMap(e => e.evidence || []).filter(u => /^https?:\/\//.test(u)))];
    console.log('\n[evidence] checking ' + urls.length + ' unique URL(s)...');
    return Promise.all(urls.map(async u => {
      try {
        const r = await fetch(u, { method: 'HEAD', redirect: 'follow', headers: { 'User-Agent': 'origin-ledger-check' } });
        const ok = (r.status >= 200 && r.status < 400) || r.status === 429;
        console.log((ok ? '  ok  ' : ' FAIL ') + r.status + '  ' + u);
        return ok;
      } catch (err) {
        console.log('  err  ----  ' + u + '  (' + err.message + ')');
        return false;
      }
    })).then(rs => {
      const bad = rs.filter(x => !x).length;
      console.log('\n[evidence] ' + (rs.length - bad) + '/' + rs.length + ' reachable' + (bad ? '  (' + bad + ' FAILED)' : ''));
      if (bad) process.exit(1);
    });
  }
}

function report(errs, warn) {
  for (const w of warn) console.log('[warn] ' + w);
  for (const e of errs) console.log('[fail] ' + e);
  console.log(errs.length ? '\nLEDGER INVALID: ' + errs.length + ' error(s)' : '\nLEDGER OK');
  if (errs.length) process.exit(1);
}

function add(file) {
  if (!file) { console.error('usage: node tools/ledger.cjs add <entry.json>'); process.exit(1); }
  const L = load();
  const e = JSON.parse(fs.readFileSync(file, 'utf8'));
  const maxN = L.entries.reduce((m, x) => Math.max(m, parseInt((x.id || 'bld-0000').slice(4), 10) || 0), 0);
  e.id = e.id && /^bld-\d{4}$/.test(e.id) ? e.id : 'bld-' + String(maxN + 1).padStart(4, '0');
  e.counted = !!e.counted;
  if (!e.receipt_ref) e.receipt_ref = null;
  if (!Array.isArray(e.evidence)) e.evidence = e.evidence ? [e.evidence] : [];
  L.entries.push(e);
  L.updated = new Date().toISOString().slice(0, 10);
  fs.writeFileSync(LEDGER, JSON.stringify(L, null, 2) + '\n');
  console.log('appended ' + e.id + ' -> ' + e.handle);
  check(false);
}

const cmd = process.argv[2];
if (cmd === 'check') check(process.argv.includes('--evidence'));
else if (cmd === 'add') add(process.argv[3]);
else { console.log('usage: node tools/ledger.cjs check [--evidence] | add <entry.json>'); process.exit(1); }
