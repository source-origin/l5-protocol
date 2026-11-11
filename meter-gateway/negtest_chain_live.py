"""Negative control for the verifier that the LIVE leg relies on.

The LIVE leg ends with "GET /receipts/<id> verifies clean". That line is worth
nothing unless we can show the verifier says NO when something is actually wrong.
So: take one REAL signed receipt (written by the last live run) and mutate it
eight ways, one at a time, and require the verifier to object every time. The
first case is the positive control -- the untouched receipt must stay clean, or
we have only built a machine that says no.

Run:  python negtest_chain_live.py
Exit: 0 all controls behaved, 1 at least one did not.
"""
import copy
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

import gateway as G  # noqa: E402

RECEIPT = os.path.join(HERE, "live-receipt.json")


def load():
    if not os.path.exists(RECEIPT):
        print("missing %s -- run chain_live.py first (the control needs a real receipt)"
              % os.path.basename(RECEIPT))
        sys.exit(2)
    rc = json.load(open(RECEIPT, encoding="utf-8"))
    cfg = {"pricing": (rc.get("metering") or {}).get("pricing") or {}}
    return rc, cfg


def flip(hexstr, i=2):
    """Change one character of a 0x-prefixed hex string, keeping it well formed."""
    c = "1" if hexstr[i] != "1" else "2"
    return hexstr[:i] + c + hexstr[i + 1:]


def mut_amount(r):
    r["amount"] = int(r["amount"]) + 1


def mut_prompt(r):
    r["metering"]["promptTokens"] = int(r["metering"]["promptTokens"]) + 100000


def mut_completion(r):
    r["metering"]["completionTokens"] = int(r["metering"]["completionTokens"]) + 100000


def mut_signature(r):
    r["payerAuth"] = flip(r["payerAuth"], 2)


def mut_payer(r):
    # a different, valid-looking address: the signature still recovers to the old one
    r["payer"] = "0x" + ("11" * 19) + "22"


def mut_receipt_id(r):
    r["receiptId"] = flip(r["receiptId"], 2)


def mut_chain_id(r):
    r["chainId"] = int(r["chainId"]) + 1


def mut_pricing(r):
    r["metering"]["pricing"] = {"promptPer1k": 1, "completionPer1k": 1}


CASES = [
    ("untouched receipt must verify clean", None, True),
    ("amount raised by 1 wei-unit", mut_amount, False),
    ("promptTokens inflated by 100000", mut_prompt, False),
    ("completionTokens inflated by 100000", mut_completion, False),
    ("payerAuth signature corrupted", mut_signature, False),
    ("payer address swapped", mut_payer, False),
    ("receiptId altered", mut_receipt_id, False),
    ("chainId altered", mut_chain_id, False),
    ("pricing table rewritten in the receipt", mut_pricing, False),
]


def main():
    rc, cfg = load()
    print("=" * 78)
    print("VERIFIER NEGATIVE CONTROL  (%s)" % os.path.basename(RECEIPT))
    print("=" * 78)
    print("  receipt %s  amount=%s" % (rc["receiptId"][:18] + "...", rc["amount"]))

    ok = True
    for label, fn, expect_clean in CASES:
        sample = copy.deepcopy(rc)
        if fn is not None:
            try:
                fn(sample)
            except Exception as e:
                print("  SKIP  %-46s (cannot build sample: %s)" % (label, e))
                ok = False
                continue
        bad = G.verify_receipt(sample, cfg)
        clean = not bad
        good = clean == expect_clean
        ok = ok and good
        print("  %s  %-46s %s" % ("PASS" if good else "FAIL", label,
                                  "clean" if clean else str(bad)[:70]))

    print("-" * 78)
    if not ok:
        print("VERIFIER IS DECORATION -- at least one control did not behave")
        return 1
    print("VERIFIER IS LIVE -- %d/%d controls behaved" % (len(CASES), len(CASES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
