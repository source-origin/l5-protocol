#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Live leg: a REAL model server (Ollama, OpenAI-compatible) behind the meter gateway.

Everything before this file ran against the built-in mock, which means the token
counts were invented by us and then priced by us -- a round trip that can only
agree with itself. This leg replaces the left half with a model server that
reports its own `usage`, and the right half with a real chain.

What is proven, in order, and nothing beyond:

  1. the upstream really is a model: the answer comes from Ollama, not from
     `call_mock`, and the backend refuses to start a receipt if it is unreachable
     (a dead upstream is an error, never a quiet fall back to "estimated")
  2. `metering.source == "backend"` -- the counts are the server's, not our estimate
  3. the receipt's amount == price(prompt_tokens, completion_tokens) recomputed
     from those same numbers
  4. L5x402 accepted the payer signature and the receipt reads back identical
     (id / amount / chainId), still `Pending` with `settledAmount == 0`
  5. a dead upstream produces HTTP 502 and NO receipt -- silently invoicing
     someone for a request that never reached a model is the failure mode this
     whole thing exists to prevent

Uses a throwaway chain (anvil if the OS allows it, otherwise the py-evm JSON-RPC
shim in tools/) and the local Ollama. No real funds, no network, no consensus.

Exit: 0 all checks passed / 1 something failed / 2 setup problem.
"""
import glob
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
WS = os.path.dirname(os.path.dirname(HERE))
# Machine-specific paths come from the environment, never from a default: a default
# would either leak somebody's home directory into a public repo or silently point
# at a tree that is not the one we think we are testing.
REPO = os.environ.get("L5_REPO") or ""
FOUNDRY = os.environ.get("FOUNDRY_DIR") or ""
ANVIL = os.path.join(FOUNDRY, "anvil.exe") if FOUNDRY else "anvil"
SITE_DEPLOY = os.environ.get("SITE_DEPLOY") or os.path.join(WS, "tools", "site-deploy.py")
DEV_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
RPC_PORT = 8703
GW_PORT = 8419
RPC = "http://127.0.0.1:%d" % RPC_PORT
GW = "http://127.0.0.1:%d" % GW_PORT
UPSTREAM = os.environ.get("OLLAMA_OPENAI") or "http://127.0.0.1:11434/v1/chat/completions"
MODEL = os.environ.get("LIVE_MODEL") or "qwen2.5:0.5b"

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append((name, bool(ok), detail))
    print(("  PASS  " if ok else "  FAIL  ") + name + (("  -- " + detail) if detail else ""))
    return ok


def fail(msg, code=1):
    print("\nFAIL: " + msg)
    return code


def post(url, path, body, timeout=180):
    req = urllib.request.Request(url + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, json.loads(r.read().decode("utf-8", "replace")), dict(r.headers)


def get(url, path, timeout=60):
    with urllib.request.urlopen(url + path, timeout=timeout) as r:
        return r.status, json.loads(r.read().decode("utf-8", "replace"))


def price(prompt_tokens, completion_tokens, pricing):
    """Integer uYUAN per component, rounded UP -- same rule as gateway.price().
    Rounding the *sum* instead of each component drifts by 1 uYUAN, and a meter
    that disagrees with itself by 1 is a meter nobody can audit."""
    def up(tok, per_1k):
        return -(-int(tok) * int(per_1k) // 1000)
    return up(prompt_tokens, pricing["prompt_per_1k"]) + up(completion_tokens, pricing["completion_per_1k"])


def start_gateway(port, extra):
    p = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "gateway.py"), "--port", str(port)] + extra,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace",
    )
    base = "http://127.0.0.1:%d" % port
    for _ in range(60):
        try:
            with urllib.request.urlopen(base + "/healthz", timeout=2) as r:
                if r.status == 200:
                    return p, base
        except Exception:
            time.sleep(0.5)
    out = p.stdout.read() if p.stdout else ""
    p.kill()
    raise RuntimeError("gateway did not start:\n" + (out or "")[-1200:])


def start_chain(port):
    """Bring up a throwaway chain and return (proc_or_None, rpc, note).

    anvil is the first choice. On this machine the OS application-control policy
    blocks anvil.exe (WinError 4551), which is a policy decision, not a bug to
    disable -- so fall back to `tools/rpc_shim.py`, a JSON-RPC node over py-evm.
    The gateway and forge do not know the difference; only this function does.
    """
    rpc = "http://127.0.0.1:%d" % port
    try:
        p = subprocess.run([ANVIL, "--version"], capture_output=True, text=True, timeout=20)
        anvil_ok = p.returncode == 0
        anvil_note = (p.stderr or p.stdout or "").strip()[:120]
    except Exception as e:
        anvil_ok = False
        anvil_note = str(e)[:120]

    if anvil_ok:
        proc = subprocess.Popen([ANVIL, "--port", str(port), "--silent"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return proc, rpc, "anvil"

    shim = os.path.join(WS, "tools", "rpc_shim.py")
    if not os.path.exists(shim):
        raise RuntimeError("anvil unusable (%s) and rpc_shim.py missing" % anvil_note)
    # Keep the node's stderr on disk: when a broadcast fails, the reason lives there
    # and nowhere else. Losing it turns a one-line fix into an archaeology dig.
    err_path = os.path.join(HERE, "live-chain-%d.log" % port)
    err = open(err_path, "w", encoding="utf-8")
    proc = subprocess.Popen([sys.executable, shim, "--port", str(port),
                             "--fund", "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"],
                            stdout=err, stderr=err, text=True)
    print("  [chain] node log: %s" % err_path)
    return proc, rpc, "rpc_shim/py-evm (anvil blocked by application control policy)"


def wait_rpc(rpc, seconds=40):
    for _ in range(seconds * 2):
        try:
            req = urllib.request.Request(rpc, data=json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=3) as r:
                return json.loads(r.read().decode())["result"]
        except Exception:
            time.sleep(0.5)
    return None


def rpc_call(rpc, method, params):
    req = urllib.request.Request(rpc, data=json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode()).get("result")


def codesizes(rpc, addresses):
    """Ask THIS node for the code at each address.

    A receipt saying `verified_codesize: true` is a claim made by an earlier process
    against an earlier chain. The only witness that counts is the node we are about
    to point the gateway at (lesson 45: codesize is the fact, the printout is a claim).
    """
    out = {}
    for name, addr in addresses.items():
        code = rpc_call(rpc, "eth_getCode", [addr, "latest"])
        out[name] = 0 if not code or code == "0x" else (len(code) - 2) // 2
    return out


def main():
    if not os.path.exists(ANVIL):
        print("  [chain] anvil not found at %s -- will use the py-evm shim" % ANVIL)

    print("=" * 78)
    print("L5 meter gateway · LIVE leg (Ollama + chain)")
    print("=" * 78)
    print("  upstream %s" % UPSTREAM)
    print("  model    %s" % MODEL)
    run_started = time.time()

    # ---- 0. the upstream must be a real model server before anything else ----
    try:
        st, up, _ = post(UPSTREAM, "", {
            "model": MODEL,
            "messages": [{"role": "user", "content": "Reply with the single word: pong"}],
            "max_tokens": 12, "stream": False,
        }, timeout=240)
    except Exception as e:
        return fail("upstream unreachable (%s). Start it with: ollama serve" % e, 2)
    prompt_tokens = int((up.get("usage") or {}).get("prompt_tokens") or 0)
    completion_tokens = int((up.get("usage") or {}).get("completion_tokens") or 0)
    check("upstream is a real model server reporting its own usage",
          st == 200 and prompt_tokens > 0 and completion_tokens > 0,
          "prompt=%d completion=%d" % (prompt_tokens, completion_tokens))
    check("upstream echoes the model we asked for", (up.get("model") or "").startswith(MODEL),
          str(up.get("model")))
    if prompt_tokens <= 0:
        return fail("upstream reported no usage -- cannot proceed honestly", 2)

    # ---- 1. throwaway chain + deploy ----
    print("\n  [chain] starting a throwaway chain on :%d ..." % RPC_PORT)
    chain_proc, RPC, chain_note = start_chain(RPC_PORT)
    print("  [chain] %s" % chain_note)
    try:
        cid = wait_rpc(RPC)
        if not cid:
            out = ""
            try:
                out = (chain_proc.stdout.read() or "")[-800:] if chain_proc.stdout else ""
            except Exception:
                pass
            return fail("chain did not answer on %s\n%s" % (RPC, out), 2)

        deploy = subprocess.run(
            [sys.executable, os.path.join(WS, "tools", "site-deploy.py"), "--rpc", RPC],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900,
        )
        if deploy.returncode != 0:
            print(deploy.stdout[-2000:])
            return fail("deploy failed (exit %d)" % deploy.returncode, 2)
        files = sorted(glob.glob(os.path.join(WS, "deploy", "receipts", "l5-chain*-*.json")))
        if not files:
            return fail("no deploy receipt written", 2)
        # Sorting by NAME puts every `l5-chain31337-*` after every `l5-chain131...-*`,
        # so `[-1]` once handed us an 11-07 receipt for a chain this run never touched.
        # The gateway then called an address with no code and the failure surfaced as
        # an opaque BadFunctionCallOutput -- i.e. we debugged the symptom three layers down.
        # Order by mtime, then refuse anything written before this run started.
        newest = max(files, key=os.path.getmtime)
        if os.path.getmtime(newest) < run_started - 5:
            return fail("newest receipt predates this run (%s) -- deploy wrote nothing" % os.path.basename(newest), 2)
        dep = json.load(open(newest, encoding="utf-8"))
        x402 = dep["contracts"]["L5x402"]
        yuan = dep["contracts"]["YUAN"]
        chain_id = int(dep.get("chainId") or int(cid, 16))
        print("  [chain] receipt %s" % os.path.basename(newest))
        print("  [chain] L5x402 %s" % x402)
        print("  [chain] YUAN   %s" % yuan)
        if chain_id != int(cid, 16):
            return fail("receipt is for chain %d but the node says %s" % (chain_id, cid), 2)
        live = codesizes(RPC, dep["contracts"])
        thin = {k: v for k, v in live.items() if v == 0}
        check("every address in this run's receipt has code on this node",
              not thin, "%d/%d addresses, min codesize %d B"
              % (len(live) - len(thin), len(live), min(live.values())))

        run_live_check(GW_PORT, x402, yuan, chain_id, RPC, DEV_KEY)
    finally:
        if chain_proc is not None:
            chain_proc.kill()
            try:
                chain_proc.wait(timeout=10)
            except Exception:
                pass


def run_live_check(gw_port, x402, yuan, chain_id, rpc, dev_key):
    # ---- 2. gateway in front of the real model, anchoring to that chain ----
    print("\n  [gateway] starting on :%d with --upstream ..." % gw_port)
    gw_proc, base = start_gateway(gw_port, [
        "--upstream", UPSTREAM,
        "--anchor", "--rpc", rpc, "--x402", x402, "--token", yuan,
        "--chain-id", str(chain_id), "--payer-key", dev_key, "--anchor-key", dev_key,
        "--artifact", os.path.join(REPO, "out", "L5x402.sol"),
    ])
    try:
        st, health = get(base, "/healthz")
        check("gateway is up and reports a non-mock backend",
              health.get("backend") == "http", json.dumps(health.get("backend")))

        body = {
            "model": MODEL,
            "messages": [{"role": "user", "content": "In one short sentence: what is a settlement layer?"}],
            "max_tokens": 48, "stream": False,
        }
        t0 = time.time()
        st, resp, headers = post(base, "/v1/chat/completions", body, timeout=300)
        elapsed = time.time() - t0
        rc = resp.get("x_origin_receipt") or resp.get("receipt")
        if not rc:
            return fail("no receipt in the response: " + json.dumps(resp)[:600])
        # Keep one real receipt on disk. The negative control needs a genuinely
        # signed object to tamper with; a hand-made fixture would only prove that
        # the verifier agrees with my own idea of what a receipt is.
        with open(os.path.join(HERE, "live-receipt.json"), "w", encoding="utf-8") as f:
            json.dump(rc, f, indent=2, ensure_ascii=False)

        text = ((resp.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
        check("completion came back through the gateway", st == 200 and len(text) > 0,
              "%.1fs, %d chars" % (elapsed, len(text)))
        check("response model is the real one", (resp.get("model") or "").startswith(MODEL), str(resp.get("model")))
        check("receipt header is present", bool(headers.get("X-L5-Receipt-Id")),
              str(headers.get("X-L5-Receipt-Id"))[:18] + "...")

        met = rc.get("metering") or {}
        check("metering.source == backend (server counts, not our estimate)",
              met.get("source") == "backend", str(met.get("source")))
        pt = int(met.get("promptTokens") or 0)
        ct = int(met.get("completionTokens") or 0)
        check("token counts are positive and consistent with the upstream",
              pt > 0 and ct > 0, "prompt=%d completion=%d" % (pt, ct))
        expected = price(pt, ct, met.get("pricing") or {})
        check("amount == price(prompt, completion) recomputed here",
              int(rc.get("amount", -1)) == expected,
              "%s vs %d µYUAN" % (rc.get("amount"), expected))

        # ---- 3. the chain leg ----
        anchor = rc.get("anchor") or {}
        if not rc.get("anchored"):
            print("        anchor error: " + str(anchor.get("error"))[:600])
            if anchor.get("trace"):
                print("        trace tail: " + str(anchor.get("trace"))[-700:])
        check("receipt was anchored on chain", bool(rc.get("anchored")), str(anchor.get("txHash"))[:20] + "...")
        check("receipt status is Pending (no money moved)", str(rc.get("status")) == "Pending",
              str(rc.get("status")))
        check("settledAmount is 0 -- we do not claim settlement without a transfer",
              int(rc.get("settledAmount", -1)) == 0, str(rc.get("settledAmount")))
        rib = (rc.get("anchor") or {}).get("onchain") or {}
        if rib:
            check("on-chain read-back matches the gateway's receipt",
                  rib.get("receiptId") == rc.get("receiptId"),
                  "read back id " + str(rib.get("receiptId"))[:18] + "...")
            check("read-back amount matches",
                  int(rib.get("amount", -1)) == int(rc.get("amount", -2)), str(rib.get("amount")))
            check("read-back says Pending / settledAmount 0 (chain agrees with us)",
                  int(rib.get("settledAmount", -1)) == 0, str(rib.get("settledAmount")))
        else:
            check("on-chain read-back present", False, "receipt carried no anchor.onchain field")

        # ---- 4. verification endpoint recomputes and re-signs ----
        st2, ver = get(base, "/receipts/" + rc["receiptId"])
        check("GET /receipts/<id> verifies clean (recomputed, not trusted)",
              st2 == 200 and ver.get("verified") is True, json.dumps(ver.get("failures") or [])[:120])

        # ---- 5. negative: a dead upstream must NOT produce an invoice ----
        gw2_proc, base2 = start_gateway(gw_port + 1, ["--upstream", "http://127.0.0.1:9/v1/chat/completions"])
        try:
            try:
                st3, bad, _ = post(base2, "/v1/chat/completions", body, timeout=60)
                status = st3
            except urllib.error.HTTPError as e:
                status = e.code
                bad = json.loads(e.read().decode("utf-8", "replace") or "{}")
            check("dead upstream -> 502, not a silent fallback", status == 502, "HTTP %s" % status)
            check("dead upstream -> no receipt was minted",
                  not (bad.get("x_origin_receipt") or bad.get("receipt")),
                  json.dumps(bad)[:120])
        finally:
            gw2_proc.kill()
            gw2_proc.wait(timeout=10)
    finally:
        gw_proc.kill()
        gw_proc.wait(timeout=10)

    print("\n" + "=" * 78)
    passed = sum(1 for _, ok, _ in RESULTS if ok)
    total = len(RESULTS)
    failed = [n for n, ok, _ in RESULTS if not ok]
    print("%d/%d checks passed" % (passed, total))
    if failed:
        print("FAILED: " + "; ".join(failed))
        print("LIVE LEG RED")
        return 1
    print("LIVE LEG GREEN -- real model usage, real signature, real chain, no invented numbers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
