#!/bin/bash
# =============================================================================
# Local AI Stack Benchmark Suite
# Run BEFORE and AFTER hardware optimization to measure improvements
#
# Usage:
#   chmod +x benchmark.sh
#   ./benchmark.sh                    # System-level benchmarks only
#   ./benchmark.sh --with-ollama      # System + Ollama LLM benchmarks
#   ./benchmark.sh --host larvikite   # Tag results with hostname override
#
# Results saved to: ./benchmark-results/<hostname>-<timestamp>.txt
# =============================================================================

set -euo pipefail

WITH_OLLAMA=false
HOST_OVERRIDE=""

for arg in "$@"; do
  case $arg in
    --with-ollama) WITH_OLLAMA=true ;;
    --host) HOST_OVERRIDE="next" ;;
    *)
      if [[ "$HOST_OVERRIDE" == "next" ]]; then
        HOST_OVERRIDE="$arg"
      fi
      ;;
  esac
done

HOSTNAME="${HOST_OVERRIDE:-$(hostname)}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="./benchmark-results"
RESULTS_FILE="${RESULTS_DIR}/${HOSTNAME}-${TIMESTAMP}.txt"

mkdir -p "$RESULTS_DIR"

log() {
  echo "$1" | tee -a "$RESULTS_FILE"
}

separator() {
  log ""
  log "================================================================"
  log "$1"
  log "================================================================"
}

# =============================================================================
# SYSTEM INFO
# =============================================================================
separator "SYSTEM INFORMATION"

log "Hostname:  $HOSTNAME"
log "Date:      $(date)"
log "Kernel:    $(uname -r)"
log ""

log "--- CPU ---"
lscpu | grep -E "Model name|Socket|Core|Thread|CPU MHz|CPU max|CPU min" | tee -a "$RESULTS_FILE"
log ""

log "--- Memory ---"
free -h | tee -a "$RESULTS_FILE"
log ""
log "Total DIMMs populated: $(dmidecode -t memory 2>/dev/null | grep -c 'Size: [0-9]' || echo 'N/A (need root)')"
log "Configured speed:      $(dmidecode -t memory 2>/dev/null | grep 'Configured Memory Speed' | head -1 | awk '{print $4, $5}' || echo 'N/A (need root)')"
log "Rated speed:           $(dmidecode -t memory 2>/dev/null | grep 'Speed:' | grep -v Configured | head -1 | awk '{print $2, $3}' || echo 'N/A (need root)')"

# =============================================================================
# MEMORY BANDWIDTH - STREAM benchmark
# =============================================================================
separator "MEMORY BANDWIDTH (STREAM)"

# Install if needed
if ! command -v gcc &>/dev/null; then
  log "Installing gcc..."
  apt-get install -y gcc >/dev/null 2>&1 || yum install -y gcc >/dev/null 2>&1
fi

STREAM_DIR="/tmp/stream-bench"
mkdir -p "$STREAM_DIR"

if [[ ! -f "$STREAM_DIR/stream" ]]; then
  log "Downloading and compiling STREAM benchmark..."
  cat > "$STREAM_DIR/stream.c" << 'STREAMCODE'
/*  STREAM benchmark - simplified single-file version  */
#include <stdio.h>
#include <stdlib.h>
#include <float.h>
#include <limits.h>
#include <sys/time.h>

#ifndef STREAM_ARRAY_SIZE
#define STREAM_ARRAY_SIZE 80000000
#endif

#ifndef NTIMES
#define NTIMES 10
#endif

static double a[STREAM_ARRAY_SIZE], b[STREAM_ARRAY_SIZE], c[STREAM_ARRAY_SIZE];

static double mysecond() {
    struct timeval tp;
    gettimeofday(&tp, NULL);
    return ((double)tp.tv_sec + (double)tp.tv_usec * 1.e-6);
}

int main() {
    int j, k;
    double times[4][NTIMES];
    double avgtime[4] = {0}, maxtime[4] = {0}, mintime[4] = {FLT_MAX, FLT_MAX, FLT_MAX, FLT_MAX};
    double bytes[4] = {
        2 * sizeof(double) * STREAM_ARRAY_SIZE,  // Copy
        2 * sizeof(double) * STREAM_ARRAY_SIZE,  // Scale
        3 * sizeof(double) * STREAM_ARRAY_SIZE,  // Add
        3 * sizeof(double) * STREAM_ARRAY_SIZE   // Triad
    };
    char *label[4] = {"Copy:  ", "Scale: ", "Add:   ", "Triad: "};
    double scalar = 3.0;

    for (j = 0; j < STREAM_ARRAY_SIZE; j++) {
        a[j] = 1.0; b[j] = 2.0; c[j] = 0.0;
    }

    for (k = 0; k < NTIMES; k++) {
        times[0][k] = mysecond();
        for (j = 0; j < STREAM_ARRAY_SIZE; j++) c[j] = a[j];
        times[0][k] = mysecond() - times[0][k];

        times[1][k] = mysecond();
        for (j = 0; j < STREAM_ARRAY_SIZE; j++) b[j] = scalar * c[j];
        times[1][k] = mysecond() - times[1][k];

        times[2][k] = mysecond();
        for (j = 0; j < STREAM_ARRAY_SIZE; j++) c[j] = a[j] + b[j];
        times[2][k] = mysecond() - times[2][k];

        times[3][k] = mysecond();
        for (j = 0; j < STREAM_ARRAY_SIZE; j++) a[j] = b[j] + scalar * c[j];
        times[3][k] = mysecond() - times[3][k];
    }

    for (k = 1; k < NTIMES; k++) {
        for (j = 0; j < 4; j++) {
            avgtime[j] += times[j][k];
            if (times[j][k] < mintime[j]) mintime[j] = times[j][k];
            if (times[j][k] > maxtime[j]) maxtime[j] = times[j][k];
        }
    }

    printf("Function    Best Rate MB/s  Avg time     Min time     Max time\n");
    for (j = 0; j < 4; j++) {
        avgtime[j] /= (double)(NTIMES - 1);
        printf("%s%12.1f  %11.6f  %11.6f  %11.6f\n", label[j],
            1.0E-06 * bytes[j] / mintime[j], avgtime[j], mintime[j], maxtime[j]);
    }
    return 0;
}
STREAMCODE

  gcc -O3 -fopenmp -DSTREAM_ARRAY_SIZE=80000000 -DNTIMES=20 \
    "$STREAM_DIR/stream.c" -o "$STREAM_DIR/stream" 2>/dev/null || \
  gcc -O3 -DSTREAM_ARRAY_SIZE=80000000 -DNTIMES=20 \
    "$STREAM_DIR/stream.c" -o "$STREAM_DIR/stream"
fi

log "Running STREAM (this measures actual memory bandwidth)..."
log ""
OMP_NUM_THREADS=$(nproc) "$STREAM_DIR/stream" 2>&1 | tee -a "$RESULTS_FILE"

# =============================================================================
# MEMORY LATENCY - simple pointer chase
# =============================================================================
separator "MEMORY LATENCY (dd throughput proxy)"

log "Sequential read throughput (cached):"
dd if=/dev/zero of=/dev/null bs=1M count=10000 2>&1 | tail -1 | tee -a "$RESULTS_FILE"
log ""
log "Sequential write to tmpfs:"
TMPFS_DIR="/tmp/bench-tmpfs"
mkdir -p "$TMPFS_DIR"
dd if=/dev/zero of="$TMPFS_DIR/test" bs=1M count=4096 conv=fdatasync 2>&1 | tail -1 | tee -a "$RESULTS_FILE"
rm -f "$TMPFS_DIR/test"

# =============================================================================
# CPU MULTI-CORE (simple compile benchmark)
# =============================================================================
separator "CPU MULTI-CORE (kernel compile simulation)"

log "Compiling STREAM with all cores as a quick multi-core stress indicator..."
COMPILE_START=$(date +%s%N)
for i in $(seq 1 3); do
  gcc -O3 -DSTREAM_ARRAY_SIZE=80000000 "$STREAM_DIR/stream.c" -o /dev/null 2>/dev/null &
done
wait
COMPILE_END=$(date +%s%N)
COMPILE_MS=$(( (COMPILE_END - COMPILE_START) / 1000000 ))
log "3x parallel compiles completed in: ${COMPILE_MS}ms"

# =============================================================================
# NUMA TOPOLOGY
# =============================================================================
separator "NUMA TOPOLOGY"

if command -v numactl &>/dev/null; then
  numactl --hardware 2>&1 | tee -a "$RESULTS_FILE"
else
  log "numactl not installed — install with: apt install numactl"
  if [[ -d /sys/devices/system/node ]]; then
    for node in /sys/devices/system/node/node*; do
      nodeid=$(basename "$node")
      meminfo=$(cat "$node/meminfo" 2>/dev/null | grep MemTotal | awk '{print $4, $5}')
      cpulist=$(cat "$node/cpulist" 2>/dev/null)
      log "$nodeid: CPUs=$cpulist  MemTotal=$meminfo"
    done
  fi
fi

# =============================================================================
# OLLAMA LLM BENCHMARKS (optional)
# =============================================================================
if $WITH_OLLAMA; then
  separator "OLLAMA LLM INFERENCE BENCHMARKS"

  if ! command -v curl &>/dev/null; then
    log "curl not found, skipping Ollama benchmarks"
  elif ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
    log "Ollama not reachable at localhost:11434, skipping"
    log "Make sure Ollama is running: systemctl status ollama"
  else
    AVAILABLE_MODELS=$(curl -s http://localhost:11434/api/tags | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('models', []):
    print(m['name'])
" 2>/dev/null || echo "")

    if [[ -z "$AVAILABLE_MODELS" ]]; then
      log "No models found. Pull models first: ollama pull qwen2.5-coder:14b"
    else
      log "Available models: $AVAILABLE_MODELS"
      log ""

      PROMPTS=(
        "Write a Python function that validates an IPv4 CIDR notation string"
        "Explain what a CloudFormation Transform does in 3 sentences"
        "Write a bash script that finds all files larger than 100MB and lists them sorted by size"
      )

      for MODEL in $AVAILABLE_MODELS; do
        separator "Benchmarking: $MODEL"

        # Warmup — load model into memory
        log "Warming up (loading model into RAM)..."
        curl -s http://localhost:11434/api/generate \
          -d "{\"model\":\"$MODEL\",\"prompt\":\"hello\",\"stream\":false}" >/dev/null 2>&1

        for i in "${!PROMPTS[@]}"; do
          PROMPT="${PROMPTS[$i]}"
          log ""
          log "--- Prompt $((i+1)): ${PROMPT:0:60}..."

          RESPONSE=$(curl -s http://localhost:11434/api/generate \
            -d "{\"model\":\"$MODEL\",\"prompt\":\"$PROMPT\",\"stream\":false}" 2>/dev/null)

          if [[ -n "$RESPONSE" ]]; then
            EVAL_COUNT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('eval_count',0))" 2>/dev/null || echo 0)
            EVAL_DURATION=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('eval_duration',0))" 2>/dev/null || echo 0)
            PROMPT_EVAL_COUNT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('prompt_eval_count',0))" 2>/dev/null || echo 0)
            PROMPT_EVAL_DURATION=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('prompt_eval_duration',0))" 2>/dev/null || echo 0)
            TOTAL_DURATION=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_duration',0))" 2>/dev/null || echo 0)

            if [[ "$EVAL_DURATION" -gt 0 ]]; then
              TOK_PER_SEC=$(python3 -c "print(f'{$EVAL_COUNT / ($EVAL_DURATION / 1e9):.2f}')" 2>/dev/null || echo "N/A")
            else
              TOK_PER_SEC="N/A"
            fi

            if [[ "$PROMPT_EVAL_DURATION" -gt 0 ]]; then
              PROMPT_TOK_PER_SEC=$(python3 -c "print(f'{$PROMPT_EVAL_COUNT / ($PROMPT_EVAL_DURATION / 1e9):.2f}')" 2>/dev/null || echo "N/A")
            else
              PROMPT_TOK_PER_SEC="N/A"
            fi

            TOTAL_SEC=$(python3 -c "print(f'{$TOTAL_DURATION / 1e9:.2f}')" 2>/dev/null || echo "N/A")

            log "  Tokens generated:  $EVAL_COUNT"
            log "  Generation speed:  $TOK_PER_SEC tok/s"
            log "  Prompt eval speed: $PROMPT_TOK_PER_SEC tok/s"
            log "  Total time:        ${TOTAL_SEC}s"
          else
            log "  ERROR: No response from Ollama"
          fi
        done

        # Unload model to free RAM for next
        curl -s http://localhost:11434/api/generate \
          -d "{\"model\":\"$MODEL\",\"prompt\":\"\",\"keep_alive\":0,\"stream\":false}" >/dev/null 2>&1
        log ""
        log "Model unloaded."
      done
    fi
  fi
fi

# =============================================================================
# SUMMARY
# =============================================================================
separator "BENCHMARK COMPLETE"

log ""
log "Results saved to: $RESULTS_FILE"
log ""
log "To compare before/after:"
log "  diff ${RESULTS_DIR}/${HOSTNAME}-BEFORE.txt ${RESULTS_DIR}/${HOSTNAME}-AFTER.txt"
log ""
log "Or for a quick side-by-side on key metrics:"
log "  grep -E 'Triad:|tok/s|Configured Memory Speed|Model name|cores' ${RESULTS_DIR}/${HOSTNAME}-*.txt"
