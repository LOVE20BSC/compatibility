#!/usr/bin/env bash
# Runs one profile end to end.
#
#   ./script/run.sh <profile>              # verify sources, then run the suite
#   ./script/run.sh bsc56_public --no-verify
#
# Add a network by dropping a JSON file into config/networks/; nothing here knows any address.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.foundry/bin:$PATH"

PROFILE="${1:-anvil}"
shift || true

FORGE_ARGS=()
RUN_VERIFY=1
for arg in "$@"; do
  case "$arg" in
    --no-verify) RUN_VERIFY=0 ;;
    *) FORGE_ARGS+=("$arg") ;;
  esac
done

CONFIG="config/networks/${PROFILE}.json"
test -f "$CONFIG" || { echo "unknown profile: $PROFILE"; exit 1; }

read_cfg() { python3 -c "import json,sys;d=json.load(open('$CONFIG'));print(d.get('$1',''))"; }

MODE="$(read_cfg mode)"
CHAIN_ID="$(read_cfg chainId)"
FORK_BLOCK="$(read_cfg forkBlock)"
RPC="$(python3 -c "import json;print(json.load(open('$CONFIG'))['rpc'][0] if json.load(open('$CONFIG'))['rpc'] else '')")"

RESULTS="results/${PROFILE}"
mkdir -p "$RESULTS"

export COMPAT_PROFILE="$PROFILE"
export COMPAT_RESULTS_DIR="$RESULTS"
export COMPAT_CHAIN_ID="$CHAIN_ID"

if [ "$MODE" = "local" ]; then
  # The local baseline deploys the pinned Uniswap V2 reference; its artefacts have to exist first.
  export COMPAT_LOCAL=true
  for p in ref-uni-core ref-uni-periphery ref-weth; do forge build --profile "$p" >/dev/null; done
else
  export COMPAT_LOCAL=false
  export COMPAT_RPC_URL="$RPC"
  export COMPAT_FORK_BLOCK="$FORK_BLOCK"
  export COMPAT_WBNB="$(python3 -c "import json;print(json.load(open('$CONFIG'))['addresses']['wbnb'])")"
  export COMPAT_FACTORY="$(python3 -c "import json;print(json.load(open('$CONFIG'))['addresses']['factory'])")"
  export COMPAT_ROUTER="$(python3 -c "import json;print(json.load(open('$CONFIG'))['addresses']['router'])")"
fi

echo "== profile $PROFILE (mode=$MODE, chain=$CHAIN_ID, fork-block=${FORK_BLOCK:-latest}) =="

if [ "$RUN_VERIFY" -eq 1 ]; then
  python3 -u script/verify_source.py "$PROFILE" || echo "source verification reported mismatches"
fi

forge test --profile default -vv ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} 2>&1 | tee "$RESULTS/forge-test.log"

echo "== evidence written to $RESULTS =="
