#!/usr/bin/env python3
"""Mint a Flexo MMS bearer token (HS256), stdlib only.

The auth-service issues tokens with these claims; layer1-service verifies them
with the shared JWT_SECRET and resolves the user IRI as
<root_context>/users/<username>, so `username` must match an mms:id in
mount/cluster.trig (e.g. "ldap/user/user01").

Prints the full header value, "Bearer <jwt>", on one line.
"""
import argparse, base64, hashlib, hmac, json, os, sys, time


def b64u(raw: bytes) -> bytes:
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def mint(secret, username, groups, audience, issuer, hours):
    now = int(time.time())
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "aud": audience,
        "iss": issuer,
        "username": username,
        "groups": groups,
        "iat": now,
        "exp": now + int(hours * 3600),
    }
    signing_input = b".".join(
        b64u(json.dumps(part, separators=(",", ":")).encode())
        for part in (header, payload)
    )
    sig = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    return (signing_input + b"." + b64u(sig)).decode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secret", default=os.environ.get("JWT_SECRET"))
    ap.add_argument("--user", default="ldap/user/user01")
    ap.add_argument("--groups", default="super_admins")
    ap.add_argument("--audience", default=os.environ.get("JWT_AUDIENCE", "flexo-mms-audience"))
    ap.add_argument("--issuer", default=os.environ.get("JWT_DOMAIN", "http://flexo-mms-services"))
    ap.add_argument("--hours", type=float, default=24 * 365)
    ap.add_argument("--no-prefix", action="store_true")
    a = ap.parse_args()
    if not a.secret:
        sys.exit("mint-token: no --secret and no JWT_SECRET in the environment")
    groups = [g.strip() for g in a.groups.split(",") if g.strip()]
    tok = mint(a.secret, a.user, groups, a.audience, a.issuer, a.hours)
    print(tok if a.no_prefix else "Bearer " + tok)


if __name__ == "__main__":
    main()
