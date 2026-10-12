import csv
import os
import random
import string
from datetime import date, timedelta

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
INCOMING_DIR = os.path.join(BASE_DIR, "..", "incoming")
DATA_DIR = BASE_DIR

BRANCHES = ["MUM001", "DEL002", "BLR003", "CHN004", "HYD005"]
TXN_TYPES = ["CREDIT", "DEBIT", "TRANSFER", "REVERSAL"]
ACCOUNT_IDS = [f"AC{str(i).zfill(6)}" for i in range(1, 201)]

def random_ref():
    return "REF" + "".join(random.choices(string.digits, k=10))

def random_amount(positive=True):
    amount = round(random.uniform(100.0, 500000.0), 2)
    return amount if positive else -amount

def random_date(base_date, spread=0):
    delta = random.randint(-spread, 0)
    return (base_date + timedelta(days=delta)).strftime("%Y-%m-%d")

def write_control_file(filepath, row_count, total_amount):
    with open(filepath, "w") as f:
        f.write(f"ROW_COUNT={row_count}\n")
        f.write(f"TOTAL_AMOUNT={total_amount:.2f}\n")

def generate_clean_file(file_date):
    filename = f"TXN_{file_date.strftime('%Y%m%d')}.csv"
    filepath = os.path.join(INCOMING_DIR, filename)
    refs = set()
    num_records = random.randint(80, 150)
    total = 0.0
    with open(filepath, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["account_id", "txn_date", "amount", "txn_type", "branch", "ref_number"])
        for _ in range(num_records):
            ref = random_ref()
            while ref in refs:
                ref = random_ref()
            refs.add(ref)
            acc = random.choice(ACCOUNT_IDS)
            txn_date = random_date(file_date, spread=2)
            amount = random_amount()
            txn_type = random.choice(TXN_TYPES)
            branch = random.choice(BRANCHES)
            writer.writerow([acc, txn_date, f"{amount:.2f}", txn_type, branch, ref])
            total += amount
    ctrl_path = filepath.replace(".csv", ".ctrl")
    write_control_file(ctrl_path, num_records, total)
    return filename, num_records, total

def generate_bad_files(file_date):
    bad_date = file_date + timedelta(days=1)
    wrong_name_path = os.path.join(INCOMING_DIR, f"TRANSACTIONS_{bad_date.strftime('%Y%m%d')}.csv")
    with open(wrong_name_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["account_id", "txn_date", "amount", "txn_type", "branch", "ref_number"])
        writer.writerow([random.choice(ACCOUNT_IDS), file_date.strftime("%Y-%m-%d"), "1000.00", "CREDIT", "MUM001", random_ref()])
    ctrl_path = wrong_name_path.replace(".csv", ".ctrl")
    write_control_file(ctrl_path, 1, 1000.00)

    bad_date2 = file_date + timedelta(days=2)
    no_header_path = os.path.join(INCOMING_DIR, f"TXN_{bad_date2.strftime('%Y%m%d')}.csv")
    with open(no_header_path, "w", newline="") as f:
        writer = csv.writer(f)
        for _ in range(5):
            writer.writerow([random.choice(ACCOUNT_IDS), file_date.strftime("%Y-%m-%d"), "500.00", "DEBIT", "DEL002", random_ref()])
    ctrl_path = no_header_path.replace(".csv", ".ctrl")
    write_control_file(ctrl_path, 5, 2500.00)

    bad_date3 = file_date + timedelta(days=3)
    wrong_count_path = os.path.join(INCOMING_DIR, f"TXN_{bad_date3.strftime('%Y%m%d')}.csv")
    with open(wrong_count_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["account_id", "txn_date", "amount", "txn_type", "branch", "ref_number"])
        for _ in range(10):
            writer.writerow([random.choice(ACCOUNT_IDS), file_date.strftime("%Y-%m-%d"), "200.00", "CREDIT", "BLR003", random_ref()])
    ctrl_path = wrong_count_path.replace(".csv", ".ctrl")
    write_control_file(ctrl_path, 99, 999999.00)

def generate_dirty_file(file_date):
    bad_date4 = file_date + timedelta(days=4)
    filename = f"TXN_{bad_date4.strftime('%Y%m%d')}.csv"
    filepath = os.path.join(INCOMING_DIR, filename)
    refs = set()
    total = 0.0

    with open(filepath, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["account_id", "txn_date", "amount", "txn_type", "branch", "ref_number"])

        for _ in range(30):
            ref = random_ref()
            while ref in refs:
                ref = random_ref()
            refs.add(ref)
            amount = random_amount()
            writer.writerow([random.choice(ACCOUNT_IDS), file_date.strftime("%Y-%m-%d"), f"{amount:.2f}", random.choice(TXN_TYPES), random.choice(BRANCHES), ref])
            total += amount

        writer.writerow(["", file_date.strftime("%Y-%m-%d"), "5000.00", "CREDIT", "MUM001", random_ref()])
        writer.writerow([random.choice(ACCOUNT_IDS), "", "3000.00", "DEBIT", "DEL002", random_ref()])
        writer.writerow([random.choice(ACCOUNT_IDS), file_date.strftime("%Y-%m-%d"), "2000.00", "CREDIT", "", random_ref()])

        dup_ref = random_ref()
        dup_row = [random.choice(ACCOUNT_IDS), file_date.strftime("%Y-%m-%d"), "1500.00", "CREDIT", "HYD005", dup_ref]
        writer.writerow(dup_row)
        writer.writerow(dup_row)

        writer.writerow([random.choice(ACCOUNT_IDS), file_date.strftime("%Y-%m-%d"), "-9999.99", "DEBIT", "CHN004", random_ref()])
        writer.writerow([random.choice(ACCOUNT_IDS), file_date.strftime("%Y-%m-%d"), "INVALID_AMT", "TRANSFER", "BLR003", random_ref()])
        writer.writerow([random.choice(ACCOUNT_IDS), "2025-13-45", "800.00", "REVERSAL", "MUM001", random_ref()])
        writer.writerow(["AC999999", file_date.strftime("%Y-%m-%d"), "12000.00", "CREDIT", "DEL002", random_ref()])

    total_rows = 39
    ctrl_path = filepath.replace(".csv", ".ctrl")
    write_control_file(ctrl_path, total_rows, total)

def generate_account_master():
    filepath = os.path.join(DATA_DIR, "account_master.csv")
    with open(filepath, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["account_id", "account_name", "account_type", "branch", "status"])
        for acc in ACCOUNT_IDS:
            name = f"Customer_{acc}"
            acc_type = random.choice(["SAVINGS", "CURRENT", "FIXED_DEPOSIT"])
            branch = random.choice(BRANCHES)
            status = "ACTIVE"
            writer.writerow([acc, name, acc_type, branch, status])

def generate_large_file():
    filepath = os.path.join(DATA_DIR, "TXN_LARGE.csv")
    num_records = 500000
    total = 0.0
    with open(filepath, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["account_id", "txn_date", "amount", "txn_type", "branch", "ref_number"])
        base_date = date(2025, 1, 1)
        for i in range(num_records):
            ref = f"REF{str(i).zfill(10)}"
            acc = random.choice(ACCOUNT_IDS)
            txn_date = (base_date + timedelta(days=random.randint(0, 364))).strftime("%Y-%m-%d")
            amount = random_amount()
            txn_type = random.choice(TXN_TYPES)
            branch = random.choice(BRANCHES)
            writer.writerow([acc, txn_date, f"{amount:.2f}", txn_type, branch, ref])
            total += amount
    print(f"Large file: {num_records} rows, total={total:.2f}")

if __name__ == "__main__":
    os.makedirs(INCOMING_DIR, exist_ok=True)
    random.seed(42)
    base = date(2025, 10, 1)
    generate_account_master()
    generate_clean_file(base)
    generate_bad_files(base)
    generate_dirty_file(base)
    generate_large_file()
    print("All sample data generated.")
