#!/usr/bin/env bash
# =============================================================================
# ffi helper for test/mainnet-fork/Fork0xReplay.t.sol
#
# Fetches a FIRM 0x AllowanceHolder quote (chain 4663) and emits, on stdout,
# abi-encoded (address to, bytes data, uint256 buyAmount, uint256 minBuyAmount)
# for vm.ffi to decode. Everything else goes to stderr.
#
# Args: <sellToken> <buyToken> <sellAmount> <taker> [slippageBps=50]
#
# The API key is taken from $ZEROX_API_KEY, falling back to the gitignored
# ../bowstring-backend/.env.mainnet (cwd is the bowstring-contracts root when
# invoked via vm.ffi). The key is never echoed.
# =============================================================================
set -euo pipefail

SELL=$1; BUY=$2; AMT=$3; TAKER=$4; SLIP=${5:-50}

KEY="${ZEROX_API_KEY:-}"
if [ -z "$KEY" ] && [ -f ../bowstring-backend/.env.mainnet ]; then
  KEY=$(grep '^ZEROX_API_KEY=' ../bowstring-backend/.env.mainnet | cut -d= -f2)
fi
if [ -z "$KEY" ]; then
  echo "fetch-0x-quote: ZEROX_API_KEY not set and .env.mainnet not found" >&2
  exit 1
fi

RESP=$(curl -sS --max-time 15 \
  -H "0x-api-key: $KEY" -H "0x-version: v2" \
  "https://api.0x.org/swap/allowance-holder/quote?chainId=4663&sellToken=$SELL&buyToken=$BUY&sellAmount=$AMT&taker=$TAKER&slippageBps=$SLIP")

if [ "$(echo "$RESP" | jq -r '.liquidityAvailable // false')" != "true" ]; then
  echo "fetch-0x-quote: no liquidity or API error: $(echo "$RESP" | jq -c '{name, message}' 2>/dev/null || echo "$RESP" | head -c 200)" >&2
  exit 1
fi

TO=$(echo "$RESP" | jq -r '.transaction.to')
DATA=$(echo "$RESP" | jq -r '.transaction.data')
BUYAMT=$(echo "$RESP" | jq -r '.buyAmount')
MINBUY=$(echo "$RESP" | jq -r '.minBuyAmount')

if [ -z "$TO" ] || [ "$TO" = "null" ] || [ -z "$DATA" ] || [ "$DATA" = "null" ]; then
  echo "fetch-0x-quote: quote missing transaction.to/data" >&2
  exit 1
fi

cast abi-encode "q(address,bytes,uint256,uint256)" "$TO" "$DATA" "$BUYAMT" "$MINBUY"
