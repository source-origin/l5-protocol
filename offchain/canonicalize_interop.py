#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Arbitra <-> ORIGIN L5 canonicalization interop check.

Reproduces Arbitra's canonicalize() (TypeScript) semantics in Python, then
keccak256 hashes the resulting UTF-8 byte string — exactly what Arbitra does
("generate the byte string before the keccak256 hash").

Reference TS (from Ali-Adel-Nour, Arbitra issue #56):
  function canonicalize(value: unknown): string {
    if (Array.isArray(value)) return `[${value.map(canonicalize).join(",")}]`;
    if (value !== null && typeof value === "object") {
      const entries = Object.entries(value)
        .filter(([, item]) => item !== undefined)      // strip undefined
        .sort(([left], [right]) => left.localeCompare(right))  // alphabetical
        .map(([key, item]) => `${JSON.stringify(key)}:${canonicalize(item)}`);
      return `{${entries.join(",")}}`;
    }
    return value === undefined ? "null" : JSON.stringify(value);
  }

The only thing this file does NOT do: claim our EIP-712 actionDigest (a
keccak256 over abi.encode of a typed struct) is byte-equal to Arbitra's JSON
canonical digest. They are different serializations of different artifacts:
  - L5 actionDigest  = EIP-712 typed-struct hash (payer authorization)
  - Arbitra verdict  = canonical JSON -> keccak256 (adjudication decision)
The interop boundary is: settlement consumes the verdict *digest* as an opaque
ref, and any party that holds the verdict JSON can recompute that digest with
this canonical form. That is the alignment that matters.
"""
import json
from Crypto.Hash import keccak

def canonicalize(value):
    if isinstance(value, list):
        return "[" + ",".join(canonicalize(v) for v in value) + "]"
    if isinstance(value, dict):
        # strip None-undefined: TS filters only `undefined`, but a JSON
        # round-trip has no undefined; keep semantics explicit for None too
        entries = []
        for k in sorted(value.keys(), key=lambda s: s):  # localeCompare ~ codepoint sort
            item = value[k]
            if item is None:
                continue  # mirror "strip undefined" for the JSON-visible None
            entries.append(json.dumps(k) + ":" + canonicalize(item))
        return "{" + ",".join(entries) + "}"
    if value is None:
        return "null"
    # bool/int/float/str -> JSON.stringify equivalent (compact, no spaces)
    return json.dumps(value, separators=(",", ":"))

def keccak256(s: str) -> str:
    k = keccak.new(digest_bits=256)
    k.update(s.encode("utf-8"))
    return k.hexdigest()

# ---- test vectors ----
VECTORS = [
    # simple object, keys out of order -> proves alphabetical sort matters
    {"z": 1, "a": 2, "m": 3},
    # nested object + array (order preserved)
    {"payload": {"b": 1, "a": 2}, "items": [3, 1, 2], "name": "origin"},
    # string with chars that must survive JSON escaping
    {"key": "a:b,c\"d\\e", "amount": "100.5"},
    # bool / null / number encodings
    {"ok": True, "nothing": None, "count": 7},
]

def main():
    print("=== Arbitra canonicalize (Python port) interop vectors ===")
    for i, v in enumerate(VECTORS):
        c = canonicalize(v)
        h = keccak256(c)
        print(f"[{i}] canonical: {c}")
        print(f"    keccak256: {h}")
        print()

    # a concrete verdict-shaped payload (matches Arbitra's adjudication shape)
    verdict = {
        "verdict_id": "v_0x1a2b3c",
        "receipt_ref": "0xdeadbeef",
        "action_ref": "0xfeedface",
        "decision": "adjudicated",
        "release_amount": "40000000",  # 40e6 micro-YUAN, string to avoid float
        "timestamp": 1727280000,
        "signer_key_family": "secp256r1",
        "evidence": [
            {"digest": "0xabc", "role": "outcome"},
            {"digest": "0xdef", "role": "binding"},
        ],
    }
    c = canonicalize(verdict)
    h = keccak256(c)
    print("=== verdict-shaped payload ===")
    print("canonical:", c)
    print("keccak256:", h)

if __name__ == "__main__":
    main()
