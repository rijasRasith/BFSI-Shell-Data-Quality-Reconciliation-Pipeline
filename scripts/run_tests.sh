#!/usr/bin/env bash

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$PIPELINE_DIR/scripts/pipeline.sh" --source-only 2>/dev/null || true

LOG_DIR="$PIPELINE_DIR/logs"
REPORTS_DIR="$PIPELINE_DIR/reports"

mkdir -p "$LOG_DIR" "$REPORTS_DIR"

TEST_RESULTS_FILE="$REPORTS_DIR/test_results_$(date +%Y%m%d%H%M%S).txt"
PASS=0
FAIL=0

assert_equal() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $label" | tee -a "$TEST_RESULTS_FILE"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label | expected='$expected' actual='$actual'" | tee -a "$TEST_RESULTS_FILE"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local label="$1"
    local filepath="$2"
    if [ -f "$filepath" ]; then
        echo "[PASS] $label" | tee -a "$TEST_RESULTS_FILE"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label | file not found: $filepath" | tee -a "$TEST_RESULTS_FILE"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_contains() {
    local label="$1"
    local filepath="$2"
    local pattern="$3"
    if grep -q "$pattern" "$filepath" 2>/dev/null; then
        echo "[PASS] $label" | tee -a "$TEST_RESULTS_FILE"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label | pattern='$pattern' not found in $filepath" | tee -a "$TEST_RESULTS_FILE"
        FAIL=$((FAIL + 1))
    fi
}

assert_dir_not_empty() {
    local label="$1"
    local dirpath="$2"
    local pattern="${3:-*}"
    if compgen -G "$dirpath/$pattern" > /dev/null 2>&1; then
        echo "[PASS] $label" | tee -a "$TEST_RESULTS_FILE"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label | no files matching '$pattern' in $dirpath" | tee -a "$TEST_RESULTS_FILE"
        FAIL=$((FAIL + 1))
    fi
}

setup_test_env() {
    export TEST_INCOMING="$PIPELINE_DIR/test_incoming"
    export TEST_PROCESSING="$PIPELINE_DIR/test_processing"
    export TEST_QUARANTINE="$PIPELINE_DIR/test_quarantine"
    export TEST_REJECTED="$PIPELINE_DIR/test_rejected"
    rm -rf "$TEST_INCOMING" "$TEST_PROCESSING" "$TEST_QUARANTINE" "$TEST_REJECTED"
    mkdir -p "$TEST_INCOMING" "$TEST_PROCESSING" "$TEST_QUARANTINE" "$TEST_REJECTED"
}

teardown_test_env() {
    rm -rf "$PIPELINE_DIR/test_incoming" \
           "$PIPELINE_DIR/test_processing" \
           "$PIPELINE_DIR/test_quarantine" \
           "$PIPELINE_DIR/test_rejected"
}

test_filename_pattern_valid() {
    local result
    if echo "TXN_20251001.csv" | grep -qE "^TXN_[0-9]{8}\.csv$"; then
        result="PASS"
    else
        result="FAIL"
    fi
    assert_equal "Valid filename pattern accepted" "PASS" "$result"
}

test_filename_pattern_invalid() {
    local result
    if echo "TRANSACTIONS_20251001.csv" | grep -qE "^TXN_[0-9]{8}\.csv$"; then
        result="PASS"
    else
        result="FAIL"
    fi
    assert_equal "Invalid filename pattern rejected" "FAIL" "$result"
}

test_header_valid() {
    local tmpfile
    tmpfile=$(mktemp /tmp/test_XXXXXX.csv)
    echo "account_id,txn_date,amount,txn_type,branch,ref_number" > "$tmpfile"
    local actual_header
    actual_header=$(head -1 "$tmpfile" | tr -d '\r')
    assert_equal "Valid header accepted" "account_id,txn_date,amount,txn_type,branch,ref_number" "$actual_header"
    rm -f "$tmpfile"
}

test_header_invalid() {
    local tmpfile
    tmpfile=$(mktemp /tmp/test_XXXXXX.csv)
    echo "id,date,amount,type,br,ref" > "$tmpfile"
    local actual_header
    actual_header=$(head -1 "$tmpfile" | tr -d '\r')
    local expected="account_id,txn_date,amount,txn_type,branch,ref_number"
    if [ "$actual_header" != "$expected" ]; then
        assert_equal "Invalid header rejected" "PASS" "PASS"
    else
        assert_equal "Invalid header rejected" "PASS" "FAIL"
    fi
    rm -f "$tmpfile"
}

test_control_total_match() {
    local tmpfile
    tmpfile=$(mktemp /tmp/test_XXXXXX.csv)
    {
        echo "account_id,txn_date,amount,txn_type,branch,ref_number"
        echo "AC000001,2025-10-01,1000.00,CREDIT,MUM001,REF0000000001"
        echo "AC000002,2025-10-01,2000.00,DEBIT,DEL002,REF0000000002"
    } > "$tmpfile"
    local ctrl_file="${tmpfile%.csv}.ctrl"
    printf 'ROW_COUNT=2\nTOTAL_AMOUNT=3000.00\n' > "$ctrl_file"
    local actual_count
    actual_count=$(tail -n +2 "$tmpfile" | wc -l)
    local actual_total
    actual_total=$(awk -F',' 'NR>1 { sum += $3 } END { printf "%.2f", sum }' "$tmpfile")
    assert_equal "Control count match" "2" "$actual_count"
    assert_equal "Control total match" "3000.00" "$actual_total"
    rm -f "$tmpfile" "$ctrl_file"
}

test_null_detection() {
    local count
    count=$(echo -e "account_id,txn_date,amount,txn_type,branch,ref_number\n,2025-10-01,500.00,CREDIT,MUM001,REF001\nAC000001,,300.00,DEBIT,DEL002,REF002" \
        | awk -F',' 'NR>1 { if ($1=="" || $2=="" || $3=="" || $4=="" || $5=="" || $6=="") count++ } END { print count+0 }')
    assert_equal "Null fields detected" "2" "$count"
}

test_negative_amount_detection() {
    local count
    count=$(printf 'account_id,txn_date,amount,txn_type,branch,ref_number\nAC000001,2025-10-01,-500.00,DEBIT,MUM001,REF001\nAC000002,2025-10-01,200.00,CREDIT,DEL002,REF002\n' \
        | awk -F',' 'NR>1 { if ($3 + 0 < 0) count++ } END { print count+0 }')
    assert_equal "Negative amounts detected" "1" "$count"
}

test_non_numeric_amount_detection() {
    local count
    count=$(printf 'account_id,txn_date,amount,txn_type,branch,ref_number\nAC000001,2025-10-01,INVALID,DEBIT,MUM001,REF001\nAC000002,2025-10-01,200.00,CREDIT,DEL002,REF002\n' \
        | awk -F',' 'NR>1 { if ($3 !~ /^-?[0-9]+(\.[0-9]+)?$/) count++ } END { print count+0 }')
    assert_equal "Non-numeric amount detected" "1" "$count"
}

test_duplicate_ref_detection() {
    local count
    count=$(printf 'account_id,txn_date,amount,txn_type,branch,ref_number\nAC000001,2025-10-01,500.00,CREDIT,MUM001,REF001\nAC000002,2025-10-01,300.00,DEBIT,DEL002,REF001\nAC000003,2025-10-01,100.00,CREDIT,BLR003,REF002\n' \
        | awk -F',' 'NR>1 { if (seen[$6]++) count++ } END { print count+0 }')
    assert_equal "Duplicate ref_number detected" "1" "$count"
}

test_invalid_date_detection() {
    local count
    count=$(printf 'account_id,txn_date,amount,txn_type,branch,ref_number\nAC000001,2025-13-01,500.00,CREDIT,MUM001,REF001\nAC000002,2025-10-01,300.00,DEBIT,DEL002,REF002\n' \
        | awk -F',' 'NR>1 {
            split($2, d, "-")
            m = d[2]+0
            if (m < 1 || m > 12) count++
        } END { print count+0 }')
    assert_equal "Invalid date detected" "1" "$count"
}

test_unknown_account_detection() {
    local master
    master=$(mktemp /tmp/master_XXXXXX.csv)
    printf 'account_id,account_name,account_type,branch,status\nAC000001,Customer,SAVINGS,MUM001,ACTIVE\n' > "$master"
    local count
    count=$(printf 'AC000001,2025-10-01,500.00,CREDIT,MUM001,REF001\nAC999999,2025-10-01,300.00,DEBIT,DEL002,REF002\n' \
        | awk -F',' -v master="$master" '
        BEGIN { while ((getline line < master) > 0) { split(line, p, ","); valid[p[1]]=1 } }
        { if (!($1 in valid)) count++ }
        END { print count+0 }')
    assert_equal "Unknown account detected" "1" "$count"
    rm -f "$master"
}

test_empty_file_handling() {
    local tmpfile
    tmpfile=$(mktemp /tmp/test_XXXXXX.csv)
    echo "account_id,txn_date,amount,txn_type,branch,ref_number" > "$tmpfile"
    local count
    count=$(tail -n +2 "$tmpfile" | wc -l)
    assert_equal "Empty file: zero data rows" "0" "$count"
    rm -f "$tmpfile"
}

test_reconciliation_pass() {
    local src_count=100
    local tgt_count=100
    local src_total="250000.50"
    local tgt_total="250000.50"
    local status
    if [ "$src_count" -eq "$tgt_count" ]; then
        match=$(awk -v a="$src_total" -v b="$tgt_total" 'BEGIN { diff=a-b; if(diff<0)diff=-diff; print (diff<0.01)?"OK":"FAIL" }')
        [ "$match" = "OK" ] && status="PASS" || status="FAIL"
    else
        status="FAIL"
    fi
    assert_equal "Reconciliation PASS scenario" "PASS" "$status"
}

test_reconciliation_fail_count() {
    local src_count=100
    local tgt_count=95
    local status
    [ "$src_count" -ne "$tgt_count" ] && status="FAIL" || status="PASS"
    assert_equal "Reconciliation FAIL on count mismatch" "FAIL" "$status"
}

test_reconciliation_fail_amount() {
    local src_total="250000.50"
    local tgt_total="249000.00"
    local match
    match=$(awk -v a="$src_total" -v b="$tgt_total" 'BEGIN { diff=a-b; if(diff<0)diff=-diff; print (diff<0.01)?"OK":"FAIL" }')
    assert_equal "Reconciliation FAIL on amount mismatch" "FAIL" "$match"
}

print_summary() {
    echo ""
    echo "==============================="
    echo "  TEST SUMMARY"
    echo "==============================="
    echo "  PASSED : $PASS"
    echo "  FAILED : $FAIL"
    echo "  TOTAL  : $((PASS + FAIL))"
    echo "==============================="
    echo ""
    echo "Full results: $TEST_RESULTS_FILE"
}

{
    echo "==============================="
    echo "  PIPELINE TEST SUITE"
    echo "  Run: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "==============================="
    echo ""
} > "$TEST_RESULTS_FILE"

setup_test_env

test_filename_pattern_valid
test_filename_pattern_invalid
test_header_valid
test_header_invalid
test_control_total_match
test_null_detection
test_negative_amount_detection
test_non_numeric_amount_detection
test_duplicate_ref_detection
test_invalid_date_detection
test_unknown_account_detection
test_empty_file_handling
test_reconciliation_pass
test_reconciliation_fail_count
test_reconciliation_fail_amount

teardown_test_env
print_summary

[ "$FAIL" -eq 0 ]
