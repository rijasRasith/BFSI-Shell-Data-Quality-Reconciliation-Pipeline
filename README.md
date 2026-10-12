# BFSI-Shell-Data-Quality-Reconciliation-Pipeline

A scheduled batch pipeline that receives daily banking transaction files, performs data-quality checks, loads clean records into MySQL, reconciles source against target, and produces exception and reconciliation reports.

---

## Architecture

```
incoming/
   TXN_YYYYMMDD.csv   ← raw daily transaction drop
   TXN_YYYYMMDD.ctrl  ← companion control-total file
        │
        ▼
   [File-Level Checks]
   • filename pattern
   • header validation
   • column count
   • control totals (row count + amount)
        │
   FAIL ├──────────────► quarantine/
        │                quarantine.log
   PASS │
        ▼
   [Record-Level QC]
   • null fields
   • duplicate ref_number
   • non-numeric amount
   • negative amount
   • invalid date
   • unknown account_id
        │
        ├── clean records ──► processing/TXN_*_clean.csv
        └── bad records  ──► rejected/TXN_*_rejected.csv  (+ reason code)
                                │
                                ▼
                    [Exception Report]
                    reports/exception_YYYYMMDD.rpt
                                │
                                ▼
                    [MySQL Load]
                    txn_staging → txn_final
                                │
                                ▼
                    [Reconciliation]
                    src count/total vs tgt count/total
                    logs/reconciliation_YYYYMMDD.log
                                │
                                ▼
                    [Archive & Rotate]
                    archive/   logs/ (30-day retention)
```

---

## Folder Layout

```
.
├── data/
│   ├── generate_data.py       # generates all sample data
│   ├── account_master.csv     # 200-account reference file
│   └── TXN_LARGE.csv          # 500 000-row file for PySpark
├── incoming/                  # daily file drop location
├── processing/                # working directory during a run
├── quarantine/                # files failing file-level checks
├── rejected/                  # records failing record-level QC
├── archive/                   # processed files (timestamped)
├── logs/                      # pipeline, reconciliation, cron logs
├── reports/                   # exception reports, PySpark summaries
├── scripts/
│   ├── pipeline.sh            # main orchestrator
│   ├── run_tests.sh           # automated test suite
│   ├── simulate_days.sh       # multi-day simulation
│   ├── setup_db.sh            # one-time DB + account master setup
│   ├── setup_cron.sh          # registers cron job
│   └── pyspark_summary.py     # PySpark large-file summary job
└── sql/
    ├── schema.sql             # full MySQL schema + user creation
    └── load_account_master.sql
```

---

## Control Checklist

| Check | Tool | On Failure |
|---|---|---|
| Filename pattern `TXN_YYYYMMDD.csv` | `grep -E` | Quarantine |
| Header row present and correct | `head` / string compare | Quarantine |
| Column count = 6 on every row | `awk` | Quarantine |
| Row count matches `.ctrl` file | `wc -l` / `awk` | Quarantine |
| Amount total matches `.ctrl` file | `awk` sum | Quarantine |
| No null fields | `awk` | Reject record |
| No duplicate `ref_number` | `awk` seen-array | Reject record |
| Amount is non-negative numeric | `awk` regex + arithmetic | Reject record |
| Date format `YYYY-MM-DD` and valid | `awk` | Reject record |
| `account_id` exists in master | `awk` lookup | Reject record |
| Source count = target count | shell + MySQL | Alert + log |
| Source total = target total | shell + MySQL | Alert + log |

---

## How to Run

### Prerequisites

- Linux / WSL (Ubuntu 20.04+)
- Bash 4+, GNU awk, GNU date
- MySQL 8.x (`mysql` client on PATH)
- Python 3.8+
- PySpark 3.x (`pyspark` installed via `pip install pyspark`)

### 1. Generate Sample Data

```bash
cd /path/to/project
python3 data/generate_data.py
```

### 2. Initialise the Database

```bash
bash scripts/setup_db.sh
# Prompts for MySQL root password, then pipeline_user password
```

### 3. Run the Pipeline Manually

```bash
bash scripts/pipeline.sh
```

### 4. Schedule with Cron

```bash
bash scripts/setup_cron.sh
# Registers daily run at 02:00 AM
```

### 5. Simulate Multiple Days

```bash
bash scripts/simulate_days.sh
```

### 6. Run Automated Tests

```bash
bash scripts/run_tests.sh
```

### 7. Run PySpark Summary Job

```bash
python3 scripts/pyspark_summary.py
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DB_HOST` | `localhost` | MySQL host |
| `DB_PORT` | `3306` | MySQL port |
| `DB_NAME` | `banking_pipeline` | Database name |
| `DB_USER` | `pipeline_user` | MySQL user |
| `DB_PASS` | `pipeline_pass` | MySQL password |

Override before running: `export DB_PASS=mypassword && bash scripts/pipeline.sh`

---

## Test Scenarios

| # | Scenario | Expected Result |
|---|---|---|
| 1 | Clean file, correct control total | All records clean, loaded, recon PASS |
| 2 | Wrong filename pattern | Quarantined: INVALID_FILENAME_PATTERN |
| 3 | Missing / wrong header | Quarantined: MISSING_OR_INVALID_HEADER |
| 4 | Row count mismatch in ctrl | Quarantined: CONTROL_TOTAL_MISMATCH |
| 5 | Amount total mismatch in ctrl | Quarantined: CONTROL_TOTAL_MISMATCH |
| 6 | Null fields in records | Records rejected: NULL_FIELD |
| 7 | Duplicate `ref_number` | Records rejected: DUPLICATE_REF |
| 8 | Negative amount | Records rejected: NEGATIVE_AMOUNT |
| 9 | Non-numeric amount | Records rejected: NON_NUMERIC_AMOUNT |
| 10 | Invalid date (month > 12) | Records rejected: INVALID_DATE_VALUE |
| 11 | Unknown `account_id` | Records rejected: UNKNOWN_ACCOUNT_ID |
| 12 | Empty file (header only) | No records loaded, no recon run |
| 13 | Already-processed file dropped again | Skipped (double-processing guard) |
| 14 | DB unreachable (simulated) | Retries 3×, alert written, exits 1 |
| 15 | Reconciliation count mismatch | Recon FAIL logged, alert raised |

---

## Sample Exception Report

```
==================================================================
  DAILY TRANSACTION EXCEPTION REPORT
  File     : TXN_20251005.csv
  Run Date : 2025-10-05 02:00:31
==================================================================

  Total Records    : 39
  Clean Records    : 30
  Rejected Records : 9
  Rejection Rate   : 23.08%

  REJECTION BREAKDOWN
  ------------------
  NULL_FIELD                : 3
  DUPLICATE_REF             : 1
  NEGATIVE_AMOUNT           : 1
  NON_NUMERIC_AMOUNT        : 1
  INVALID_DATE              : 1
  UNKNOWN_ACCOUNT_ID        : 1
  (second dup counted once)

==================================================================
```

---

## Sample Reconciliation Log

```
2025-10-01 02:00:45 | TXN_20251001.csv | src_count=112 tgt_count=112 | src_total=8254310.47 tgt_total=8254310.47 | PASS
2025-10-05 02:00:52 | TXN_20251005.csv | src_count=30 tgt_count=30 | src_total=6103291.00 tgt_total=6103291.00 | PASS
```

---

## Numbers (for Resume)

| Metric | Value |
|---|---|
| Files processed (clean) | 1 |
| Files quarantined | 3 |
| Total records (clean file) | ~100 |
| Records rejected | 9 |
| Rejection rate | ~23% |
| Rejection reasons tracked | 6 |
| Reconciliation mismatches caught | 2 |
| Large file rows (PySpark) | 500 000 |
| Test scenarios | 15 |

---

## Limitations

- Pipeline runs as a single process; true parallelism requires process substitution or a job queue.
- `LOAD DATA LOCAL INFILE` requires `local_infile=ON` in MySQL config.
- Date validation in awk is calendar-approximate (does not check day-of-month against month length).
- PySpark job is designed for local mode; for cluster submission, adjust `SparkSession` master.
- Cron setup assumes system crontab access; adjust for `systemd` timers if required.
