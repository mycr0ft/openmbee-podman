#!/usr/bin/env bash
# Shared helpers. Sourced by the other scripts after they cd to the repo root.
#
# dotenv KEY [DEFAULT]: read one value out of .env.
# .env is never `source`d: values such as FLEXO_AUTH="Bearer eyJ..." contain
# spaces and would be executed as commands by the shell.
dotenv() {
  local v
  v=$(python3 bin/envset.py "${ENV_FILE:-.env}" "$1" 2>/dev/null || true)
  printf '%s' "${v:-${2:-}}"
}

# base URLs derived from .env, exported as B, L1, AUTH, STORE, SYS, QUAD
load_urls() {
  export BIND_ADDR="$(dotenv BIND_ADDR 127.0.0.1)"
  B="http://${BIND_ADDR}"
  L1="$B:$(dotenv LAYER1_PORT 8080)"
  AUTH="$B:$(dotenv AUTH_PORT 8082)"
  STORE="$B:$(dotenv STORE_PORT 18081)"
  SYS="$B:$(dotenv SYSMLV2_PORT 18083)"
  QUAD="$B:$(dotenv QUAD_PORT 3030)"
  ORG="$(dotenv FLEXO_SYSMLV2_ORG sysmlv2)"
}
