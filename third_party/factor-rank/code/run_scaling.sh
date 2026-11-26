#!/usr/bin/env bash
# Large-n asymptotic-separation sweep driver (paper thm:separation).
#
# Runs each (family, size, backend) cell as a SEPARATE process, so a TDD
# compile that OOMs at the exponential wall kills only its own process — never
# a sibling backend and never this driver. Each successful/timed-out cell
# writes its own CSV row (the binary does this); if a cell's process exits
# non-zero (crash / OOM-kill / abort) the driver appends a status=oom row so no
# cell is silently lost.
#
# Usage:
#   ./run_scaling.sh                       # full sweep, 1800s/cell timeout
#   TIMEOUT_S=600 ./run_scaling.sh         # shorter per-cell cap
#   MEM_LIMIT_KB=16000000 ./run_scaling.sh # best-effort address-space cap (Linux)
#
# Output: bench_out_scaling/runs.csv (13 columns; header written by the binary).
set -u

BIN="./target/release/scaling"
OUT="${OUT:-bench_out_scaling/runs.csv}"
TIMEOUT_S="${TIMEOUT_S:-1800}"
MEM_LIMIT_KB="${MEM_LIMIT_KB:-0}"   # 0 = no ulimit; else `ulimit -v` KB (Linux; often a no-op on macOS)

if [ ! -x "$BIN" ]; then
  echo "error: $BIN not found — run: cargo build --release" >&2
  exit 1
fi
mkdir -p "$(dirname "$OUT")"

# Cell grid. MUX carries the scaling story (CNF route, no 2^n); HWB is capped
# at n~20-22 by the 2^n truth-table constructor (both backends).
MUX_SIZES=(2 3 4 5 6 7)          # k; n = k + 2^k = 6,11,20,37,70,135
HWB_SIZES=(6 8 10 12 14 16 18 20)  # n (22 optional; add if memory allows)
BACKENDS=(tdd atdd)

run_cell () {
  local family="$1" size="$2" backend="$3"
  local n nc vt
  if [ "$family" = "mux" ]; then
    n=$(( size + (1 << size) )); nc=$(( 1 << size )); vt="mux_data"
  else
    n="$size"; nc=0; vt="rl_id"
  fi
  echo "=== $family size=$size backend=$backend (n=$n) ==="
  # Optional best-effort address-space cap, applied in the child subshell only.
  ( if [ "$MEM_LIMIT_KB" -gt 0 ]; then ulimit -v "$MEM_LIMIT_KB" 2>/dev/null || true; fi
    exec "$BIN" --family "$family" --size "$size" --backend "$backend" \
         --out "$OUT" --timeout-s "$TIMEOUT_S" )
  local rc=$?
  if [ $rc -ne 0 ]; then
    # Process died before banking a row (OOM-kill / abort / mem-cap). Record it.
    echo "$family,$size,$n,$nc,$backend,$vt,oom,,0,0,,," >> "$OUT"
    echo "  -> exit $rc: recorded status=oom"
  fi
}

for k in "${MUX_SIZES[@]}"; do
  for be in "${BACKENDS[@]}"; do
    run_cell mux "$k" "$be"
  done
done
for n in "${HWB_SIZES[@]}"; do
  for be in "${BACKENDS[@]}"; do
    run_cell hwb "$n" "$be"
  done
done

echo "sweep complete -> $OUT"
