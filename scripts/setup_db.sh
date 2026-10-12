#!/usr/bin/env bash

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_NAME="${DB_NAME:-banking_pipeline}"
DB_USER="${DB_USER:-pipeline_user}"
DB_PASS="${DB_PASS:-pipeline_pass}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DATA_DIR="$PIPELINE_DIR/data"

echo "[INFO] Initialising MySQL schema..."
mysql -h "$DB_HOST" -P "$DB_PORT" -u root -p < "$PIPELINE_DIR/sql/schema.sql"

echo "[INFO] Loading account master data..."
mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -e "LOAD DATA LOCAL INFILE '${DATA_DIR}/account_master.csv'
        INTO TABLE account_master
        FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '\"'
        LINES TERMINATED BY '\n'
        IGNORE 1 ROWS
        (account_id, account_name, account_type, branch, status);"

echo "[INFO] Verifying account_master row count..."
mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -e "SELECT COUNT(*) AS account_count FROM account_master;"

echo "[INFO] Setup complete."
