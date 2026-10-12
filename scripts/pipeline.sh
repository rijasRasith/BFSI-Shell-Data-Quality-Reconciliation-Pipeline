#!/usr/bin/env bash

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$PIPELINE_DIR/logs"
INCOMING_DIR="$PIPELINE_DIR/incoming"
PROCESSING_DIR="$PIPELINE_DIR/processing"
QUARANTINE_DIR="$PIPELINE_DIR/quarantine"
REJECTED_DIR="$PIPELINE_DIR/rejected"
ARCHIVE_DIR="$PIPELINE_DIR/archive"
REPORTS_DIR="$PIPELINE_DIR/reports"
DATA_DIR="$PIPELINE_DIR/data"
SCRIPTS_DIR="$PIPELINE_DIR/scripts"

LOCK_FILE="/tmp/txn_pipeline.lock"
LOG_FILE="$LOG_DIR/pipeline_$(date +%Y%m%d).log"
RECON_LOG="$LOG_DIR/reconciliation_$(date +%Y%m%d).log"
EXCEPTION_REPORT="$REPORTS_DIR/exception_$(date +%Y%m%d).rpt"
NOTIFICATION_FILE="$LOG_DIR/alerts_$(date +%Y%m%d).txt"

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-banking_pipeline}"
DB_USER="${DB_USER:-pipeline_user}"
DB_PASS="${DB_PASS:-pipeline_pass}"

EXPECTED_HEADER="account_id,txn_date,amount,txn_type,branch,ref_number"
EXPECTED_COLUMNS=6
FILENAME_PATTERN="^TXN_[0-9]{8}\.csv$"
MAX_DB_RETRIES=3
DB_RETRY_DELAY=5

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info()  { log "INFO " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_error() { log "ERROR" "$@"; }

alert() {
    local message="$*"
    log_error "ALERT: $message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALERT: $message" >> "$NOTIFICATION_FILE"
}

acquire_lock() {
    if [ -e "$LOCK_FILE" ]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            log_error "Pipeline already running with PID $pid. Exiting."
            exit 1
        else
            log_warn "Stale lock file found. Removing."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

check_already_processed() {
    local filename="$1"
    local archive_file="$ARCHIVE_DIR/$filename"
    if [ -f "$archive_file" ] || compgen -G "$ARCHIVE_DIR/${filename%.csv}_*.csv" > /dev/null 2>&1; then
        return 0
    fi
    if grep -q "$filename" "$LOG_DIR"/*.log 2>/dev/null | grep -q "LOAD_COMPLETE"; then
        return 0
    fi
    return 1
}

mysql_exec() {
    local sql="$1"
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "$sql" 2>/dev/null
}

mysql_exec_with_retry() {
    local sql="$1"
    local attempt=1
    while [ "$attempt" -le "$MAX_DB_RETRIES" ]; do
        if mysql_exec "$sql"; then
            return 0
        fi
        log_warn "DB attempt $attempt/$MAX_DB_RETRIES failed. Retrying in ${DB_RETRY_DELAY}s..."
        sleep "$DB_RETRY_DELAY"
        attempt=$((attempt + 1))
    done
    log_error "DB operation failed after $MAX_DB_RETRIES attempts."
    return 1
}

check_filename_pattern() {
    local filename="$1"
    if ! echo "$filename" | grep -qE "$FILENAME_PATTERN"; then
        return 1
    fi
    local file_date_str
    file_date_str=$(echo "$filename" | grep -oE "[0-9]{8}")
    if ! date -d "$file_date_str" "+%Y%m%d" > /dev/null 2>&1; then
        return 1
    fi
    return 0
}

check_header() {
    local filepath="$1"
    local actual_header
    actual_header=$(head -1 "$filepath" | tr -d '\r')
    if [ "$actual_header" != "$EXPECTED_HEADER" ]; then
        return 1
    fi
    return 0
}

check_column_count() {
    local filepath="$1"
    local bad_rows
    bad_rows=$(awk -F',' 'NR>1 { if (NF != '"$EXPECTED_COLUMNS"') print NR }' "$filepath" | wc -l)
    if [ "$bad_rows" -gt 0 ]; then
        return 1
    fi
    return 0
}

check_control_totals() {
    local filepath="$1"
    local ctrl_file="${filepath%.csv}.ctrl"
    if [ ! -f "$ctrl_file" ]; then
        log_warn "Control file missing for $filepath"
        return 1
    fi
    local expected_count expected_total
    expected_count=$(grep "^ROW_COUNT=" "$ctrl_file" | cut -d'=' -f2 | tr -d '\r')
    expected_total=$(grep "^TOTAL_AMOUNT=" "$ctrl_file" | cut -d'=' -f2 | tr -d '\r')
    local actual_count
    actual_count=$(tail -n +2 "$filepath" | wc -l)
    local actual_total
    actual_total=$(awk -F',' 'NR>1 { sum += $3 } END { printf "%.2f", sum }' "$filepath")
    if [ "$actual_count" -ne "$expected_count" ]; then
        log_warn "Row count mismatch: expected=$expected_count actual=$actual_count"
        return 1
    fi
    local total_match
    total_match=$(awk -v a="$actual_total" -v b="$expected_total" 'BEGIN { diff = a - b; if (diff < 0) diff = -diff; print (diff < 0.01) ? "OK" : "FAIL" }')
    if [ "$total_match" != "OK" ]; then
        log_warn "Total amount mismatch: expected=$expected_total actual=$actual_total"
        return 1
    fi
    return 0
}

quarantine_file() {
    local filepath="$1"
    local reason="$2"
    local filename
    filename=$(basename "$filepath")
    local ctrl_file="${filepath%.csv}.ctrl"
    mv "$filepath" "$QUARANTINE_DIR/"
    [ -f "$ctrl_file" ] && mv "$ctrl_file" "$QUARANTINE_DIR/"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $filename | $reason" >> "$QUARANTINE_DIR/quarantine.log"
    log_warn "Quarantined: $filename | Reason: $reason"
    alert "File quarantined: $filename | Reason: $reason"
}

file_level_checks() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    log_info "Running file-level checks on: $filename"

    if ! check_filename_pattern "$filename"; then
        quarantine_file "$filepath" "INVALID_FILENAME_PATTERN"
        return 1
    fi

    if ! check_header "$filepath"; then
        quarantine_file "$filepath" "MISSING_OR_INVALID_HEADER"
        return 1
    fi

    if ! check_column_count "$filepath"; then
        quarantine_file "$filepath" "INCONSISTENT_COLUMN_COUNT"
        return 1
    fi

    if ! check_control_totals "$filepath"; then
        quarantine_file "$filepath" "CONTROL_TOTAL_MISMATCH"
        return 1
    fi

    log_info "File-level checks passed: $filename"
    return 0
}

record_level_checks() {
    local src_file="$1"
    local clean_file="$2"
    local rejected_file="$3"
    local account_master="$DATA_DIR/account_master.csv"
    local filename
    filename=$(basename "$src_file")
    log_info "Running record-level checks on: $filename"

    awk -F',' -v acct_master="$account_master" -v clean="$clean_file" -v rejected="$rejected_file" '
    BEGIN {
        while ((getline line < acct_master) > 0) {
            split(line, parts, ",")
            valid_accounts[parts[1]] = 1
        }
        close(acct_master)
        null_count = 0
        dup_count = 0
        neg_count = 0
        non_numeric_count = 0
        invalid_date_count = 0
        unknown_acc_count = 0
    }
    NR == 1 {
        print > clean
        print > rejected
        next
    }
    {
        account_id = $1
        txn_date   = $2
        amount     = $3
        txn_type   = $4
        branch     = $5
        ref_number = $6

        reason = ""

        if (account_id == "" || txn_date == "" || amount == "" || txn_type == "" || branch == "" || ref_number == "") {
            reason = "NULL_FIELD"
            null_count++
        } else if (seen_refs[ref_number]++) {
            reason = "DUPLICATE_REF"
            dup_count++
        } else if (amount !~ /^-?[0-9]+(\.[0-9]+)?$/) {
            reason = "NON_NUMERIC_AMOUNT"
            non_numeric_count++
        } else if (amount + 0 < 0) {
            reason = "NEGATIVE_AMOUNT"
            neg_count++
        } else if (txn_date !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) {
            reason = "INVALID_DATE_FORMAT"
            invalid_date_count++
        } else {
            split(txn_date, d, "-")
            m = d[2] + 0; dy = d[3] + 0
            if (m < 1 || m > 12 || dy < 1 || dy > 31) {
                reason = "INVALID_DATE_VALUE"
                invalid_date_count++
            }
        }

        if (reason == "" && !(account_id in valid_accounts)) {
            reason = "UNKNOWN_ACCOUNT_ID"
            unknown_acc_count++
        }

        if (reason == "") {
            print $0 > clean
        } else {
            print $0 "," reason > rejected
        }
    }
    END {
        print "NULL_FIELD=" null_count > "/tmp/qc_counts.tmp"
        print "DUPLICATE_REF=" dup_count >> "/tmp/qc_counts.tmp"
        print "NON_NUMERIC_AMOUNT=" non_numeric_count >> "/tmp/qc_counts.tmp"
        print "NEGATIVE_AMOUNT=" neg_count >> "/tmp/qc_counts.tmp"
        print "INVALID_DATE=" invalid_date_count >> "/tmp/qc_counts.tmp"
        print "UNKNOWN_ACCOUNT_ID=" unknown_acc_count >> "/tmp/qc_counts.tmp"
    }
    ' "$src_file"

    local clean_count rejected_count
    clean_count=$(tail -n +2 "$clean_file" | wc -l)
    rejected_count=$(tail -n +2 "$rejected_file" | wc -l)
    log_info "Record-level check complete: clean=$clean_count rejected=$rejected_count"
}

generate_exception_report() {
    local filename="$1"
    local clean_file="$2"
    local rejected_file="$3"
    local run_date
    run_date=$(date '+%Y-%m-%d %H:%M:%S')
    local clean_count rejected_count total_count
    clean_count=$(tail -n +2 "$clean_file" | wc -l)
    rejected_count=$(tail -n +2 "$rejected_file" | wc -l)
    total_count=$((clean_count + rejected_count))

    {
        echo "=================================================================="
        echo "  DAILY TRANSACTION EXCEPTION REPORT"
        echo "  File     : $filename"
        echo "  Run Date : $run_date"
        echo "=================================================================="
        echo ""
        echo "  Total Records    : $total_count"
        echo "  Clean Records    : $clean_count"
        echo "  Rejected Records : $rejected_count"
        if [ "$total_count" -gt 0 ]; then
            local rejection_rate
            rejection_rate=$(awk -v r="$rejected_count" -v t="$total_count" 'BEGIN { printf "%.2f%%", (r/t)*100 }')
            echo "  Rejection Rate   : $rejection_rate"
        fi
        echo ""
        echo "  REJECTION BREAKDOWN"
        echo "  ------------------"
        if [ -f /tmp/qc_counts.tmp ]; then
            while IFS='=' read -r reason count; do
                printf "  %-25s : %d\n" "$reason" "$count"
            done < /tmp/qc_counts.tmp
            rm -f /tmp/qc_counts.tmp
        fi
        echo ""
        echo "=================================================================="
    } >> "$EXCEPTION_REPORT"

    log_info "Exception report updated: $EXCEPTION_REPORT"
}

load_to_mysql() {
    local clean_file="$1"
    local filename="$2"
    log_info "Loading clean data to MySQL staging: $filename"

    local load_sql
    load_sql="LOAD DATA LOCAL INFILE '${clean_file}' INTO TABLE txn_staging
    FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '\"'
    LINES TERMINATED BY '\n'
    IGNORE 1 ROWS
    (account_id, txn_date, amount, txn_type, branch, ref_number)
    SET source_file='${filename}', loaded_at=NOW();"

    if ! mysql_exec_with_retry "$load_sql"; then
        log_error "Staging load failed for $filename"
        alert "Staging load failed for $filename"
        return 1
    fi

    local promote_sql="INSERT INTO txn_final
    SELECT account_id, txn_date, amount, txn_type, branch, ref_number, source_file, loaded_at
    FROM txn_staging
    WHERE source_file = '${filename}'
    ON DUPLICATE KEY UPDATE loaded_at=NOW();"

    if ! mysql_exec_with_retry "$promote_sql"; then
        log_error "Promotion to final table failed for $filename"
        alert "Promotion to final table failed for $filename"
        return 1
    fi

    log_info "Data loaded successfully to txn_final for: $filename"
    return 0
}

reconcile() {
    local clean_file="$1"
    local filename="$2"
    log_info "Running reconciliation for: $filename"

    local src_count src_total
    src_count=$(tail -n +2 "$clean_file" | wc -l)
    src_total=$(awk -F',' 'NR>1 { sum += $3 } END { printf "%.2f", sum }' "$clean_file")

    local tgt_count tgt_total
    tgt_count=$(mysql_exec "SELECT COUNT(*) FROM txn_final WHERE source_file='${filename}';" 2>/dev/null | tail -1)
    tgt_total=$(mysql_exec "SELECT COALESCE(SUM(amount),0) FROM txn_final WHERE source_file='${filename}';" 2>/dev/null | tail -1)

    local recon_status="PASS"
    local mismatch_detail=""

    if [ "$src_count" != "$tgt_count" ]; then
        recon_status="FAIL"
        mismatch_detail="COUNT_MISMATCH: src=$src_count tgt=$tgt_count"
    fi

    local total_match
    total_match=$(awk -v a="$src_total" -v b="$tgt_total" 'BEGIN { diff = a - b; if (diff < 0) diff = -diff; print (diff < 0.01) ? "OK" : "FAIL" }')
    if [ "$total_match" != "OK" ]; then
        recon_status="FAIL"
        mismatch_detail="$mismatch_detail AMOUNT_MISMATCH: src=$src_total tgt=$tgt_total"
    fi

    local recon_entry
    recon_entry="$(date '+%Y-%m-%d %H:%M:%S') | $filename | src_count=$src_count tgt_count=$tgt_count | src_total=$src_total tgt_total=$tgt_total | $recon_status"
    [ -n "$mismatch_detail" ] && recon_entry="$recon_entry | $mismatch_detail"
    echo "$recon_entry" >> "$RECON_LOG"

    if [ "$recon_status" = "FAIL" ]; then
        log_error "Reconciliation FAILED for $filename: $mismatch_detail"
        alert "Reconciliation failure: $filename | $mismatch_detail"
        return 1
    fi

    log_info "Reconciliation PASSED for: $filename"
    return 0
}

archive_file() {
    local filepath="$1"
    local ctrl_file="${filepath%.csv}.ctrl"
    local filename
    filename=$(basename "$filepath")
    local archive_name="${filename%.csv}_$(date +%Y%m%d%H%M%S).csv"
    mv "$filepath" "$ARCHIVE_DIR/$archive_name"
    [ -f "$ctrl_file" ] && mv "$ctrl_file" "$ARCHIVE_DIR/${archive_name%.csv}.ctrl"
    log_info "Archived: $filename -> $archive_name"
}

rotate_logs() {
    find "$LOG_DIR" -name "*.log" -mtime +30 -delete
    find "$REPORTS_DIR" -name "*.rpt" -mtime +30 -delete
    find "$ARCHIVE_DIR" -name "*.csv" -mtime +90 -delete
    log_info "Log and archive rotation completed."
}

process_file() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")

    if check_already_processed "$filename"; then
        log_warn "Already processed, skipping: $filename"
        return 0
    fi

    log_info "=== Processing file: $filename ==="

    cp "$filepath" "$PROCESSING_DIR/"
    local proc_file="$PROCESSING_DIR/$filename"
    local base="${filename%.csv}"
    local clean_file="$PROCESSING_DIR/${base}_clean.csv"
    local rejected_file="$REJECTED_DIR/${base}_rejected.csv"

    if ! file_level_checks "$proc_file"; then
        rm -f "$proc_file"
        return 1
    fi

    record_level_checks "$proc_file" "$clean_file" "$rejected_file"
    generate_exception_report "$filename" "$clean_file" "$rejected_file"

    local clean_count
    clean_count=$(tail -n +2 "$clean_file" | wc -l)
    if [ "$clean_count" -eq 0 ]; then
        log_warn "No clean records to load for: $filename"
    else
        if load_to_mysql "$clean_file" "$filename"; then
            reconcile "$clean_file" "$filename"
        fi
    fi

    archive_file "$filepath"
    rm -f "$proc_file" "$clean_file"
    log_info "=== Completed: $filename ==="
}

main() {
    mkdir -p "$LOG_DIR" "$REPORTS_DIR" "$QUARANTINE_DIR" "$REJECTED_DIR" "$ARCHIVE_DIR" "$PROCESSING_DIR"
    acquire_lock
    trap 'release_lock; log_info "Pipeline interrupted."' INT TERM EXIT

    log_info "=========================================="
    log_info "Pipeline started - $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "=========================================="

    local processed=0 failed=0 skipped=0

    shopt -s nullglob
    for f in "$INCOMING_DIR"/TXN_*.csv; do
        if process_file "$f"; then
            processed=$((processed + 1))
        else
            failed=$((failed + 1))
        fi
    done
    shopt -u nullglob

    rotate_logs

    log_info "=========================================="
    log_info "Pipeline complete: processed=$processed failed=$failed skipped=$skipped"
    log_info "=========================================="

    release_lock
    trap - INT TERM EXIT
}

main "$@"
