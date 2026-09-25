# Arbitra <-> ORIGIN L5 · Verdict Digest Interop

**Status:** working note for `Ali-Adel-Nour/Arbitra#56`
**Scope:** how Arbitra's canonical-JSON verdict digest crosses into origin-1 settlement
**Date:** 2026-09-26

---

## 1. The boundary, stated once

Two different artifacts, two different digests, one consumption point:

| Artifact | Producer | Serialization | Hash | Purpose |
|---|---|---|---|---|
| **PaymentAction digest** | payer (ORIGIN) | EIP-712 typed struct → `keccak256(abi.encode(...))` | keccak256 | authorizes *what* may settle |
| **Verdict digest** | adjudicator (Arbitra) | canonical JSON → `keccak256(utf8(bytes))` | keccak256 | authorizes *that it should* settle |

They are **not byte-equal, and should not be**. They are different signers
signing different claims. What must be true is narrower and stronger:

> Any party holding the verdict JSON can recompute its digest **bit-for-bit**
> using the canonical form below, and the digest they get is the same opaque
> `verdictRef` the release transaction carries.

That is the entire interop contract. Settlement never re-interprets the verdict;
it refuses to release without a digest that the adjudicator's key produced.

---

## 2. Canonicalization (Arbitra's rule, verbatim semantics)

Reference TS (from Arbitra #56):

```typescript
export function canonicalize(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalize).join(",")}]`;
  }
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, item]) => item !== undefined)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => `${JSON.stringify(key)}:${canonicalize(item)}`);
    return `{${entries.join(",")}}`;
  }
  return value === undefined ? "null" : JSON.stringify(value);
}
```

Rules in plain words:

1. **Object keys** — sorted with `localeCompare` (codepoint-order for the
   ASCII keys we use; both sides must pin one comparator — see §4).
2. **Whitespace** — none. No space after `:` or `,`.
3. **Undefined** — stripped and omitted entirely.
4. **Arrays** — element order preserved (do **not** sort arrays).
5. **Scalars** — `JSON.stringify` of the value (strings quoted, numbers
   bare, booleans `true`/`false`, null → `null`).
6. **Hash** — `keccak256` over the **UTF-8 bytes** of the canonical string.

A Python port is committed at
`offchain/canonicalize_interop.py` (zero deps beyond `pycryptodome` for keccak),
and reproduces these semantics for cross-checking.

---

## 3. What origin-1 does with it

In `L5x402.sol`, the release path carries a `verdictRef` (bytes32). Two modes,
matching your `verdict-before-release` direction:

- `attachVerdict(receiptId, verdictDigest)` — cite a pre-minted verdict.
- `recordPostHocVerdict(receiptId, verdictDigest, isFinal)` — record + mark final.

In both, `verdictDigest` is **opaque**. The contract stores it, emits it, and
gates finality on it. It never parses the verdict JSON, never verifies the
secp256r1 signature itself — that verification happens where P256 is native
(your chain), and the **output** (the digest + the fact it was verified) crosses
the boundary.

This is why the canonical rule matters: the digest is the *only* thing that
travels, so the only way a later auditor can prove "this release was authorized
by verdict V" is to recompute `canonicalize(V)` and match it to the stored
`verdictRef`. A whitespace or key-order mismatch makes that proof fail silently.

---

## 4. The two seams we must still pin (ask back to you)

These are the places "we both sign canonical JSON" turns into two byte strings.
Both are cheap to settle now, expensive later:

1. **Key comparator.** TS `localeCompare` is locale-aware; our Python port uses
   codepoint sort (`sorted()`). For the ASCII keys we use they coincide, but the
   moment a key is non-ASCII (e.g. a field named with CJK), `localeCompare`
   diverges by locale. **Proposal:** pin to a locale-independent comparator —
   UTF-16 code-unit order (what `localeCompare` effectively gives for ASCII) or
   pure codepoint order. Pick one, write it down.

2. **Number encoding.** `JSON.stringify(100.5)` → `"100.5"`, but
   `JSON.stringify(1e21)` → `"1e+21"` (exponent form), and `1.0` → `"1"`.
   A verdict amount that serializes as `1e+21` on one side and `1000000000000000000000`
   on the other breaks the digest. **Proposal:** amounts in verdicts are always
   **strings** (decimal, no exponent) — `release_amount: "40000000"` not `40000000`.
   Our L5 receipt already treats amounts as `uint256`; keep the JSON carrier a
   string.

If you confirm these two, I'll freeze the interop note as a shared spec and add
a cross-vector test that locks the verdict JSON ↔ digest pair so neither side
drifts.

---

## 5. Test vectors (frozen here for cross-check)

Canonical → keccak256, produced by `offchain/canonicalize_interop.py`:

```
{"z":1,"a":2,"m":3}
  -> c430eff553e48f85ee27e092fcbec540df75778b53c4ffb75dcaa805ba25ea57

{"items":[3,1,2],"name":"origin","payload":{"a":2,"b":1}}
  -> 1da1062cfc73697f68e26d54d910ce3c7d95048934fd23d62ead0f810b3ea19c
```

Verdict-shaped payload (the one that would actually cross the boundary):

```
{"action_ref":"0xfeedface","decision":"adjudicated","evidence":[{"digest":"0xabc","role":"outcome"},{"digest":"0xdef","role":"binding"}],"receipt_ref":"0xdeadbeef","release_amount":"40000000","signer_key_family":"secp256r1","timestamp":1727280000,"verdict_id":"v_0x1a2b3c"}
  -> 2e078f41c9148a9fe36eb42ee937c417bac99d7b0049e625e887bc43fad45359
```

Verify on your side with your own TS `canonicalize` + keccak256; if the hex
matches, the canonical form is byte-locked and the interop is real.

---

*— 源 / ORIGIN · L5 interop note*
