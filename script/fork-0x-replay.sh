#!/usr/bin/env bash
# =============================================================================
# Fork0xReplay runner — the "live 0x quote pre-deploy" verification from the
# 2026-07-08 mainnet migration plan (implemented as a gated fork test rather
# than a .s.sol script so it gets asserts + ForkBase for free).
#
# Pulls a REAL firm 0x quote and settles it through the production staged path
# (TradeDelegateProxyV2 -> MainnetExecutionEngine -> 0x AllowanceHolder) on a
# fork of Robinhood Chain mainnet (4663). Network-only: NOTHING is broadcast.
#
# Usage:  ./script/fork-0x-replay.sh
# Env:    ZEROX_API_KEY     — taken from ../bowstring-backend/.env.mainnet if unset
#         REPLAY_BUY_TOKEN  — buy-token override (default WETH; use the AAPL
#                             address once the 0x equities entitlement lands)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${ZEROX_API_KEY:-}" ] && [ -f ../bowstring-backend/.env.mainnet ]; then
  ZEROX_API_KEY=$(grep '^ZEROX_API_KEY=' ../bowstring-backend/.env.mainnet | cut -d= -f2)
  export ZEROX_API_KEY
fi

MAINNET_FORK=true ZEROX_REPLAY=true forge test --match-contract Fork0xReplay --ffi -vvv
