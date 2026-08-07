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
NCHUNK="${2:-12}"
cd "$(dirname "$0")"
rm -rf mc_chunks; mkdir -p mc_chunks
for i in $(seq 0 $((NCHUNK-1))); do
  echo "=== chunk $i of $NCHUNK ==="
  /usr/bin/time -f "  chunk $i peak RSS %M KB, %e s" \
    octave --no-gui --quiet --eval "MC_CHUNK=$i; MC_NCHUNK=$NCHUNK; main_${SCRIPT}_monte_carlo" \
    || octave --no-gui --quiet --eval "MC_CHUNK=$i; MC_NCHUNK=$NCHUNK; main_${SCRIPT}_monte_carlo"
done
echo "=== aggregating ==="
octave --no-gui --quiet --eval "mc_aggregate('$SCRIPT')"
