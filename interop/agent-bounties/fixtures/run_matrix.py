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

  For every row it binds the log's identities, walks the log through the state
  machine, then classifies the claim into exactly one of:

      supported         the log establishes the claim
      rejected          the log contradicts the claim
      indistinguishable the log is insufficient in both directions

  Nothing is rounded up. A row that we cannot decide is reported as
  indistinguishable, and the summary keeps failing, unsupported and
  indistinguishable rows separate -- there is no single "pass rate".

  The exit status is computed once, before either output branch, so the text
  table and --json cannot disagree about whether the run is red.

Usage:
    python fixtures/run_matrix.py                 # table
    python fixtures/run_matrix.py --json          # machine-readable rows
    python fixtures/run_matrix.py --verbose       # per-event trace
    python fixtures/run_matrix.py --controls      # run the mutation controls
"""
import copy
import io
import json
import os
import re
import sys
import tempfile
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
MATRIX = os.path.join(HERE, "escrow_9_cases.json")
CONTROLS = os.path.join(HERE, "controls_mutations.json")

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

# Every event in this model is emitted at most once per escrow. A second
# emission is a contradiction, not a second payment.
SINGLE_SHOT = set(TRANSITIONS)


# --------------------------------------------------------------------------
# Identity binding
# --------------------------------------------------------------------------

def bind(case):
    """Bind every identity the log asserts to the case's canonical fields.

    Before this ran, only EscrowReleased was checked against anything, so an
    event could be rewritten to reference a different escrow, a different
    payer, or an amount never committed, and the row would still be reported
    supported. Nothing downstream may trust an unbound log.
    """
    esc = case["escrow"]
    agr = case.get("agreement") or {}
    claim = case.get("claim") or {}
    errors = []

    eid = esc["id"]
    committed = int(esc["amount"]) if "amount" in esc else None
    payer = esc.get("payer")
    payee = esc.get("payee")

    # agreement <-> escrow: the two identities must be the same deal.
    if agr:
        if agr.get("id") != esc.get("agreementId"):
            errors.append(
                "agreement %s does not match escrow.agreementId %s"
                % (agr.get("id"), esc.get("agreementId"))
            )
        if payer is not None and agr.get("consumer") != payer:
            errors.append(
                "agreement.consumer %s is not escrow payer %s"
                % (agr.get("consumer"), payer)
            )
        if payee is not None and agr.get("provider") != payee:
            errors.append(
                "agreement.provider %s is not escrow payee %s"
                % (agr.get("provider"), payee)
            )
        if "totalValue" in agr and committed is not None:
            if int(agr["totalValue"]) != committed:
                errors.append(
                    "agreement.totalValue %s != escrow committed %s"
                    % (agr["totalValue"], committed)
                )

    # claim <-> escrow: a claim about another escrow is not a claim here.
    if claim.get("escrowId") is not None and claim["escrowId"] != eid:
        errors.append(
            "claim names escrow %s, case escrow is %s" % (claim["escrowId"], eid)
        )

    seen = {}
    for e in case["events"]:
        t = e.get("type")
        seq = e.get("seq")

        if e.get("escrowId") != eid:
            errors.append(
                "seq %s %s names escrow %s, case escrow is %s"
                % (seq, t, e.get("escrowId"), eid)
            )

        if t in SINGLE_SHOT:
            seen[t] = seen.get(t, 0) + 1
            if seen[t] > 1:
                errors.append(
                    "duplicate %s for %s at seq %s" % (t, eid, seq)
                )

        if t == "EscrowCreated":
            if e.get("agreementId") != esc.get("agreementId"):
                errors.append(
                    "seq %s create names agreement %s, escrow is %s"
                    % (seq, e.get("agreementId"), esc.get("agreementId"))
                )
            if payer is not None and e.get("payer") != payer:
                errors.append(
                    "seq %s create payer %s, escrow payer is %s"
                    % (seq, e.get("payer"), payer)
                )
            if payee is not None and e.get("payee") != payee:
                errors.append(
                    "seq %s create payee %s, escrow payee is %s"
                    % (seq, e.get("payee"), payee)
                )
            if committed is not None and "amount" in e and int(e["amount"]) != committed:
                errors.append(
                    "seq %s create amount %s, committed amount is %s"
                    % (seq, e["amount"], committed)
                )
        elif t == "EscrowFunded":
            if payer is not None and e.get("funder") != payer:
                errors.append(
                    "seq %s funder %s, escrow payer is %s"
                    % (seq, e.get("funder"), payer)
                )
            if committed is not None and "amount" in e and int(e["amount"]) != committed:
                errors.append(
                    "seq %s funded amount %s, committed amount is %s"
                    % (seq, e["amount"], committed)
                )
        elif t == "EscrowVerified":
            # The proofs carried here are opaque in this model. What is bound
            # is the escrow the claim belongs to, above.
            pass
        elif t == "EscrowReleased":
            if payee is not None and e.get("payee") != payee:
                errors.append(
                    "seq %s release payee %s, escrow payee is %s"
                    % (seq, e.get("payee"), payee)
                )
            if committed is not None and "amount" in e and int(e["amount"]) != committed:
                errors.append(
                    "seq %s release amount %s, committed amount is %s"
                    % (seq, e["amount"], committed)
                )
        elif t == "EscrowRefunded":
            if payer is not None and e.get("payer") != payer:
                errors.append(
                    "seq %s refund payee %s, escrow payer is %s"
                    % (seq, e.get("payer"), payer)
                )
            if committed is not None and "amount" in e and int(e["amount"]) != committed:
                errors.append(
                    "seq %s refunded amount %s, committed amount is %s"
                    % (seq, e["amount"], committed)
                )
        elif t == "EscrowTimeout":
            if esc.get("deadline") is not None and e.get("deadline") != esc.get("deadline"):
                errors.append(
                    "seq %s timeout deadline %s, escrow deadline is %s"
                    % (seq, e.get("deadline"), esc.get("deadline"))
                )
        elif t == "EscrowCancelled":
            if payer is not None and e.get("canceller") != payer:
                errors.append(
                    "seq %s canceller %s, escrow payer is %s"
                    % (seq, e.get("canceller"), payer)
                )

    return errors


# --------------------------------------------------------------------------
# Replay and classification
# --------------------------------------------------------------------------

def replay(events, verbose=False):
    """Walk the log. Returns (final_state, errors)."""
    state = EMPTY
    errors = []
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
    eid = esc["id"]
    committed = int(esc["amount"]) if "amount" in esc else None

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
            if committed is not None and got_amt != committed:
                return "rejected", "released %d, escrow committed %d" % (got_amt, committed)
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
        if any(e["payee"] != esc["payee"] for e in paid):
            return "rejected", "a release event paid someone other than the escrow payee"
        if committed is not None and total != 2 * committed:
            return "rejected", "releases sum to %d, twice the committed amount is %d" % (
                total, 2 * committed)
        if len(paid) == 2 and total == want_amt:
            return "supported", "two release events summing to %d" % total
        return "rejected", "releases sum to %d, claim says %d" % (total, want_amt)

    if kind == "funds-returned-to-payer":
        want_to = claim["recipient"]
        want_amt = int(claim["amount"])
        if not refunded:
            return "rejected", "no EscrowRefunded event; escrow is %s" % state
        if state != CANCELLED:
            return "rejected", "refunded but escrow ended in %s, not Cancelled" % state
        got_to = refunded[0]["payer"]
        got_amt = int(refunded[0]["amount"])
        # The canonical comparison, not just claim-against-event: both sides of
        # the event may be moved together and still agree with each other.
        if esc.get("payer") is not None and got_to != esc["payer"]:
            return "rejected", "refund went to %s, escrow payer is %s" % (got_to, esc["payer"])
        if committed is not None and got_amt != committed:
            return "rejected", "refunded %d, escrow committed %d" % (got_amt, committed)
        if got_to != want_to:
            return "rejected", "refund went to %s, claim says %s" % (got_to, want_to)
        if got_amt != want_amt:
            return "rejected", "refunded %d, claim says %d" % (got_amt, want_amt)
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
        out.append((pin, "function %s(" % fn in src,
                    "ok" if ("function %s(" % fn) in src else "function not found"))
    return out


def evaluate_doc(doc, verbose=False):
    rows = []
    for case in doc["cases"]:
        if verbose:
            print("")
            print("%s  %s" % (case["id"], case["title"]))
        errors = bind(case)
        state, replay_errors = replay(case["events"], verbose=verbose)
        errors = errors + replay_errors
        if state != case["escrow"]["state"]:
            errors.append(
                "replayed final state %s != declared state %s"
                % (state, case["escrow"]["state"])
            )
        verdict, reason = classify(case, state, errors)
        rows.append({
            "id": case["id"],
            "expected": case["expected"],
            "verdict": verdict,
            "agree": verdict == case["expected"],
            "reason": reason,
            "controls": case.get("controls", []),
            "final_state": state,
            "pins": pins_ok(case.get("pins", [])),
        })
    return rows


def summarise(rows):
    supported = [r for r in rows if r["verdict"] == "supported"]
    rejected = [r for r in rows if r["verdict"] == "rejected"]
    undecided = [r for r in rows if r["verdict"] == "indistinguishable"]
    disagree = [r for r in rows if not r["agree"]]
    bad_pins = [(r["id"], p) for r in rows for p in r["pins"] if not p[1]]
    return {
        "supported": supported,
        "rejected": rejected,
        "indistinguishable": undecided,
        "disagree": disagree,
        "bad_pins": bad_pins,
    }


def status_of(summary):
    """The one place the exit status is decided, shared by every output branch."""
    return 0 if not summary["disagree"] and not summary["bad_pins"] else 1


def main(argv=None, matrix=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    as_json = "--json" in argv
    verbose = "--verbose" in argv
    matrix = matrix or MATRIX

    doc = json.load(open(matrix, encoding="utf-8"))
    rows = evaluate_doc(doc, verbose=verbose)
    summary = summarise(rows)

    # Computed once, before either branch. --json used to return 0 no matter
    # what the rows said, which let a harness read a red run as green.
    status = status_of(summary)

    if as_json:
        print(json.dumps(rows, indent=2))
        return status

    print("")
    print("%-34s %-16s %-16s %-6s %s" % ("CASE", "EXPECTED", "VERDICT", "AGREE", "REASON"))
    print("-" * 118)
    for r in rows:
        print("%-34s %-16s %-16s %-6s %s" % (
            r["id"], r["expected"], r["verdict"], "yes" if r["agree"] else "NO", r["reason"][:60]))
    print("-" * 118)

    print("supported         : %d" % len(summary["supported"]))
    print("rejected          : %d" % len(summary["rejected"]))
    print("indistinguishable : %d   <- rows we cannot decide, not failures and not passes"
          % len(summary["indistinguishable"]))
    print("row mismatches    : %d" % len(summary["disagree"]))
    print("broken pins       : %d" % len(summary["bad_pins"]))
    if summary["disagree"]:
        print("")
        print("MISMATCHES (fix or withdraw, do not restate):")
        for r in summary["disagree"]:
            print("  %-34s expected %s, got %s -- %s"
                  % (r["id"], r["expected"], r["verdict"], r["reason"]))
    if summary["bad_pins"]:
        print("")
        print("BROKEN PINS:")
        for cid, (pin, _, why) in summary["bad_pins"]:
            print("  %-34s %s (%s)" % (cid, pin, why))
    print("")
    print("Note: 'supported' means the LOG establishes the claim. It does not mean")
    print("the operator is honest, and a rejected row is not evidence of fraud --")
    print("it means the claim as stated does not follow from what is observable.")
    return status


# --------------------------------------------------------------------------
# Mutation controls
# --------------------------------------------------------------------------

def apply_edit(obj, path, value):
    """Apply one 'a.b[0].c' edit in place."""
    parts = re.findall(r"[^.\[\]]+|\[\d+\]", path)
    cur = obj
    for p in parts[:-1]:
        cur = cur[int(p[1:-1])] if p.startswith("[") else cur[p]
    last = parts[-1]
    if last.startswith("["):
        cur[int(last[1:-1])] = value
    else:
        cur[last] = value


def run_controls(verbose=False):
    """Apply each mutation and require the checker to catch it."""
    doc = json.load(open(MATRIX, encoding="utf-8"))
    controls = json.load(open(CONTROLS, encoding="utf-8"))["controls"]

    print("")
    print("MUTATION CONTROLS")
    print("-" * 118)
    failures = []

    for ctrl in controls:
        base = [c for c in doc["cases"] if c["id"] == ctrl["base"]]
        if not base:
            failures.append((ctrl["id"], "base case %s not found" % ctrl["base"]))
            continue
        case = copy.deepcopy(base[0])
        for path, value in ctrl["edit"]:
            apply_edit(case, path, value)

        if ctrl["kind"] == "process":
            # Force a row mismatch, then require both output branches to agree
            # that the run is red.
            mutated = copy.deepcopy(doc)
            target = [c for c in mutated["cases"] if c["id"] == ctrl["base"]][0]
            for path, value in ctrl["edit"]:
                apply_edit(target, path, value)
            fd, tmp = tempfile.mkstemp(suffix=".json")
            os.close(fd)
            try:
                with open(tmp, "w", encoding="utf-8") as fh:
                    json.dump(mutated, fh)
                with redirect_stdout(io.StringIO()):
                    rc_text = main(argv=[], matrix=tmp)
                with redirect_stdout(io.StringIO()):
                    rc_json = main(argv=["--json"], matrix=tmp)
            finally:
                os.unlink(tmp)
            ok = rc_text != 0 and rc_json != 0
            detail = "text exit=%s, json exit=%s" % (rc_text, rc_json)
        else:
            errors = bind(case)
            state, replay_errors = replay(case["events"])
            errors = errors + replay_errors
            if state != case["escrow"]["state"]:
                errors.append("replayed final state %s != declared state %s"
                              % (state, case["escrow"]["state"]))
            verdict, reason = classify(case, state, errors)
            ok = verdict == ctrl["expect"]
            detail = "verdict=%s, want=%s -- %s" % (verdict, ctrl["expect"], reason[:80])

        print("%-34s %-4s %s" % (ctrl["id"], "ok" if ok else "FAIL", detail))
        if not ok:
            failures.append((ctrl["id"], detail))

    print("-" * 118)
    print("controls passed   : %d/%d" % (len(controls) - len(failures), len(controls)))
    if failures:
        print("")
        print("CONTROL FAILURES (the checker still accepts a corrupted fixture):")
        for cid, why in failures:
            print("  %-34s %s" % (cid, why))
    return 0 if not failures else 1


if __name__ == "__main__":
    if "--controls" in sys.argv[1:]:
        sys.exit(run_controls())
    sys.exit(main())
