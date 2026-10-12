# Runbook: Shell-Based Banking Transaction Pipeline

## On-Call Contact Checklist

Before escalating, confirm:
1. Pipeline log exists at `logs/pipeline_YYYYMMDD.log`
2. Alert file exists at `logs/alerts_YYYYMMDD.txt`
3. No stale lock: `/tmp/txn_pipeline.lock`

---

## Failure: File Quarantined

**Symptom:** File appears in `quarantine/`, reason logged in `quarantine/quarantine.log`.

| Reason Code | Cause | Action |
|---|---|---|
| `INVALID_FILENAME_PATTERN` | File name does not match `TXN_YYYYMMDD.csv` | Contact upstream to resend with correct naming |
| `MISSING_OR_INVALID_HEADER` | Header row absent or wrong column names | Manually inspect file; if data is correct, add header and move back to `incoming/` |
| `INCONSISTENT_COLUMN_COUNT` | One or more rows have != 6 fields | Return to source for correction |
| `CONTROL_TOTAL_MISMATCH` | Row count or amount total differs from `.ctrl` file | Verify `.ctrl` file; if file is complete, regenerate `.ctrl` and retry |

**To retry a quarantined file:**
```bash
cp quarantine/TXN_YYYYMMDD.csv incoming/
cp quarantine/TXN_YYYYMMDD.ctrl incoming/   # if applicable
bash scripts/pipeline.sh
```

---

## Failure: Records Rejected

**Symptom:** `rejected/TXN_YYYYMMDD_rejected.csv` contains records; exception report shows non-zero counts.

**Action:**
- Review rejection reasons in the exception report at `reports/exception_YYYYMMDD.rpt`.
- For `UNKNOWN_ACCOUNT_ID`: verify with account master team; add account if valid and reprocess rejected file after correction.
- For `NULL_FIELD` or `DUPLICATE_REF`: return the raw file to source team for correction.
- Rejected files are retained for audit; do not delete without sign-off.

---

## Failure: MySQL Load Failed

**Symptom:** Log line: `[ERROR] Staging load failed for TXN_YYYYMMDD.csv`

1. Check DB connectivity: `mysql -u pipeline_user -p banking_pipeline -e "SELECT 1;"`
2. Check MySQL error log: `/var/log/mysql/error.log`
3. If `local_infile` is disabled: `SET GLOBAL local_infile = 1;` in MySQL root session.
4. If schema is out of sync: re-run `mysql -u root -p < sql/schema.sql`.
5. Once DB is healthy, re-run the pipeline. Duplicate-key guard prevents double-loading.

---

## Failure: Reconciliation Mismatch

**Symptom:** Log line: `[ERROR] Reconciliation FAILED for TXN_YYYYMMDD.csv`

**Immediate steps:**
1. Compare counts: `grep "TXN_YYYYMMDD" logs/reconciliation_YYYYMMDD.log`
2. Query target: `SELECT COUNT(*), SUM(amount) FROM txn_final WHERE source_file='TXN_YYYYMMDD.csv';`
3. Count clean source: `tail -n +2 processing/TXN_YYYYMMDD_clean.csv | wc -l` (if still present)
4. Check for partial load (DB was mid-insert): delete staging rows and reload.
5. Escalate to data engineering lead if mismatch persists after reload.

**Escalation contacts:** (fill in per your organisation's RACI)

---

## Failure: Stale Lock File

**Symptom:** `Pipeline already running with PID XXXXX. Exiting.`

1. Verify no pipeline process is actually running: `ps aux | grep pipeline.sh`
2. If the process is truly dead: `rm -f /tmp/txn_pipeline.lock`
3. Re-run: `bash scripts/pipeline.sh`

---

## Failure: Double-Processing Prevented

**Symptom:** Log: `Already processed, skipping: TXN_YYYYMMDD.csv`

This is expected behaviour. If you genuinely need to reprocess:
1. Remove the archived copy: `rm archive/TXN_YYYYMMDD_*.csv`
2. Clear target rows: `DELETE FROM txn_final WHERE source_file='TXN_YYYYMMDD.csv';`
3. Move file back: `cp incoming_backup/TXN_YYYYMMDD.csv incoming/`
4. Re-run the pipeline.

---

## Routine Maintenance

| Task | Frequency | Command |
|---|---|---|
| Log rotation (auto) | Daily | Handled by `pipeline.sh` |
| Archive purge (auto, 90d) | Daily | Handled by `pipeline.sh` |
| DB backup | Weekly | `mysqldump banking_pipeline > backup_YYYYMMDD.sql` |
| Test suite | After any code change | `bash scripts/run_tests.sh` |
| PySpark job | On demand / weekly | `python3 scripts/pyspark_summary.py` |

---

## Escalation Matrix

| Severity | Scenario | Escalate To | SLA |
|---|---|---|---|
| P1 | Recon mismatch > 1% of value | Data Engineering Lead + Compliance | 1 hour |
| P2 | File quarantined for 2nd day running | Operations + Upstream Team | 4 hours |
| P3 | DB load failed, retries exhausted | DBA on-call | 8 hours |
| P4 | Rejected rate > 5% | Data Quality team | Next business day |
