#!/bin/bash
# Run a Monte Carlo script in memory-bounded chunks, then aggregate.
#
# WHY: glpk leaks ~46.5 MB per full-day simulation at nSegments=10 and Octave
# never releases it (`clear` does not help -- the memory is held at the C
# level). Only process exit frees it. main_month4e runs 300 day-sims, i.e.
# ~14 GB in one process. Chunking is EXACT, not an approximation: draws are
# independent and seeded per draw index.
#
# Budget rule: ~46.5 MB x (draws per chunk) x (configs per draw).
#   month4e, 5 draws/chunk x 5 configs = 25 day-sims ~ 1.2 GB.
#
# Usage:  ./run_chunked.sh [script] [nchunks]
set -e
SCRIPT="${1:-month4e}"
# Default chunk counts follow the budget rule ~46.5 MB x draws/chunk x sims/draw:
#   month4e  5 draws x 5 sims = 25 ~ 1.2 GB -> 12 chunks
#   month4i  5 draws x 5 sims = 25 ~ 1.1 GB -> 12 chunks
#   month4j  3 draws x 8 sims = 24 ~ 1.1 GB -> 20 chunks (2 prices x 4 configs)
case "$SCRIPT" in
  month4j) DEF=20 ;;
  *)       DEF=12 ;;
esac
NCHUNK="${2:-$DEF}"
cd "$(dirname "$0")"
case "$SCRIPT" in
  month4e) ENTRY=main_month4e_monte_carlo ;;
  month4i) ENTRY=main_month4i_heatpump_pwl_gate ;;
  month4j) ENTRY=main_month4j_pwl_device_table ;;
  *) echo "unknown script: $SCRIPT"; exit 1 ;;
esac
rm -rf mc_chunks; mkdir -p mc_chunks
for i in $(seq 0 $((NCHUNK-1))); do
  echo "=== chunk $i of $NCHUNK ==="
  /usr/bin/time -f "  chunk $i peak RSS %M KB, %e s" \
    octave --no-gui --quiet --eval "MC_CHUNK=$i; MC_NCHUNK=$NCHUNK; $ENTRY" \
    || octave --no-gui --quiet --eval "MC_CHUNK=$i; MC_NCHUNK=$NCHUNK; $ENTRY"
done
echo "=== aggregating ==="
octave --no-gui --quiet --eval "mc_aggregate('$SCRIPT')"
