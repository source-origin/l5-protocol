#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""ORIGIN L5 meter gateway (MVP).

One HTTP request in, one signed receipt out.

    request  ->  backend (vLLM / Ollama / mock)  ->  real token usage
             ->  price (micro-YUAN)  ->  EIP-712 PaymentAction
             ->  signed receipt  ->  optional on-chain recordReceipt()

The point of this file is NOT to be a nice API proxy. It is to make the billing
claim checkable: every number in the receipt can be recomputed by a third party
from (request body, response body, pricing table, chain id, contract address),
and the on-chain leg re-reads the receipt instead of trusting the tx log line.

Honesty rules baked in:
  * usage source is labelled. "backend" = the model server reported it.
    "estimated" = we guessed from characters. An estimate never calls itself measured.
  * a receipt that was only signed off-chain says `anchored: false`.
    `settledAmount` stays 0 until value actually moves, mirroring the contract.
  * the on-chain leg verifies by read-back (getReceipt), not by "tx sent".

Usage:
    python gateway.py --port 8410                       # offline mock backend
    python gateway.py --upstream http://127.0.0.1:8000   # vLLM / Ollama
    python gateway.py --anchor --rpc http://127.0.0.1:8599

Endpoints:
    POST /v1/chat/completions   OpenAI-compatible; returns x_origin_receipt
    GET  /v1/models
    GET  /receipts/<receiptId>  recompute + verify one receipt
    GET  /pricing
    GET  /healthz
"""
import argparse
import json
import os
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib import error as urlerror
from urllib import request as urlrequest

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

from eth_abi import encode as abi_encode
from eth_account import Account
from eth_utils import keccak

# ── constants mirrored from src/L5x402.sol ────────────────────────────────────
DOMAIN_NAME = "ORIGIN L5 x402"
DOMAIN_VERSION = "1"
DOMAIN_TYPEHASH = keccak(text="EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
PAYMENT_ACTION_TYPEHASH = keccak(
    text="PaymentAction(bytes32 requestId,address payer,address payee,address token,uint256 amount,"
         "bytes32 routeHash,bytes32 payloadHash,bytes32 permissionHash,uint256 deadline)"
)
ZERO32 = b"\x00" * 32

# µYUAN per 1,000 tokens. YUAN has 6 decimals, so 120 = 0.00012 YUAN.
DEFAULT_PRICING = {"prompt_per_1k": 120, "completion_per_1k": 480}

ROUTE = "/v1/chat/completions"


# ── canonical helpers ────────────────────────────────────────────────────────
def canonical(obj):
    """Same bytes whoever computes it: sorted keys, no whitespace, utf-8."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def h32(data):
    return keccak(data) if isinstance(data, bytes) else keccak(text=data)


def addr_to_bytes20(a):
    return bytes.fromhex(a[2:] if a.startswith("0x") else a)


def domain_separator(chain_id, verifying):
    return keccak(abi_encode(
        ["bytes32", "bytes32", "bytes32", "uint256", "address"],
        [DOMAIN_TYPEHASH, keccak(text=DOMAIN_NAME), keccak(text=DOMAIN_VERSION), chain_id, verifying],
    ))


def action_digest(chain_id, verifying, act):
    """Must byte-match L5x402.actionDigest(). Selftest proves it against the contract."""
    struct_hash = keccak(abi_encode(
        ["bytes32", "bytes32", "address", "address", "address", "uint256", "bytes32", "bytes32", "bytes32", "uint256"],
        [PAYMENT_ACTION_TYPEHASH, act["requestId"], act["payer"], act["payee"], act["token"], act["amount"],
         act["routeHash"], act["payloadHash"], act["permissionHash"], act["deadline"]],
    ))
    return keccak(b"\x19\x01" + domain_separator(chain_id, bytes.fromhex(verifying[2:])) + struct_hash)


def receipt_id(act):
    """Must byte-match L5x402._generateReceiptId()."""
    packed = (act["requestId"] + addr_to_bytes20(act["payer"]) + addr_to_bytes20(act["payee"])
              + act["amount"].to_bytes(32, "big") + act["payloadHash"])
    return keccak(packed)


# ── metering + pricing ───────────────────────────────────────────────────────
def meter(body, resp):
    """Return (prompt_tokens, completion_tokens, source). Never invents certainty."""
    usage = (resp or {}).get("usage") or {}
    pt, ct = usage.get("prompt_tokens"), usage.get("completion_tokens")
    if isinstance(pt, int) and isinstance(ct, int):
        return pt, ct, "backend"
    # fallback estimate: ~4 chars/token, clearly labelled
    prompt_text = " ".join(str(m.get("content") or "") for m in body.get("messages", []))
    out_text = ""
    for ch in (resp or {}).get("choices") or []:
        out_text += str((ch.get("message") or {}).get("content") or "")
    return max(1, len(prompt_text) // 4), max(1, len(out_text) // 4), "estimated"


def price(pt, ct, pricing):
    """Integer µYUAN, rounded up per component so a request never prices at 0."""
    def up(tok, per_1k):
        return -(-tok * per_1k // 1000)
    return up(pt, pricing["prompt_per_1k"]) + up(ct, pricing["completion_per_1k"])


# ── receipt construction ─────────────────────────────────────────────────────
def build_receipt(body, resp, cfg):
    pt, ct, source = meter(body, resp)
    amount = price(pt, ct, cfg["pricing"])
    request_id = os.urandom(32)  # bytes32, not a 16-byte uuid
    payload_hash = h32(canonical({"route": ROUTE, "request": body, "response": resp}))
    act = {
        "requestId": request_id,
        "payer": cfg["payer"],
        "payee": cfg["payee"],
        "token": cfg["token"],
        "amount": amount,
        "routeHash": h32(ROUTE),
        "payloadHash": payload_hash,
        "permissionHash": ZERO32,
        "deadline": int(time.time()) + cfg["ttl"],
    }
    digest = action_digest(cfg["chain_id"], cfg["verifying"], act)
    signed = Account._sign_hash(digest, cfg["payer_key_obj"])
    rid = receipt_id(act)

    return {
        "schema": "origin.l5.receipt/1",
        "receiptId": "0x" + rid.hex(),
        "requestId": "0x" + request_id.hex(),
        "payer": cfg["payer"],
        "payee": cfg["payee"],
        "token": cfg["token"],
        "amount": amount,
        "settledAmount": 0,
        "route": ROUTE,
        "routeHash": "0x" + act["routeHash"].hex(),
        "payloadHash": "0x" + payload_hash.hex(),
        "permissionHash": "0x" + ZERO32.hex(),
        "deadline": act["deadline"],
        "chainId": cfg["chain_id"],
        "verifyingContract": cfg["verifying"],
        "actionDigest": "0x" + digest.hex(),
        "payerAuth": "0x" + signed.signature.hex(),
        "metering": {
            "promptTokens": pt,
            "completionTokens": ct,
            "totalTokens": pt + ct,
            "source": source,
            "pricing": dict(cfg["pricing"]),
            "unit": "uYUAN",
        },
        "status": "Pending",
        "anchored": False,
        "anchor": None,
    }


def verify_receipt(rc, cfg):
    """Recompute everything from the receipt's own fields. Returns list of failures."""
    bad = []
    try:
        act = {
            "requestId": bytes.fromhex(rc["requestId"][2:]),
            "payer": rc["payer"],
            "payee": rc["payee"],
            "token": rc["token"],
            "amount": int(rc["amount"]),
            "routeHash": bytes.fromhex(rc["routeHash"][2:]),
            "payloadHash": bytes.fromhex(rc["payloadHash"][2:]),
            "permissionHash": bytes.fromhex(rc["permissionHash"][2:]),
            "deadline": int(rc["deadline"]),
        }
    except Exception as e:  # malformed receipt is a failure, not a crash
        return ["malformed: %s" % e]

    if action_digest(int(rc["chainId"]), rc["verifyingContract"], act) != bytes.fromhex(rc["actionDigest"][2:]):
        bad.append("actionDigest mismatch")
    if receipt_id(act) != bytes.fromhex(rc["receiptId"][2:]):
        bad.append("receiptId mismatch")

    m = rc.get("metering") or {}
    try:
        expected = price(int(m.get("promptTokens", 0)), int(m.get("completionTokens", 0)),
                         m.get("pricing") or cfg["pricing"])
    except Exception as e:
        # A receipt can carry its own pricing table. One with the wrong shape used to
        # raise KeyError straight out of the verifier -- so the endpoint answered 500
        # instead of "this receipt is bad". A verifier that crashes on hostile input
        # is a verifier that can be silenced.
        bad.append("pricing table unusable (%s: %s)" % (type(e).__name__, e))
        expected = None
    if expected is not None and expected != int(rc["amount"]):
        bad.append("amount != price(tokens) (%d vs %d)" % (int(rc["amount"]), expected))

    try:
        recovered = Account._recover_hash(bytes.fromhex(rc["actionDigest"][2:]), signature=bytes.fromhex(rc["payerAuth"][2:]))
    except Exception:
        # an unrecoverable signature is a failed receipt, not a crashed verifier
        return bad + ["payerAuth unrecoverable"]
    if recovered.lower() != rc["payer"].lower():
        bad.append("payerAuth signer != payer")
    return bad


# ── backends ─────────────────────────────────────────────────────────────────
def call_mock(body):
    last = ""
    for m in reversed(body.get("messages", [])):
        if m.get("role") == "user":
            last = str(m.get("content") or "")
            break
    text = "[mock-8b] " + (last[:160] or "ok")
    pt = max(1, len(json.dumps(body.get("messages", []))) // 4)
    ct = max(1, len(text) // 4)
    return {
        "id": "chatcmpl-mock-" + uuid.uuid4().hex[:12],
        "object": "chat.completion",
        "created": int(time.time()),
        "model": body.get("model") or "origin-mock-8b",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": pt, "completion_tokens": ct, "total_tokens": pt + ct},
    }


def call_upstream(url, body, timeout=120):
    req = urlrequest.Request(
        url, data=canonical(body), method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    with urlrequest.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


# ── on-chain anchor (read-back verified) ─────────────────────────────────────
class Anchor:
    def __init__(self, cfg):
        from web3 import Web3
        self.w3 = Web3(Web3.HTTPProvider(cfg["rpc"]))
        if not self.w3.is_connected():
            raise RuntimeError("rpc unreachable: " + cfg["rpc"])
        abi_path = os.path.join(cfg["artifact"], "L5x402.json")
        with open(abi_path, encoding="utf-8") as f:
            self.abi = json.load(f)["abi"]
        self.c = self.w3.eth.contract(address=Web3.to_checksum_address(cfg["verifying"]), abi=self.abi)
        self.acct = Account.from_key(cfg["anchor_key"])
        self.cfg = cfg

    def _get_receipt_outputs(self):
        for item in self.abi:
            if item.get("type") == "function" and item.get("name") == "getReceipt":
                return item["outputs"][0]["components"]
        raise RuntimeError("getReceipt not in ABI")

    def record(self, rc):
        act = (
            bytes.fromhex(rc["requestId"][2:]), rc["payer"], rc["payee"], rc["token"],
            int(rc["amount"]), bytes.fromhex(rc["routeHash"][2:]), bytes.fromhex(rc["payloadHash"][2:]),
            bytes.fromhex(rc["permissionHash"][2:]), int(rc["deadline"]), bytes.fromhex(rc["payerAuth"][2:]),
        )
        tx = self.c.functions.recordReceipt(*act).build_transaction({
            "from": self.acct.address,
            "nonce": self.w3.eth.get_transaction_count(self.acct.address),
            "gas": 1_500_000,
            "gasPrice": self.w3.eth.gas_price,
            "chainId": self.w3.eth.chain_id,
        })
        signed = self.acct.sign_transaction(tx)
        txh = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        rcp = self.w3.eth.wait_for_transaction_receipt(txh, timeout=60)
        if rcp.status != 1:
            raise RuntimeError("recordReceipt reverted")
        # read-back: the chain is the only witness we accept.
        # Field order comes from the ABI, not from a hand-counted index — that is how
        # you end up reading `route` and calling it `chainId`.
        fn = self.c.functions.getReceipt(bytes.fromhex(rc["receiptId"][2:]))
        raw = fn.call()
        names = [o["name"] for o in self._get_receipt_outputs()]
        rec = dict(zip(names, raw))
        onchain = {
            "receiptId": "0x" + rec["receiptId"].hex(),
            "amount": int(rec["amount"]),
            "settledAmount": int(rec["settledAmount"]),
            "chainId": int(rec["chainId"]),
            "status": int(rec["status"]),
            "finality": int(rec["finality"]),
        }
        if onchain["chainId"] != int(rc["chainId"]):
            raise RuntimeError("read-back chainId mismatch (%s != %s)" % (onchain["chainId"], rc["chainId"]))
        if onchain["receiptId"] != rc["receiptId"]:
            raise RuntimeError("read-back receiptId mismatch")
        if onchain["amount"] != int(rc["amount"]):
            raise RuntimeError("read-back amount mismatch")
        return {"txHash": txh.hex() if isinstance(txh, bytes) else str(txh), "block": rcp.blockNumber, "onchain": onchain}


# ── HTTP ─────────────────────────────────────────────────────────────────────
CFG = {}
STORE = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        pass

    def _send(self, code, obj, extra_headers=None):
        raw = json.dumps(obj, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/healthz":
            return self._send(200, {"ok": True, "backend": CFG["backend"], "anchored": bool(CFG["anchor"])})
        if p == "/pricing":
            return self._send(200, {"unit": "uYUAN", "decimals": 6, "pricing": CFG["pricing"]})
        if p == "/v1/models":
            return self._send(200, {"object": "list", "data": [{"id": "origin-mock-8b", "object": "model"}]})
        if p.startswith("/receipts/"):
            rid = p[len("/receipts/"):]
            rc = STORE.get(rid)
            if not rc:
                return self._send(404, {"error": "unknown receipt"})
            bad = verify_receipt(rc, CFG)
            return self._send(200 if not bad else 409, {"receipt": rc, "verified": not bad, "failures": bad})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != ROUTE:
            return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n).decode("utf-8", "replace") or "{}")
        except Exception as e:
            return self._send(400, {"error": "bad json: %s" % e})

        try:
            resp = call_mock(body) if CFG["backend"] == "mock" else call_upstream(CFG["upstream"], body)
        except urlerror.HTTPError as e:
            return self._send(502, {"error": "upstream %s" % e.code, "detail": e.read().decode("utf-8", "replace")[:400]})
        except Exception as e:
            return self._send(502, {"error": "upstream: %s" % e})

        rc = build_receipt(body, resp, CFG)
        if CFG["anchor"]:
            try:
                rc["anchor"] = CFG["anchor"].record(rc)
                rc["anchored"] = True
            except Exception as e:
                rc["anchor"] = {"error": str(e), "trace": __import__("traceback").format_exc()[-1200:]}
        STORE[rc["receiptId"]] = rc

        resp = dict(resp)
        resp["x_origin_receipt"] = rc
        self._send(200, resp, {"X-L5-Receipt-Id": rc["receiptId"], "X-L5-Amount": str(rc["amount"])})


def load_cfg(args):
    payer_key = args.payer_key or Account.create().key.hex()
    payer_acct = Account.from_key(payer_key)
    payee_key = args.payee_key or Account.create().key.hex()
    payee_acct = Account.from_key(payee_key)
    cfg = {
        "backend": "http" if args.upstream else "mock",
        "upstream": args.upstream,
        "payer": payer_acct.address,
        "payer_key_obj": payer_acct.key.hex() if hasattr(payer_acct.key, 'hex') else payer_acct.key,
        "payee": payee_acct.address,
        "token": args.token,
        "chain_id": args.chain_id,
        "verifying": args.x402,
        "ttl": args.ttl,
        "pricing": {"prompt_per_1k": args.prompt_price, "completion_per_1k": args.completion_price},
        "anchor": None,
        "anchor_key": args.anchor_key or payer_key,
        "rpc": args.rpc,
        "artifact": args.artifact,
    }
    if args.anchor:
        cfg["anchor"] = Anchor(cfg)
    return cfg


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8410)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--upstream", help="OpenAI-compatible base URL, e.g. http://127.0.0.1:8000/v1/chat/completions")
    ap.add_argument("--payer-key", help="payer signing key (demo default: random)")
    ap.add_argument("--payee-key", help="service key (demo default: random)")
    ap.add_argument("--token", default="0x" + "00" * 20)
    ap.add_argument("--chain-id", type=int, default=31337)
    ap.add_argument("--x402", default="0x" + "00" * 20, help="L5x402 contract address")
    ap.add_argument("--ttl", type=int, default=300)
    ap.add_argument("--prompt-price", type=int, default=DEFAULT_PRICING["prompt_per_1k"])
    ap.add_argument("--completion-price", type=int, default=DEFAULT_PRICING["completion_per_1k"])
    ap.add_argument("--anchor", action="store_true", help="write receipts to chain and read them back")
    ap.add_argument("--rpc", default="http://127.0.0.1:8599")
    ap.add_argument("--anchor-key", help="key that pays gas for recordReceipt")
    ap.add_argument("--artifact", default=os.environ.get("L5_ARTIFACT", ""),
                    help="dir holding out/L5x402.sol/L5x402.json")
    args = ap.parse_args(argv)

    global CFG
    CFG = load_cfg(args)
    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print("ORIGIN L5 meter gateway")
    print("  listen   http://%s:%d" % (args.host, args.port))
    print("  backend  %s" % (CFG["upstream"] or "mock (no GPU needed)"))
    print("  payer    %s" % CFG["payer"])
    print("  payee    %s" % CFG["payee"])
    print("  anchor   %s" % ("ON -> " + args.rpc if CFG["anchor"] else "off (signed receipt only)"))
    print("  pricing  %d/%d uYUAN per 1k prompt/completion tokens" % (args.prompt_price, args.completion_price))
    sys.stdout.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
