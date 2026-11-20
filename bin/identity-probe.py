#!/usr/bin/env python3
"""Probe element identity in flexo-sysmlv2.

Two experiments against a running stack:

  1. reproducibility: commit the same text into separate projects and compare
     the identifiers the parser assigned;
  2. rename fork: commit examples/hello.sysml, then the same model inside a
     renamed package, into one project, and compare identifiers per commit.

Part 1 shows element ids are name-based (UUIDv5) and survive re-parsing in a new
project. Part 2 shows a rename mints new ids and leaves the old elements in the
commit, because the service emits insertions only.

    python3 bin/identity-probe.py http://127.0.0.1:8083

Writes nothing; prints a report. Requires a token in .env (make token does it).
"""
import json
import subprocess
import sys
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8083"
TOKEN = subprocess.run(["python3", "bin/envset.py", ".env", "FLEXO_AUTH"],
                       capture_output=True, text=True, check=True).stdout.strip()
KINDS = ("Package", "PartDefinition", "PartUsage", "RequirementDefinition")


def req(path, method="GET", body=None, ctype=None):
    headers = {"Authorization": TOKEN}
    if ctype:
        headers["Content-Type"] = ctype
    data = body.encode() if isinstance(body, str) else body
    r = urllib.request.Request(BASE + path, method=method, headers=headers, data=data)
    with urllib.request.urlopen(r, timeout=120) as resp:
        return json.load(resp)


def one(d):
    return d[0] if isinstance(d, list) else d


def new_project(name):
    p = one(req("/projects", "POST", json.dumps({"@type": "Project", "name": name}),
               "application/json"))
    return p["@id"].rsplit("/", 1)[-1]


def commit(pid, text):
    c = one(req(f"/projects/{pid}/commits", "POST", text, "text/plain"))
    return c["@id"]


def shapes(pid, cid):
    """(kind, declaredName, uuid) for every node the elements view exposes."""
    out = []

    def walk(n):
        if isinstance(n, dict):
            if n.get("@type") in KINDS:
                out.append((n["@type"], n.get("declaredName"), n["@id"].rsplit("/", 1)[-1]))
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)

    walk(req(f"/projects/{pid}/commits/{cid}/elements"))
    return sorted({x for x in out if x[1]})


def main():
    text = open("examples/hello.sysml").read()
    renamed = text.replace("package HelloWorld {", "package HelloWorldRenamed {", 1)

    print("== experiment 1: same text, separate projects")
    seen = {}
    pids = [new_project(f"identity-probe-a-{i}") for i in (1, 2)]
    for pid in pids:
        cid = commit(pid, text)
        rows = shapes(pid, cid)
        print(f" -- project {pid} commit {cid}")
        for kind, name, uid in rows:
            print(f"    {kind:20s} {name:22s} {uid}")
            seen.setdefault((kind, name), set()).add(uid)
    stable = all(len(v) == 1 for v in seen.values())
    print(f" -> identical identifiers across projects: {stable}")

    print("== experiment 2: rename an ancestor inside one project")
    pid = new_project("identity-probe-rename")
    c1 = commit(pid, text)
    c2 = commit(pid, renamed)
    print(f" -- project {pid}")
    for label, cid in (("before rename", c1), ("after rename", c2)):
        print(f" {label} (commit {cid})")
        for kind, name, uid in shapes(pid, cid):
            print(f"    {kind:20s} {name:22s} {uid}")


main()
