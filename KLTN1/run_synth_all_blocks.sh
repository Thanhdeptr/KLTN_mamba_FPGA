#!/usr/bin/env bash
# Deprecated alias: use run_synth_chain_blocks.sh for production chain blocks.
exec "$(cd "$(dirname "$0")" && pwd)/run_synth_chain_blocks.sh" "$@"
