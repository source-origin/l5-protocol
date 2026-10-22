#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Reference checker for interop/agent-bounties/fixtures/escrow_9_cases.json.

Scope, stated up front so nobody has to reverse-engineer it:

  This is a REFERENCE MODEL of the escrow state machine as implemented in
  src/AgentEscrow.sol at the commit this file ships with. It is NOT an on-chain
  run and it is NOT a Solidity execution. It answers one narrow question:

      given only the escrow's public fields and the event log, can an outside
      observer establish the claim, refute it, or neither?

  For every row it walks the log through the state machine, then classifies the
  claim into exactly one of:

      supported         the log establishes the claim
      rejected          the log contradicts the claim
      indistinguishable the log is insufficient in both directions

  Nothing is rounded up. A row that we cannot decide is reported as
  indistinguishable, and the summary keeps failing, unsupported and
  indistinguishable rows separate -- there is no single "pass rate".

Usage:
    python fixtures/run_matrix.py                 # table
    python fixtures/run_matrix.py --json          # machine-readable
    python fixtures/run_matrix.py --verbose       # per-event trace
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MATRIX = os.path.join(HERE, "escrow_9_cases.json")

# Escrow states as they appear in AgentEscrow.sol
EMPTY, FUNDED, VERIFIED, RELEASED, CANCELLED, DISPUTED = (
    "Empty", "Funded", "Verified", "Released", "Cancelled", "Disputed",
)

# Event -> (required current state, next state). None means "no state change".
# Mirrors the guards in src/AgentEscrow.sol:
#   createAndFund  -> Funded
#   verifyDelivery -> Funded   -> Verified  (payee only)
#   release/settle -> Verified -> Released  (payer only)
#   refund         -> Funded   -> Cancelled (cancellation or timeout)
#   dispute        -> Verified -> Disputed
TRANSITIONS = {
    "EscrowCreated":   (EMPTY, FUNDED),
    "EscrowFunded":    (None, None),
    "EscrowVerified":  (FUNDED, VERIFIED),
    "EscrowReleased":  (VERIFIED, RELEASED),
    "EscrowCancelled": (FUNDED, CANCELLED),
    "EscrowTimeout":   (FUNDED, CANCELLED),
    "EscrowRefunded":  (None, None),
    "EscrowDisputed":  (VERIFIED, DISPUTED),
}


def replay(events, verbose=False):
    """Walk the log. Returns (final_state, errors)."""
    state = EMPTY
    errors = []
    seen_release = set()
    for e in events:
        t = e["type"]
        if t not in TRANSITIONS:
            errors.append("unknown event %s at seq %s" % (t, e.get("seq")))
            continue
        need, nxt = TRANSITIONS[t]
        if need is not None and state != need:
            errors.append(
                "%s at seq %s impossible: escrow is %s, event needs %s"
                % (t, e.get("seq"), state, need)
            )
        if t == "EscrowReleased":
            eid = e.get("escrowId")
            if eid in seen_release:
                errors.append("duplicate EscrowReleased for %s at seq %s" % (eid, e.get("seq")))
            seen_release.add(eid)
        if nxt is not None:
            if verbose:
                print("    seq %-2s %-16s %-10s -> %s" % (e.get("seq"), t, state, nxt))
            state = nxt
        elif verbose:
            print("    seq %-2s %-16s %-10s (no transition)" % (e.get("seq"), t, state))
    return state, errors


def classify(case, state, errors):
    """Return (verdict, reason) for one case."""
    claim = case["claim"]
    kind = claim["kind"]
    esc = case["escrow"]
    events = case["events"]
    eid = claim.get("escrowId") or esc["id"]

    paid = [e for e in events if e["type"] == "EscrowReleased" and e["escrowId"] == eid]
    refunded = [e for e in events if e["type"] == "EscrowRefunded" and e["escrowId"] == eid]
    verified = [e for e in events if e["type"] == "EscrowVerified" and e["escrowId"] == eid]

    if errors:
        return "rejected", "inconsistent log: " + "; ".join(errors)

    if kind == "provider-paid":
        want_to = claim["recipient"]
        want_amt = int(claim["amount"])
        if state == RELEASED and len(paid) == 1:
            got_to = paid[0]["payee"]
            got_amt = int(paid[0]["amount"])
            if got_to != esc["payee"]:
                return "rejected", "release paid %s, escrow payee is %s" % (got_to, esc["payee"])
            if got_to != want_to:
                return "rejected", "released to %s, claim says %s" % (got_to, want_to)
            if got_amt != want_amt:
                return "rejected", "released %d, claim says %d" % (got_amt, want_amt)
            return "supported", "single EscrowReleased, payee and amount match"
        if refunded:
            return "rejected", "funds were refunded to the payer; escrow is %s" % state
        if verified and state == VERIFIED:
            return "rejected", "verified but not released; no payment has occurred"
        if state == FUNDED:
            return "rejected", "still funded; no payment has occurred"
        return "rejected", "final state %s with no release event" % state

    if kind == "provider-paid-twice":
        want_amt = int(claim["amount"])
        total = sum(int(e["amount"]) for e in paid)
        if total >= want_amt:
            return "supported", "two release events summing to %d" % total
        return "rejected", "releases sum to %d, claim says %d" % (total, want_amt)

    if kind == "funds-returned-to-payer":
        want_to = claim["recipient"]
        want_amt = int(claim["amount"])
        if not refunded:
            return "rejected", "no EscrowRefunded event; escrow is %s" % state
        if state != CANCELLED:
            return "rejected", "refunded but escrow ended in %s, not Cancelled" % state
        if refunded[0]["payer"] != want_to:
            return "rejected", "refund went to %s, claim says %s" % (refunded[0]["payer"], want_to)
        if int(refunded[0]["amount"]) != want_amt:
            return "rejected", "refunded %s, claim says %d" % (refunded[0]["amount"], want_amt)
        return "supported", "EscrowRefunded to the payer, escrow terminal in Cancelled"

    if kind == "no-delivery-claim-was-made":
        # The honest gap, encoded rather than papered over.
        has_timeout = any(e["type"] == "EscrowTimeout" for e in events)
        if has_timeout and not verified:
            return (
                "indistinguishable",
                "EscrowTimeout indicates the deadline passed while Funded; it is a "
                "contract state, not a signed statement of non-delivery, so "
                "'no claim' and 'claim withheld' are observationally identical",
            )
        return "indistinguishable", "no signed non-delivery evidence in the log"

    return "indistinguishable", "unhandled claim kind %s" % kind


def pins_ok(pins):
    """Every pin must name a test function that exists in the repo."""
    out = []
    # HERE is <repo>/interop/agent-bounties/fixtures; the repo root is three up
    root = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
    for pin in pins:
        fname, _, fn = pin.partition("::")
        path = os.path.join(root, "test", fname)
        if not os.path.exists(path):
            out.append((pin, False, "test file missing"))
            continue
        try:
            src = open(path, encoding="utf-8").read()
        except Exception as exc:
            out.append((pin, False, "unreadable: %s" % exc))
            continue
        out.append((pin, "function %s(" % fn in src, "ok" if ("function %s(" % fn) in src else "function not found"))
    return out


def main():
    as_json = "--json" in sys.argv
    verbose = "--verbose" in sys.argv
    doc = json.load(open(MATRIX, encoding="utf-8"))

    rows = []
    for case in doc["cases"]:
        print("") if verbose else None
        if verbose:
            print("%s  %s" % (case["id"], case["title"]))
        state, errors = replay(case["events"], verbose=verbose)
        if state != case["escrow"]["state"]:
            errors.append(
                "replayed final state %s != declared state %s"
                % (state, case["escrow"]["state"])
            )
        verdict, reason = classify(case, state, errors)
        agree = verdict == case["expected"]
        row = {
            "id": case["id"],
            "expected": case["expected"],
            "verdict": verdict,
            "agree": agree,
            "reason": reason,
            "controls": case.get("controls", []),
            "final_state": state,
            "pins": pins_ok(case.get("pins", [])),
        }
        rows.append(row)

    if as_json:
        print(json.dumps(rows, indent=2))
        return 0

    print("")
    print("%-34s %-16s %-16s %-6s %s" % ("CASE", "EXPECTED", "VERDICT", "AGREE", "REASON"))
    print("-" * 118)
    for r in rows:
        print("%-34s %-16s %-16s %-6s %s" % (
            r["id"], r["expected"], r["verdict"], "yes" if r["agree"] else "NO", r["reason"][:60]))
    print("-" * 118)

    supported = [r for r in rows if r["verdict"] == "supported"]
    rejected = [r for r in rows if r["verdict"] == "rejected"]
    undecided = [r for r in rows if r["verdict"] == "indistinguishable"]
    disagree = [r for r in rows if not r["agree"]]
    bad_pins = [(r["id"], p) for r in rows for p in r["pins"] if not p[1]]

    print("supported         : %d" % len(supported))
    print("rejected          : %d" % len(rejected))
    print("indistinguishable : %d   <- rows we cannot decide, not failures and not passes" % len(undecided))
    print("row mismatches    : %d" % len(disagree))
    print("broken pins       : %d" % len(bad_pins))
    if disagree:
        print("")
        print("MISMATCHES (fix or withdraw, do not restate):")
        for r in disagree:
            print("  %-34s expected %s, got %s -- %s" % (r["id"], r["expected"], r["verdict"], r["reason"]))
    if bad_pins:
        print("")
        print("BROKEN PINS:")
        for cid, (pin, _, why) in bad_pins:
            print("  %-34s %s (%s)" % (cid, pin, why))
    print("")
    print("Note: 'supported' means the LOG establishes the claim. It does not mean")
    print("the operator is honest, and a rejected row is not evidence of fraud --")
    print("it means the claim as stated does not follow from what is observable.")
    return 0 if not disagree and not bad_pins else 1


if __name__ == "__main__":
    sys.exit(main())
