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
  elif ! command -v jq &>/dev/null; then
    log "jq not found, skipping Ollama benchmarks (apt install jq)"
  elif ! curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
    log "Ollama not reachable at localhost:11434, skipping"
    log "Make sure Ollama is running: systemctl status ollama"
  else
    AVAILABLE_MODELS=$(curl -s http://localhost:11434/api/tags | jq -r '.models[].name' 2>/dev/null || echo "")

    if [[ -z "$AVAILABLE_MODELS" ]]; then
      log "No models found. Pull models first: ollama pull qwen2.5-coder:14b"
    else
      log "Models: $AVAILABLE_MODELS"
      log ""
      log "NOTE: For cleanest cold-load numbers, run on the Proxmox host first:"
      log "  echo 3 > /proc/sys/vm/drop_caches"
      log ""

      # Raw data collection file — parsed at end for summary
      RAW_CSV=$(mktemp /tmp/bench-raw-XXXXXX.csv)
      echo "model,category,run,eval_count,eval_dur_ns,prompt_eval_count,prompt_eval_dur_ns,load_dur_ns,total_dur_ns" > "$RAW_CSV"

      # ── Helper: run one inference and record results ──
      run_inference() {
        local model="$1" prompt="$2" num_predict="$3" category="$4" run_num="$5"

        RESPONSE=$(curl -s --max-time 600 http://localhost:11434/api/generate \
          -d "{\"model\":\"$model\",\"prompt\":\"$prompt\",\"stream\":false,\"options\":{\"num_predict\":$num_predict}}" 2>/dev/null)

        local done_flag=$(echo "$RESPONSE" | jq -r '.done // empty' 2>/dev/null)
        if [[ "$done_flag" != "true" ]]; then
          log "    Run $run_num: ERROR — no valid response"
          return 1
        fi

        local ec=$(echo "$RESPONSE" | jq -r '.eval_count // 0')
        local ed=$(echo "$RESPONSE" | jq -r '.eval_duration // 0')
        local pec=$(echo "$RESPONSE" | jq -r '.prompt_eval_count // 0')
        local ped=$(echo "$RESPONSE" | jq -r '.prompt_eval_duration // 0')
        local ld=$(echo "$RESPONSE" | jq -r '.load_duration // 0')
        local td=$(echo "$RESPONSE" | jq -r '.total_duration // 0')

        local gen_toks=$(echo "$ec $ed" | awk '{if ($2>0) printf "%.2f", $1/($2/1e9); else print "N/A"}')
        local prompt_toks=$(echo "$pec $ped" | awk '{if ($2>0) printf "%.2f", $1/($2/1e9); else print "N/A"}')
        local load_sec=$(echo "$ld" | awk '{printf "%.2f", $1/1e9}')
        local total_sec=$(echo "$td" | awk '{printf "%.2f", $1/1e9}')

        log "    Run $run_num: ${ec} tok in ${total_sec}s | gen=${gen_toks} tok/s | prompt=${prompt_toks} tok/s | load=${load_sec}s"

        echo "$model,$category,$run_num,$ec,$ed,$pec,$ped,$ld,$td" >> "$RAW_CSV"
      }

      # ── Helper: unload a model ──
      unload_model() {
        curl -s http://localhost:11434/api/generate \
          -d "{\"model\":\"$1\",\"prompt\":\"\",\"keep_alive\":0,\"stream\":false}" >/dev/null 2>&1
        sleep 3
      }

      # ── Prompt definitions ──

      # Short output (~50 tokens)
      SHORT_P1="Explain what DNS does in exactly two sentences."
      SHORT_P2="What is the purpose of a VLAN? Answer briefly."
      SHORT_P3="Define infrastructure as code in three sentences."

      # Medium output (~200 tokens)
      MED_P1="Write a Python function that validates an email address. Include a docstring and example usage."
      MED_P2="Write a bash function that checks if a port is open on a remote host. Include error handling and a timeout parameter."
      MED_P3="Explain TCP versus UDP. Cover reliability, ordering, connection state, and typical use cases for each."

      # Long output (~500 tokens)
      LONG_P1="Write a bash script that hardens SSH on a new Ubuntu server. Disable password auth, set up key-based login, configure fail2ban, and restrict to specific users. Comment every section thoroughly."
      LONG_P2="Write a Python class implementing an LRU cache with get, put, and delete methods. Include size limits, TTL expiration, thread safety, docstrings, and type hints throughout."
      LONG_P3="Write an Ansible playbook that deploys nginx as a reverse proxy with SSL via Lets Encrypt, rate limiting, gzip compression, security headers, and structured access logging. Include handler definitions."

      # Prompt processing inputs (varying input length, capped output)
      PINPUT_SHORT="Review this code briefly: x = 1"
      PINPUT_MED="Review this Python function for bugs and improvements:\ndef fetch_data(url, retries=3):\n    for i in range(retries):\n        try:\n            resp = requests.get(url, timeout=10)\n            resp.raise_for_status()\n            return resp.json()\n        except requests.RequestException as e:\n            if i == retries - 1:\n                raise\n            time.sleep(2 ** i)\n    return None"
      PINPUT_LONG="Review this Python class for bugs, performance issues, and improvements:\nclass ConnectionPool:\n    def __init__(self, max_size=10, timeout=30):\n        self.max_size = max_size\n        self.timeout = timeout\n        self.pool = []\n        self.in_use = set()\n        self.lock = threading.Lock()\n    def acquire(self):\n        with self.lock:\n            if self.pool:\n                conn = self.pool.pop()\n                self.in_use.add(id(conn))\n                return conn\n            if len(self.in_use) < self.max_size:\n                conn = self._create_connection()\n                self.in_use.add(id(conn))\n                return conn\n        start = time.time()\n        while time.time() - start < self.timeout:\n            with self.lock:\n                if self.pool:\n                    conn = self.pool.pop()\n                    self.in_use.add(id(conn))\n                    return conn\n            time.sleep(0.1)\n        raise TimeoutError('No connections available')\n    def release(self, conn):\n        with self.lock:\n            self.in_use.discard(id(conn))\n            if len(self.pool) < self.max_size:\n                self.pool.append(conn)\n            else:\n                conn.close()\n    def _create_connection(self):\n        return socket.create_connection(('localhost', 5432), timeout=self.timeout)"

      # ══════════════════════════════════════════════════
      # RUN BENCHMARKS
      # ══════════════════════════════════════════════════

      for MODEL in $AVAILABLE_MODELS; do
        separator "Model: $MODEL"

        # ── 1. Cold load test ──
        log ""
        log "--- Cold load test (model unloaded, first inference) ---"
        unload_model "$MODEL"
        run_inference "$MODEL" "hello" 10 "cold_load" 1

        # ── 2. Generation speed: short output (50 tok) ──
        log ""
        log "--- Short generation (num_predict=50) ---"
        run_inference "$MODEL" "$SHORT_P1" 50 "gen_short" 1
        run_inference "$MODEL" "$SHORT_P2" 50 "gen_short" 2
        run_inference "$MODEL" "$SHORT_P3" 50 "gen_short" 3

        # ── 3. Generation speed: medium output (200 tok) ──
        log ""
        log "--- Medium generation (num_predict=200) ---"
        run_inference "$MODEL" "$MED_P1" 200 "gen_medium" 1
        run_inference "$MODEL" "$MED_P2" 200 "gen_medium" 2
        run_inference "$MODEL" "$MED_P3" 200 "gen_medium" 3

        # ── 4. Generation speed: long output (500 tok) ──
        log ""
        log "--- Long generation (num_predict=500) ---"
        run_inference "$MODEL" "$LONG_P1" 500 "gen_long" 1
        run_inference "$MODEL" "$LONG_P2" 500 "gen_long" 2
        run_inference "$MODEL" "$LONG_P3" 500 "gen_long" 3

        # ── 5. Prompt processing speed by input length ──
        log ""
        log "--- Prompt processing (varying input length, num_predict=50) ---"
        run_inference "$MODEL" "$PINPUT_SHORT" 50 "prompt_short" 1
        run_inference "$MODEL" "$PINPUT_MED" 50 "prompt_medium" 1
        run_inference "$MODEL" "$PINPUT_LONG" 50 "prompt_long" 1

        # ── Unload before next model ──
        unload_model "$MODEL"
        log ""
        log "Model unloaded."
      done

      # ══════════════════════════════════════════════════
      # SUMMARY REPORT
      # ══════════════════════════════════════════════════
      separator "LLM BENCHMARK SUMMARY"

      log ""
      log "--- Cold load times ---"
      log "$(printf '%-28s %12s' 'Model' 'Load (s)')"
      awk -F',' 'NR>1 && $2=="cold_load" {
        printf "%-28s %12.2f\n", $1, $8/1e9
      }' "$RAW_CSV" | tee -a "$RESULTS_FILE"

      log ""
      log "--- Generation speed (tok/s) by output length ---"
      log "$(printf '%-28s %10s %10s %10s %10s' 'Model' 'Short(50)' 'Med(200)' 'Long(500)' 'Overall')"
      for MODEL in $AVAILABLE_MODELS; do
        SHORT_AVG=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2=="gen_short" && $5>0 {sum+=$4/($5/1e9); n++} END{if(n>0) printf "%.2f", sum/n; else print "N/A"}' "$RAW_CSV")
        MED_AVG=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2=="gen_medium" && $5>0 {sum+=$4/($5/1e9); n++} END{if(n>0) printf "%.2f", sum/n; else print "N/A"}' "$RAW_CSV")
        LONG_AVG=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2=="gen_long" && $5>0 {sum+=$4/($5/1e9); n++} END{if(n>0) printf "%.2f", sum/n; else print "N/A"}' "$RAW_CSV")
        ALL_AVG=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2~/^gen_/ && $5>0 {sum+=$4/($5/1e9); n++} END{if(n>0) printf "%.2f", sum/n; else print "N/A"}' "$RAW_CSV")
        log "$(printf '%-28s %10s %10s %10s %10s' "$MODEL" "$SHORT_AVG" "$MED_AVG" "$LONG_AVG" "$ALL_AVG")"
      done

      log ""
      log "--- Generation speed variance ---"
      log "$(printf '%-28s %14s %14s %14s' 'Model' 'Short σ' 'Med σ' 'Long σ')"
      for MODEL in $AVAILABLE_MODELS; do
        SHORT_SD=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2=="gen_short" && $5>0 {v=$4/($5/1e9); sum+=v; sumsq+=v*v; n++} END{if(n>1){mean=sum/n; printf "± %.2f", sqrt((sumsq-n*mean*mean)/(n-1))} else print "N/A"}' "$RAW_CSV")
        MED_SD=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2=="gen_medium" && $5>0 {v=$4/($5/1e9); sum+=v; sumsq+=v*v; n++} END{if(n>1){mean=sum/n; printf "± %.2f", sqrt((sumsq-n*mean*mean)/(n-1))} else print "N/A"}' "$RAW_CSV")
        LONG_SD=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2=="gen_long" && $5>0 {v=$4/($5/1e9); sum+=v; sumsq+=v*v; n++} END{if(n>1){mean=sum/n; printf "± %.2f", sqrt((sumsq-n*mean*mean)/(n-1))} else print "N/A"}' "$RAW_CSV")
        log "$(printf '%-28s %14s %14s %14s' "$MODEL" "$SHORT_SD" "$MED_SD" "$LONG_SD")"
      done

      log ""
      log "--- Prompt processing speed (tok/s) by input length ---"
      log "$(printf '%-28s %14s %14s %14s' 'Model' 'Short input' 'Med input' 'Long input')"
      for MODEL in $AVAILABLE_MODELS; do
        PS=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2=="prompt_short" && $7>0 {printf "%.2f", $6/($7/1e9)}' "$RAW_CSV")
        PM=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2=="prompt_medium" && $7>0 {printf "%.2f", $6/($7/1e9)}' "$RAW_CSV")
        PL=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2=="prompt_long" && $7>0 {printf "%.2f", $6/($7/1e9)}' "$RAW_CSV")
        log "$(printf '%-28s %14s %14s %14s' "$MODEL" "${PS:-N/A}" "${PM:-N/A}" "${PL:-N/A}")"
      done

      log ""
      log "--- Overall summary ---"
      log "$(printf '%-28s %10s %18s %14s' 'Model' 'Load(s)' 'Gen tok/s (mean±σ)' 'Prompt tok/s')"
      for MODEL in $AVAILABLE_MODELS; do
        LOAD=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2=="cold_load" {printf "%.1f", $8/1e9}' "$RAW_CSV")
        GEN_MEAN=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2~/^gen_/ && $5>0 {sum+=$4/($5/1e9); n++} END{if(n>0) printf "%.1f", sum/n; else print "N/A"}' "$RAW_CSV")
        GEN_SD=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2~/^gen_/ && $5>0 {v=$4/($5/1e9); sum+=v; sumsq+=v*v; n++} END{if(n>1){mean=sum/n; printf "%.1f", sqrt((sumsq-n*mean*mean)/(n-1))} else print "0.0"}' "$RAW_CSV")
        PROMPT_AVG=$(awk -F',' -v m="$MODEL" 'NR>1 && $1==m && $2~/^prompt_/ && $7>0 {sum+=$6/($7/1e9); n++} END{if(n>0) printf "%.1f", sum/n; else print "N/A"}' "$RAW_CSV")
        log "$(printf '%-28s %10s %18s %14s' "$MODEL" "${LOAD:-N/A}" "${GEN_MEAN}±${GEN_SD}" "${PROMPT_AVG}")"
      done

      log ""
      log "Raw benchmark data: $RAW_CSV"
      cp "$RAW_CSV" "${RESULTS_DIR}/${HOSTNAME}-${TIMESTAMP}-raw.csv"
      log "Copied to: ${RESULTS_DIR}/${HOSTNAME}-${TIMESTAMP}-raw.csv"
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
log "Quick comparison on key metrics:"
log "  grep -E 'Triad:|Overall summary|Load\(s\)|tok/s' ${RESULTS_DIR}/${HOSTNAME}-*.txt"
