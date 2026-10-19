"""
Builds the analytics warehouse from the raw snapshots (bronze -> silver -> gold).

Steps:
  1. SILVER:  clean, typed, de-duplicated tables from the raw JSON files
  2. WEATHER: hourly weather table (empty if no weather has been fetched yet)
  3. GOLD:    bikes / e-bikes / open docks near each hub per snapshot, plus answer views
  4. QUALITY: data quality checks; the build fails if any ERROR-level check fails

Everything is rebuilt from the raw files on each run (CREATE OR REPLACE), so
running it twice gives the same result (idempotent). The raw files are never
modified.

Run from the project folder:
  python src/build_warehouse.py
"""
import logging
import sys
from pathlib import Path

import duckdb

WAREHOUSE_PATH = Path("data/warehouse.duckdb")
SQL_DIR = Path("sql/part_b")
WEATHER_GLOB = "data/raw/weather/*/*.json.gz"

log = logging.getLogger("warehouse")

EMPTY_WEATHER_TABLE = """
CREATE OR REPLACE TABLE silver_weather_hourly (
    hour_ts TIMESTAMPTZ, temperature_c DOUBLE, precipitation_mm DOUBLE,
    precip_band VARCHAR, temp_band VARCHAR
);
"""


def run_sql_file(con: duckdb.DuckDBPyConnection, name: str) -> None:
    log.info("Running %s", name)
    con.execute((SQL_DIR / name).read_text())


def build(con: duckdb.DuckDBPyConnection) -> list[tuple]:
    con.execute("SET TimeZone = 'UTC'")      # store and compare everything in UTC

    run_sql_file(con, "10_silver.sql")

    if list(Path().glob(WEATHER_GLOB)):
        run_sql_file(con, "15_silver_weather.sql")
    else:
        log.warning("No weather files found - run src/fetch_weather.py. Continuing without weather.")
        con.execute(EMPTY_WEATHER_TABLE)

    run_sql_file(con, "20_gold.sql")
    run_sql_file(con, "30_quality_checks.sql")
    return con.execute("SELECT * FROM quality_results ORDER BY severity, check_name").fetchall()


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    WAREHOUSE_PATH.parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(WAREHOUSE_PATH))

    results = build(con)

    print("\nDATA QUALITY")
    for check_name, severity, failed in results:
        status = "PASS" if failed == 0 else severity
        print(f"  [{status:5}] {check_name}: {failed}")

    print("\nHEADLINE: bikes, e-bikes and open docks within 400 m of each hub")
    print(con.execute("SELECT * FROM answer_hub_reliability").df().to_string(index=False))

    snapshots, hubs = con.execute(
        "SELECT COUNT(DISTINCT snapshot_ts), COUNT(DISTINCT hub_id) FROM gold_hub_availability"
    ).fetchone()
    print(f"\nWarehouse: {WAREHOUSE_PATH}  ({snapshots} snapshots x {hubs} hubs)")

    if any(severity == "ERROR" and failed > 0 for _, severity, failed in results):
        log.error("ERROR-level data quality checks failed.")
        sys.exit(1)


if __name__ == "__main__":
    main()
