from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import StructType, StructField, StringType, DateType, DecimalType
import os
import time

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
REPORTS_DIR = os.path.join(BASE_DIR, "reports")

INPUT_FILE = os.path.join(DATA_DIR, "TXN_LARGE.csv")
OUTPUT_REPORT = os.path.join(REPORTS_DIR, "pyspark_summary.csv")

SCHEMA = StructType([
    StructField("account_id",  StringType(),  nullable=False),
    StructField("txn_date",    StringType(),  nullable=False),
    StructField("amount",      StringType(),  nullable=False),
    StructField("txn_type",    StringType(),  nullable=False),
    StructField("branch",      StringType(),  nullable=False),
    StructField("ref_number",  StringType(),  nullable=False),
])


def build_spark_session():
    return (
        SparkSession.builder
        .appName("BankingTxnSummary")
        .config("spark.sql.shuffle.partitions", "8")
        .config("spark.driver.memory", "2g")
        .getOrCreate()
    )


def load_transactions(spark):
    return (
        spark.read
        .option("header", "true")
        .option("inferSchema", "false")
        .schema(SCHEMA)
        .csv(INPUT_FILE)
    )


def clean_transactions(df):
    return (
        df
        .filter(
            F.col("account_id").isNotNull() &
            F.col("txn_date").isNotNull() &
            F.col("amount").isNotNull() &
            F.col("txn_type").isNotNull() &
            F.col("branch").isNotNull() &
            F.col("ref_number").isNotNull()
        )
        .withColumn("amount_num", F.col("amount").cast("decimal(15,2)"))
        .filter(F.col("amount_num").isNotNull() & (F.col("amount_num") >= 0))
        .withColumn("txn_date_parsed", F.to_date(F.col("txn_date"), "yyyy-MM-dd"))
        .filter(F.col("txn_date_parsed").isNotNull())
        .withColumn("txn_month", F.date_format(F.col("txn_date_parsed"), "yyyy-MM"))
        .withColumn("txn_day",   F.date_format(F.col("txn_date_parsed"), "yyyy-MM-dd"))
    )


def compute_by_txn_type(df):
    return (
        df.groupBy("txn_type")
        .agg(
            F.count("*").alias("record_count"),
            F.sum("amount_num").alias("total_amount"),
            F.avg("amount_num").alias("avg_amount"),
            F.min("amount_num").alias("min_amount"),
            F.max("amount_num").alias("max_amount"),
        )
        .orderBy(F.desc("total_amount"))
    )


def compute_by_branch(df):
    return (
        df.groupBy("branch")
        .agg(
            F.count("*").alias("record_count"),
            F.sum("amount_num").alias("total_amount"),
            F.avg("amount_num").alias("avg_amount"),
        )
        .orderBy(F.desc("total_amount"))
    )


def compute_by_day(df):
    return (
        df.groupBy("txn_day")
        .agg(
            F.count("*").alias("record_count"),
            F.sum("amount_num").alias("total_amount"),
        )
        .orderBy("txn_day")
    )


def compute_by_branch_and_type(df):
    return (
        df.groupBy("branch", "txn_type")
        .agg(
            F.count("*").alias("record_count"),
            F.sum("amount_num").alias("total_amount"),
        )
        .orderBy("branch", "txn_type")
    )


def write_csv_summary(df, label, out_dir):
    out_path = os.path.join(out_dir, label)
    df.coalesce(1).write.option("header", "true").mode("overwrite").csv(out_path)


def python_baseline(filepath):
    import csv
    from collections import defaultdict
    counts = defaultdict(int)
    totals = defaultdict(float)
    start = time.time()
    with open(filepath, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                amount = float(row["amount"])
                if amount < 0:
                    continue
                key = row["txn_type"]
                counts[key] += 1
                totals[key] += amount
            except (ValueError, KeyError):
                continue
    elapsed = time.time() - start
    return counts, totals, elapsed


def main():
    os.makedirs(REPORTS_DIR, exist_ok=True)

    print(f"[INFO] Starting Python baseline pass on: {INPUT_FILE}")
    py_counts, py_totals, py_elapsed = python_baseline(INPUT_FILE)
    print(f"[INFO] Python baseline completed in {py_elapsed:.2f}s")
    for txn_type, count in sorted(py_counts.items()):
        print(f"       {txn_type}: count={count}, total={py_totals[txn_type]:.2f}")

    spark = build_spark_session()
    spark.sparkContext.setLogLevel("WARN")

    print(f"\n[INFO] Starting PySpark job on: {INPUT_FILE}")
    spark_start = time.time()

    raw_df = load_transactions(spark)
    clean_df = clean_transactions(raw_df)
    clean_df.cache()

    total_records = clean_df.count()
    print(f"[INFO] Clean records loaded: {total_records:,}")

    by_type_df  = compute_by_txn_type(clean_df)
    by_branch_df = compute_by_branch(clean_df)
    by_day_df   = compute_by_day(clean_df)
    by_branch_type_df = compute_by_branch_and_type(clean_df)

    out_dir = os.path.join(REPORTS_DIR, "pyspark_output")
    write_csv_summary(by_type_df,        "summary_by_txn_type",    out_dir)
    write_csv_summary(by_branch_df,      "summary_by_branch",      out_dir)
    write_csv_summary(by_day_df,         "summary_by_day",         out_dir)
    write_csv_summary(by_branch_type_df, "summary_by_branch_type", out_dir)

    spark_elapsed = time.time() - spark_start

    print(f"\n[INFO] PySpark job completed in {spark_elapsed:.2f}s")
    print(f"[INFO] Outputs written to: {out_dir}")
    print(f"\n[COMPARISON]")
    print(f"  Python baseline : {py_elapsed:.2f}s")
    print(f"  PySpark job     : {spark_elapsed:.2f}s")

    summary_path = os.path.join(REPORTS_DIR, "pyspark_run_summary.txt")
    with open(summary_path, "w") as f:
        f.write(f"Input File       : {INPUT_FILE}\n")
        f.write(f"Total Records    : {total_records:,}\n")
        f.write(f"Python Baseline  : {py_elapsed:.2f}s\n")
        f.write(f"PySpark Runtime  : {spark_elapsed:.2f}s\n")
        f.write(f"\n--- By Transaction Type ---\n")
        for row in by_type_df.collect():
            f.write(f"  {row['txn_type']:12s} count={row['record_count']:>8,}  total={float(row['total_amount']):>18,.2f}\n")
        f.write(f"\n--- By Branch ---\n")
        for row in by_branch_df.collect():
            f.write(f"  {row['branch']:10s} count={row['record_count']:>8,}  total={float(row['total_amount']):>18,.2f}\n")

    print(f"[INFO] Run summary written to: {summary_path}")
    spark.stop()


if __name__ == "__main__":
    main()
