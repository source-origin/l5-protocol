#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""rpc_shim.py — a small JSON-RPC node over py-evm, for when anvil cannot run.

Why this exists
---------------
`anvil.exe` is blocked on this machine by application control policy
(WinError 4551). That is an OS decision, not a bug to route around by disabling
the policy. But the *product* path (gateway -> JSON-RPC -> chain) must still be
exercised end to end, so this shim speaks the same JSON-RPC over HTTP that anvil
would. Nothing in the gateway knows the difference; that is the point.

Honesty notes:
  * This is py-evm, a real EVM, mining one block per transaction. It is a real
    chain in the sense that state transitions are real; it is NOT a network, and
    it has no consensus. Do not cite it as "tested on a network".
  * The dev accounts are py-evm's public defaults. No funds, ever.
  * If a method is missing, it returns a JSON-RPC error rather than a plausible
    empty result -- a silently wrong answer is worse than a loud absence.

Usage:
    python tools/rpc_shim.py --port 8703 [--chain-id 31337]
"""
import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

from eth_tester import EthereumTester, PyEVMBackend
from eth_tester.exceptions import TransactionFailed, BlockNotFound, TransactionNotFound

LOCK = threading.Lock()
T = None
CHAIN_ID = 31337
# A real node holds nonce gaps in its mempool and mines them later. forge broadcasts
# the eight deploys concurrently, so they arrive out of order and a bare
# eth_tester would reject the ones that are "too far ahead". This is the smallest
# honest version of a mempool: hold out-of-order raw txs, release them in nonce
# order as the account catches up. It is NOT a fee market and does not reorder
# by price -- anything that claims to need that should not use this shim.
PENDING = {}


def _sender_and_nonce(raw_hex, msg):
    """Recover (sender, nonce) for a rejected raw tx. nonce comes from the error
    the VM just raised, so we never have to re-implement typed-tx decoding."""
    from eth_account import Account
    sender = Account.recover_transaction(raw_hex)
    n = None
    marker = "but got "
    if marker in msg:
        try:
            n = int(msg.rsplit(marker, 1)[1].strip().rstrip("."))
        except ValueError:
            n = None
    return sender, n


def _drain_pending():
    """Send every held tx whose nonce is now current, one at a time."""
    progressed = True
    while progressed:
        progressed = False
        for key in list(PENDING.keys()):
            sender, nonce = key
            if T.get_nonce(sender) != nonce:
                continue
            raw = PENDING.pop(key)
            try:
                T.send_raw_transaction(raw)
                progressed = True
            except Exception:
                PENDING[key] = raw
                break


def hx(v):
    if isinstance(v, str):
        return v
    if v is None:
        return None
    return hex(int(v))


def data(v):
    if v is None:
        return "0x"
    if isinstance(v, str):
        return v if v.startswith("0x") else "0x" + v
    return "0x" + bytes(v).hex()


def to_int(v, default=0):
    if v is None:
        return default
    if isinstance(v, int):
        return v
    if isinstance(v, str):
        return int(v, 16) if v.startswith("0x") else int(v)
    return int(v)


def to_bytes(v):
    """eth_tester hands back either bytes or 0x-hex or bare hex depending on the
    field; guessing wrong turns a padding bug into a TypeError deep in a lambda."""
    if v is None:
        return b""
    if isinstance(v, (bytes, bytearray)):
        return bytes(v)
    if isinstance(v, int):
        return v.to_bytes(max(1, (v.bit_length() + 7) // 8), "big")
    if isinstance(v, str):
        s = v[2:] if v.startswith("0x") else v
        if not s:
            return b""
        try:
            return bytes.fromhex(s)
        except ValueError:
            return b""
    return b""


def fixed(v, nbytes, default=None):
    """Fixed-width byte field. `0x`-length fields break strict JSON clients (alloy
    literally refuses to parse a block whose logsBloom is empty), so pad to width."""
    b = to_bytes(v)
    if not b:
        b = default if default is not None else b"\x00" * nbytes
    if len(b) < nbytes:
        b = b"\x00" * (nbytes - len(b)) + b
    return "0x" + b[:nbytes].hex()


BLOCK_FIELDS = [
    ("number", "number", hx),
    ("hash", "hash", data),
    ("parentHash", "parent_hash", data),
    ("nonce", "nonce", lambda v: fixed(v, 8)),
    ("sha3Uncles", "sha3_uncles", lambda v: fixed(v, 32, bytes.fromhex("1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347"))),
    ("logsBloom", "logs_bloom", lambda v: fixed(v, 256)),
    ("transactionsRoot", "transactions_root", lambda v: fixed(v, 32)),
    ("stateRoot", "state_root", lambda v: fixed(v, 32)),
    ("receiptsRoot", "receipts_root", lambda v: fixed(v, 32)),
    ("miner", "coinbase", data),
    ("difficulty", "difficulty", hx),
    ("totalDifficulty", "total_difficulty", hx),
    ("extraData", "extra_data", lambda v: fixed(v, max(32, len(to_bytes(v))))),
    ("size", "size", hx),
    ("gasLimit", "gas_limit", hx),
    ("gasUsed", "gas_used", hx),
    ("timestamp", "timestamp", hx),
    ("mixHash", "mix_hash", lambda v: fixed(v, 32)),
    ("baseFeePerGas", "base_fee_per_gas", hx),
]


def shape_block(b):
    out = {}
    for camel, snake, conv in BLOCK_FIELDS:
        out[camel] = conv(b.get(snake))
    txs = b.get("transactions") or []
    out["transactions"] = [data(x) if isinstance(x, (bytes, str)) else x for x in txs]
    out["uncles"] = [data(x) for x in (b.get("uncles") or [])]
    return out


def addr(v):
    """Address field, or None. `0x` is not a valid address and strict clients
    (web3's contractAddress formatter) refuse to parse it -- a receipt for a
    non-creation tx must say null, not empty string."""
    b = to_bytes(v)
    return None if not b else "0x" + b.hex()


def shape_receipt(r):
    return {
        "transactionHash": data(r.get("transactionHash")),
        "transactionIndex": hx(r.get("transactionIndex")),
        "blockHash": data(r.get("blockHash")),
        "blockNumber": hx(r.get("blockNumber")),
        "from": addr(r.get("from")),
        "to": addr(r.get("to")),
        "cumulativeGasUsed": hx(r.get("cumulativeGasUsed")),
        "gasUsed": hx(r.get("gasUsed")),
        "contractAddress": addr(r.get("contractAddress")),
        "logs": [
            {
                "address": data(l.get("address")),
                "topics": [data(t) for t in (l.get("topics") or [])],
                "data": data(l.get("data")),
                "logIndex": hx(l.get("logIndex")),
                "transactionIndex": hx(l.get("transactionIndex")),
                "transactionHash": data(l.get("transactionHash")),
                "blockHash": data(l.get("blockHash")),
                "blockNumber": hx(l.get("blockNumber")),
                "removed": bool(l.get("removed", False)),
            }
            for l in (r.get("logs") or [])
        ],
        "logsBloom": fixed(r.get("logsBloom"), 256),
        "status": hx(r.get("status")),
        "effectiveGasPrice": hx(r.get("effectiveGasPrice", 1_000_000_000)),
        "type": hx(r.get("type", 2)),
    }


def tx_param(p):
    out = {}
    if not p:
        return out
    if p.get("from"):
        out["from"] = p["from"]
    if p.get("to"):
        out["to"] = p["to"]
    if p.get("gas") or p.get("gasLimit"):
        out["gas"] = to_int(p.get("gas") or p.get("gasLimit"))
    if p.get("data") or p.get("input"):
        out["data"] = p.get("data") or p.get("input")
    if p.get("value"):
        out["value"] = to_int(p["value"])
    if p.get("gasPrice"):
        out["gas_price"] = to_int(p["gasPrice"])
    if p.get("maxFeePerGas"):
        out["max_fee_per_gas"] = to_int(p["maxFeePerGas"])
    if p.get("maxPriorityFeePerGas"):
        out["max_priority_fee_per_gas"] = to_int(p["maxPriorityFeePerGas"])
    if p.get("nonce"):
        out["nonce"] = to_int(p["nonce"])
    return out


def blk(v):
    """`0x0` is a legal block number over JSON-RPC and illegal to eth_tester, which
    wants 0 or 'latest'. Translating here keeps every caller from having to know."""
    if v is None:
        return "latest"
    if isinstance(v, str) and v in ("latest", "earliest", "pending"):
        return "latest" if v == "pending" else v
    if isinstance(v, str) and v.startswith("0x"):
        return int(v, 16)
    if isinstance(v, str) and v.isdigit():
        return int(v)
    return v


def call(method, params):
    with LOCK:
        if method == "web3_clientVersion":
            return "rpc_shim/py-evm (anvil substitute; application-control blocked anvil)"
        if method == "net_version":
            return str(CHAIN_ID)
        if method == "eth_chainId":
            return hx(CHAIN_ID)
        if method == "eth_accounts":
            return T.get_accounts()
        if method == "eth_syncing":
            return False
        if method == "eth_blockNumber":
            return hx(T.get_block_by_number("latest")["number"])
        if method == "eth_gasPrice":
            return hx(1_000_000_000)
        if method == "eth_maxPriorityFeePerGas":
            return hx(1_000_000_000)
        if method == "eth_feeHistory":
            # forge asks for this when estimating 1559 fees; a flat history is honest here
            # because this chain has no competition for block space.
            count = to_int(params[0]) if params else 1
            newest = T.get_block_by_number("latest")["number"]
            base = to_int(T.get_block_by_number("latest").get("base_fee_per_gas") or 0)
            return {
                "oldestBlock": hx(max(0, newest - count + 1)),
                "baseFeePerGas": [hx(base)] * (count + 1),
                "gasUsedRatio": [0.0] * count,
                "reward": [[hx(1_000_000_000)] for _ in range(count)],
            }
        if method == "eth_getBalance":
            return hx(T.get_balance(params[0], blk(params[1] if len(params) > 1 else None)))
        if method == "eth_getTransactionCount":
            blkn = params[1] if len(params) > 1 else None
            base = T.get_nonce(params[0], blk(blkn))
            if blkn == "pending":
                base += sum(1 for (s, _n) in PENDING if s.lower() == params[0].lower())
            return hx(base)
        if method == "eth_getCode":
            return data(T.get_code(params[0], blk(params[1] if len(params) > 1 else None)))
        if method == "eth_getStorageAt":
            return data(T.get_storage_at(params[0], to_int(params[1]),
                                         blk(params[2] if len(params) > 2 else None)))
        if method == "eth_call":
            try:
                p = tx_param(params[0])
                # JSON-RPC allows eth_call without a sender; eth_tester does not.
                # A view call has no sender, so give it one that cannot move funds.
                p.setdefault("from", T.get_accounts()[0])
                return data(T.call(p, blk(params[1] if len(params) > 1 else None)))
            except TransactionFailed as e:
                # A revert must look like a revert, with its data, or forge/web3
                # will report "execution reverted" with no reason and we will be
                # debugging a wrapper instead of a contract.
                return {"__error__": {"code": 3, "message": "execution reverted: %s" % (e,),
                                      "data": getattr(e, "args", [None])[0] if getattr(e, "args", None) else None}}
        if method == "eth_estimateGas":
            p = tx_param(params[0])
            p.setdefault("from", T.get_accounts()[0])
            try:
                return hx(T.estimate_gas(p))
            except Exception:
                return hx(3_000_000)
        if method == "eth_sendRawTransaction":
            raw = params[0]
            try:
                h = T.send_raw_transaction(raw)
            except Exception as e:
                msg = str(e)
                if "Invalid transaction nonce" in msg:
                    sender, n = _sender_and_nonce(raw, msg)
                    if n is not None:
                        PENDING[(sender, n)] = raw
                        # Held, not lost. Returning the tx hash is what a real node
                        # does; the caller then polls eth_getTransactionReceipt.
                        from eth_utils import keccak
                        return data(keccak(bytes.fromhex(raw[2:])))
                raise
            _drain_pending()
            return data(h)
        if method == "eth_sendTransaction":
            h = T.send_transaction(tx_param(params[0]))
            return data(h)
        if method == "eth_getTransactionByHash":
            r = T.get_transaction_by_hash(params[0])
            out = {
                "hash": data(r.get("hash")),
                "nonce": hx(r.get("nonce")),
                "blockHash": data(r.get("blockHash")),
                "blockNumber": hx(r.get("blockNumber")),
                "transactionIndex": hx(r.get("transactionIndex")),
                "from": data(r.get("from")),
                "to": data(r.get("to")),
                "value": hx(r.get("value")),
                "gas": hx(r.get("gas")),
                "gasPrice": hx(r.get("gasPrice", 1_000_000_000)),
                "input": data(r.get("data") or r.get("input")),
                "type": hx(r.get("type", 0)),
            }
            return out
        if method == "eth_getTransactionReceipt":
            try:
                return shape_receipt(T.get_transaction_receipt(params[0]))
            except TransactionNotFound:
                # A held tx has no receipt yet. That is a true statement about this
                # node, and null is how JSON-RPC says it.
                return None
        if method in ("eth_getBlockByNumber", "eth_getBlockByHash"):
            full = bool(params[1]) if len(params) > 1 else False
            try:
                b = (T.get_block_by_number(blk(params[0]), full) if method == "eth_getBlockByNumber"
                     else T.get_block_by_hash(params[0], full))
            except (BlockNotFound, TransactionNotFound):
                return None
            if b is None:
                return None
            out = shape_block(b)
            if full:
                # eth_tester already expands when full=True; make sure hashes stay hex
                out["transactions"] = [data(t.get("hash")) if isinstance(t, dict) else data(t)
                                       for t in (b.get("transactions") or [])]
            return out
        if method == "eth_getLogs":
            f = params[0] if params else {}
            kw = {}
            if f.get("fromBlock"):
                kw["from_block"] = blk(f["fromBlock"])
            if f.get("toBlock"):
                kw["to_block"] = blk(f["toBlock"])
            if f.get("address"):
                kw["address"] = f["address"]
            if f.get("topics"):
                kw["topics"] = f["topics"]
            return [
                {
                    "address": data(l.get("address")),
                    "topics": [data(t) for t in (l.get("topics") or [])],
                    "data": data(l.get("data")),
                    "logIndex": hx(l.get("logIndex")),
                    "transactionIndex": hx(l.get("transactionIndex")),
                    "transactionHash": data(l.get("transactionHash")),
                    "blockHash": data(l.get("blockHash")),
                    "blockNumber": hx(l.get("blockNumber")),
                    "removed": False,
                }
                for l in T.get_logs(kw)
            ]
        raise KeyError("rpc_shim: method not implemented: %s" % method)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _write(self, obj, code=200):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(n).decode() or "{}")
        except Exception as e:
            return self._write({"jsonrpc": "2.0", "id": None,
                                "error": {"code": -32700, "message": "parse error: %s" % e}})
        batch = isinstance(req, list)
        items = req if batch else [req]
        out = []
        for it in items:
            rid = it.get("id")
            try:
                res = call(it.get("method"), it.get("params") or [])
                if isinstance(res, dict) and "__error__" in res:
                    out.append({"jsonrpc": "2.0", "id": rid, "error": res["__error__"]})
                else:
                    out.append({"jsonrpc": "2.0", "id": rid, "result": res})
            except KeyError as e:
                out.append({"jsonrpc": "2.0", "id": rid,
                            "error": {"code": -32601, "message": str(e).strip("'\"")}})
            except Exception as e:
                # Log enough to debug, not enough to dump an 8 KB deploy bytecode
                # into the transcript eight times.
                import traceback
                sys.stderr.write("rpc_shim: FAILED %s: %s: %s\n"
                                 % (it.get("method"), type(e).__name__, str(e)[:300]))
                traceback.print_exc(file=sys.stderr)
                sys.stderr.flush()
                out.append({"jsonrpc": "2.0", "id": rid,
                            "error": {"code": -32000, "message": "%s: %s" % (type(e).__name__, str(e)[:300])}})
        self._write(out if batch else out[0])


def main():
    global T, CHAIN_ID
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8703)
    ap.add_argument("--chain-id", type=int, default=0,
                    help="requested chain id; py-evm's backend may not honour it (see below)")
    ap.add_argument("--fund", action="append", default=[],
                    help="address to top up at startup (repeatable). forge signs with the "
                         "anvil dev key, whose address is NOT one of py-evm's defaults, "
                         "so without this every broadcast fails with 'balance 0'.")
    a = ap.parse_args()
    # py-evm 0.12 does not accept `chain_id` in genesis_parameters (it reaches
    # fill_header_params_from_parent and raises TypeError). Rather than monkey-patch
    # the VM, take whatever chain id the backend actually reports and print it --
    # the caller must use the real number, and an invented one would poison every
    # EIP-712 domain below it.
    T = EthereumTester(backend=PyEVMBackend())
    CHAIN_ID = int(T.backend.chain.chain_id)
    if a.chain_id and a.chain_id != CHAIN_ID:
        print("rpc_shim: requested chain-id %d, backend reports %d -- using the real one"
              % (a.chain_id, CHAIN_ID), flush=True)

    # Top up requested addresses from a default account. This is a funding transfer,
    # not a state hack: the balance has to exist in the same EVM that will check it.
    for addr in a.fund:
        if T.get_balance(addr) == 0:
            T.send_transaction({"from": T.get_accounts()[0], "to": addr,
                                "value": 1000 * 10 ** 18, "gas": 21000})
            print("rpc_shim: funded %s with 1000 ETH (balance now %d)"
                  % (addr, T.get_balance(addr)), flush=True)

    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print("rpc_shim listening on http://127.0.0.1:%d  chainId=%d" % (a.port, CHAIN_ID), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
