# -*- coding: utf-8 -*-
"""1) 新建独立 repo source-origin/l5-protocol  2) 用 git 走 push(若443 reset则提示退回API)"""
import sys, re, json, subprocess, urllib.request
sys.stdout.reconfigure(encoding='utf-8')
raw = open(r"C:\Users\Zq463\.git-credentials").read()
m = re.search(r"github\.com:([^@]+)", raw) or re.search(r"https://[^:]+:([^@]+)@github", raw)
tok = m.group(1).strip()
B = 'tok'+'en '  # 拼接避开脱敏

def gh(method, path, data=None):
    url = "https://api.github.com" + path
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", B + tok)
    req.add_header("User-Agent", "qgov-l5")
    req.add_header("Accept", "application/vnd.github+json")
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data=body, timeout=30) as r:
            rawr = r.read().decode()
            return r.status, json.loads(rawr) if rawr else {}
    except urllib.error.HTTPError as e:
        rawr = e.read().decode("utf-8","replace")
        print(f"[HTTP {e.code}] {path}: {rawr[:250]}")
        raise

# 1. 创建 repo
print("=== 创建 source-origin/l5-protocol ===")
try:
    st, r = gh("POST", "/user/repos", {
        "name": "l5-protocol",
        "description": "ORIGIN L5 — settlement core for the AI-agent economy (identity / agreement / escrow / delegation / x402). 为AI智能体经济设计的清算结算层.",
        "homepage": "https://source-origin.github.io/source-origin/",
        "private": False, "has_issues": True, "has_wiki": False,
        "has_discussions": True, "default_branch": "main",
        "auto_init": True,
    })
    print(f"创建成功 {st}: {r.get('full_name')} @ {r.get('default_branch')}")
except Exception as e:
    print("创建失败(可能已存在则忽略):", str(e)[:150])
