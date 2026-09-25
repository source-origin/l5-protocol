#!/usr/bin/env node
/**
 * tools/ledger.test.cjs — regression test for the Builder Ledger verifier.
 *
 * Why this exists: docs/LEDGER.md rule 3 says an external entry is "counted" only on a
 * receipt *signed by* that entry's published key. The verifier once only checked that a
 * key was *listed*, so remembered->counted was one string. scvd (seancrecord) pointed it
 * at the rule; this test is what keeps the rule and the code from drifting apart again.
 *
 * It builds throwaway ledgers in a temp dir and asserts `tools/ledger.cjs check` goes
 * red on a field-only receipt and green only on a signature that actually verifies.
 *
 * Zero deps. Run: node tools/ledger.test.cjs   (exits non-zero on failure)
 */
'use strict';
const fs = require('fs'), os = require('os'), path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const HERE = __dirname;
const LEDGER_CJS = path.join(HERE, 'ledger.cjs');
if (!fs.existsSync(LEDGER_CJS)) { console.error('cannot find ' + LEDGER_CJS); process.exit(1); }

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ledger-test-'));
fs.mkdirSync(path.join(TMP, 'tools'), { recursive: true });
fs.copyFileSync(LEDGER_CJS, path.join(TMP, 'tools', 'ledger.cjs'));

const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const JWK = publicKey.export({ format: 'jwk' });
const RECEIPT = 'release-receipt:{"agreement_id":"0xabc","balance_delta":{"charged":"10","asset":"YUAN"},"finality":"final"}';
const GOOD = crypto.sign(null, Buffer.from(RECEIPT, 'utf8'), privateKey).toString('base64');
const BAD = crypto.sign(null, Buffer.from('tampered', 'utf8'), privateKey).toString('base64');

function entry(over) {
  return Object.assign({
    id: 'bld-0001', handle: 'testuser', surface: 'github:testuser', tier: 'converged',
    note: 'test', first_seen: '2026-09-25', counted: false, receipt_ref: null,
    evidence: ['https://example.com/x'],
  }, over);
}
function writeLedger(entries) {
  fs.writeFileSync(path.join(TMP, 'ledger.json'),
    JSON.stringify({ schema: 'origin-builder-ledger/1', updated: '2026-09-25', entries }, null, 2));
}
function check() {
  try { return { ok: true, out: execFileSync('node', [path.join(TMP, 'tools', 'ledger.cjs'), 'check'], { encoding: 'utf8' }) }; }
  catch (e) { return { ok: false, out: (e.stdout || '') + (e.stderr || '') }; }
}

const cases = [
  ['field-only receipt is rejected (scvd counter-example)',
    [entry({ counted: true, receipt_ref: 'some-string', signing_key: 'https://scvd.store/.well-known/scvd-signing-key' })], false],
  ['receipt present but signature wrong is rejected',
    [entry({ counted: true, receipt_ref: 'https://x/r', signing_key: JWK, receipt: RECEIPT, receipt_sig: BAD })], false],
  ['URL signing_key offline is rejected (not a proof)',
    [entry({ counted: true, receipt_ref: 'https://x/r', signing_key: 'https://example.com/k.jwk', receipt: RECEIPT, receipt_sig: GOOD })], false],
  ['a signature that verifies is accepted',
    [entry({ counted: true, receipt_ref: 'https://x/r', signing_key: JWK, receipt: RECEIPT, receipt_sig: GOOD })], true],
  ['counted=false stays fine without a signature',
    [entry({ counted: false })], true],
];

let fail = 0;
for (const [name, entries, wantOk] of cases) {
  writeLedger(entries);
  const r = check();
  const pass = r.ok === wantOk;
  if (!pass) fail++;
  console.log((pass ? 'ok   ' : 'FAIL ') + name + ' (expected ' + (wantOk ? 'OK' : 'INVALID') + ', got ' + (r.ok ? 'OK' : 'INVALID') + ')');
  if (!pass) console.log('   ' + r.out.trim().replace(/\n/g, '\n   '));
}
fs.rmSync(TMP, { recursive: true, force: true });
console.log(fail ? '\n' + fail + ' case(s) failed' : '\nall ' + cases.length + ' ledger cases passed');
process.exit(fail ? 1 : 0);
