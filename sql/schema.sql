CREATE DATABASE IF NOT EXISTS banking_pipeline
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE banking_pipeline;

CREATE TABLE IF NOT EXISTS account_master (
    account_id      VARCHAR(10)     NOT NULL PRIMARY KEY,
    account_name    VARCHAR(100)    NOT NULL,
    account_type    ENUM('SAVINGS','CURRENT','FIXED_DEPOSIT') NOT NULL,
    branch          VARCHAR(10)     NOT NULL,
    status          ENUM('ACTIVE','INACTIVE','SUSPENDED') NOT NULL DEFAULT 'ACTIVE',
    created_at      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS txn_staging (
    id              BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    account_id      VARCHAR(10)     NOT NULL,
    txn_date        DATE            NOT NULL,
    amount          DECIMAL(15, 2)  NOT NULL,
    txn_type        ENUM('CREDIT','DEBIT','TRANSFER','REVERSAL') NOT NULL,
    branch          VARCHAR(10)     NOT NULL,
    ref_number      VARCHAR(20)     NOT NULL,
    source_file     VARCHAR(100)    NOT NULL,
    loaded_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_staging_ref (ref_number, source_file)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS txn_final (
    id              BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    account_id      VARCHAR(10)     NOT NULL,
    txn_date        DATE            NOT NULL,
    amount          DECIMAL(15, 2)  NOT NULL,
    txn_type        ENUM('CREDIT','DEBIT','TRANSFER','REVERSAL') NOT NULL,
    branch          VARCHAR(10)     NOT NULL,
    ref_number      VARCHAR(20)     NOT NULL UNIQUE,
    source_file     VARCHAR(100)    NOT NULL,
    loaded_at       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_txn_date (txn_date),
    INDEX idx_account   (account_id),
    INDEX idx_branch    (branch),
    INDEX idx_source    (source_file)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS pipeline_run_log (
    run_id          BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    source_file     VARCHAR(100)    NOT NULL,
    run_date        TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    src_count       INT             NOT NULL DEFAULT 0,
    tgt_count       INT             NOT NULL DEFAULT 0,
    src_total       DECIMAL(20, 2)  NOT NULL DEFAULT 0.00,
    tgt_total       DECIMAL(20, 2)  NOT NULL DEFAULT 0.00,
    recon_status    ENUM('PASS','FAIL','SKIPPED') NOT NULL,
    mismatch_detail TEXT            NULL,
    INDEX idx_source_file (source_file),
    INDEX idx_run_date    (run_date)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS file_quarantine_log (
    log_id          BIGINT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    filename        VARCHAR(100)    NOT NULL,
    quarantine_time TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reason          VARCHAR(100)    NOT NULL,
    INDEX idx_filename (filename)
) ENGINE=InnoDB;

CREATE USER IF NOT EXISTS 'pipeline_user'@'localhost' IDENTIFIED BY 'pipeline_pass';
GRANT SELECT, INSERT, UPDATE, DELETE, LOAD DATA ON banking_pipeline.* TO 'pipeline_user'@'localhost';
FLUSH PRIVILEGES;
