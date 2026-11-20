#!/usr/bin/env python3
"""Set KEY=value in a .env file, preserving comments and order.

usage: envset.py FILE KEY value      (value is written verbatim, never quoted)
       envset.py FILE KEY            (prints the value, exit 1 if unset)
"""
import sys

path, key = sys.argv[1], sys.argv[2]

if len(sys.argv) == 3:
    for line in open(path):
        if line.strip().startswith(key + "="):
            print(line.split("=", 1)[1].rstrip("\n"))
            sys.exit(0)
    sys.exit(1)

value = sys.argv[3]
lines = open(path).read().splitlines(True)
out, done = [], False
for line in lines:
    if line.strip().startswith(key + "=") and not line.lstrip().startswith("#"):
        out.append(f"{key}={value}\n")
        done = True
    else:
        out.append(line)
if not done:
    out.append(f"{key}={value}\n")
open(path, "w").writelines(out)
