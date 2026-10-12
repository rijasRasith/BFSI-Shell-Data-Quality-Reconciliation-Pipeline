#!/usr/bin/env bash

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$PIPELINE_DIR/logs"

log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO ] $*" | tee -a "$LOG_DIR/simulate_$(date +%Y%m%d).log"; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN ] $*" | tee -a "$LOG_DIR/simulate_$(date +%Y%m%d).log"; }

mkdir -p "$LOG_DIR"

simulate_days=5

log_info "Starting $simulate_days-day simulation..."

for day_offset in $(seq 0 $((simulate_days - 1))); do
    sim_date=$(date -d "2025-10-01 +${day_offset} days" "+%Y%m%d" 2>/dev/null || \
               python3 -c "from datetime import date, timedelta; d=date(2025,10,1)+timedelta($day_offset); print(d.strftime('%Y%m%d'))")

    log_info "--- Simulated day: $sim_date ---"

    python3 -c "
import csv, random, string, os
from datetime import date, timedelta

random.seed($day_offset + 100)
base = date(2025, 10, 1) + timedelta($day_offset)
accounts = [f'AC{str(i).zfill(6)}' for i in range(1,201)]
branches = ['MUM001','DEL002','BLR003','CHN004','HYD005']
types    = ['CREDIT','DEBIT','TRANSFER','REVERSAL']

incoming = '${PIPELINE_DIR}/incoming'
os.makedirs(incoming, exist_ok=True)
filename = f'TXN_{base.strftime(\"%Y%m%d\")}.csv'
filepath = os.path.join(incoming, filename)

if os.path.exists(filepath):
    print(f'File already exists: {filename}')
    exit(0)

refs = set()
rows = []
total = 0.0
num = random.randint(60, 120)
with open(filepath, 'w', newline='') as f:
    w = csv.writer(f)
    w.writerow(['account_id','txn_date','amount','txn_type','branch','ref_number'])
    for _ in range(num):
        ref = 'REF' + ''.join(random.choices(string.digits, k=10))
        while ref in refs: ref = 'REF' + ''.join(random.choices(string.digits, k=10))
        refs.add(ref)
        amount = round(random.uniform(100, 100000), 2)
        w.writerow([random.choice(accounts), base.strftime('%Y-%m-%d'), f'{amount:.2f}', random.choice(types), random.choice(branches), ref])
        total += amount
ctrl = filepath.replace('.csv', '.ctrl')
with open(ctrl, 'w') as f:
    f.write(f'ROW_COUNT={num}\n')
    f.write(f'TOTAL_AMOUNT={total:.2f}\n')
print(f'Generated: {filename} ({num} rows)')
" 2>&1 | tee -a "$LOG_DIR/simulate_$(date +%Y%m%d).log"

    log_info "Running pipeline for day $sim_date..."
    bash "$PIPELINE_DIR/scripts/pipeline.sh" 2>&1 | tail -5

    sleep 1
done

log_info "Simulation complete. Check logs/ and reports/ directories."
