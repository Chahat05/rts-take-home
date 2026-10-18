"""
Tests for the Part A warehouse SQL.

Builds the schema in an in-memory DuckDB database, loads a small,
hand-checkable sample, and checks the Q2 cross-sell query and the Q3
growth query - including a business line with ZERO bookings in a year.

Run:  pytest -q tests/test_part_a_sql.py
"""
from datetime import date, datetime, timedelta
from pathlib import Path

import duckdb
import pytest

SQL_DIR = Path(__file__).resolve().parent.parent / "sql" / "part_a"


@pytest.fixture
def con():
    con = duckdb.connect()
    con.execute((SQL_DIR / "01_schema.sql").read_text())

    # Calendar 2023-2026
    d = date(2023, 1, 1)
    while d <= date(2026, 12, 31):
        con.execute(
            "INSERT INTO dim_date VALUES (?, ?, ?, ?, ?, ?, ?, FALSE)",
            [int(d.strftime("%Y%m%d")), d, d.strftime("%A"), d.weekday() >= 5,
             d.month, (d.month - 1) // 3 + 1, d.year],
        )
        d += timedelta(days=1)

    con.execute("INSERT INTO dim_customer VALUES (1, 'u1', 'hash1', TRUE, '2023-01-01', '2023-01-01')")
    con.execute("INSERT INTO dim_customer VALUES (2, NULL, 'hash2', FALSE, '2023-01-01', NULL)")
    return con


def add_bookings(con, year, line, n, status="Confirmed", start_key=0):
    for i in range(n):
        key = start_key + i
        con.execute(
            "INSERT INTO fact_booking VALUES (?, ?, 1, ?, ?, ?, NULL, ?, 100.00)",
            [key, f"o{key}", line, int(f"{year}0615"), datetime(year, 6, 15), status],
        )


def run_q3(con):
    rows = con.execute((SQL_DIR / "03_q3_booking_growth.sql").read_text()).fetchall()
    return {(r[0], r[1]): (r[2], r[3], r[4]) for r in rows}  # (year, line) -> (bookings, prev, pct)


def test_growth_is_calculated_per_business_line(con):
    add_bookings(con, 2024, "Flight", 10, start_key=0)
    add_bookings(con, 2025, "Flight", 15, start_key=100)
    result = run_q3(con)
    assert result[(2025, "Flight")] == (15, 10, 50.0)       # (15 - 10) / 10 = +50%


def test_cancelled_bookings_are_excluded(con):
    add_bookings(con, 2024, "Hotel", 4, start_key=0)
    add_bookings(con, 2025, "Hotel", 4, start_key=100)
    add_bookings(con, 2025, "Hotel", 4, status="Cancelled", start_key=200)
    assert run_q3(con)[(2025, "Hotel")] == (4, 4, 0.0)       # cancellations ignored


def test_year_with_zero_bookings_is_not_skipped(con):
    add_bookings(con, 2023, "Car", 8, start_key=0)
    # 2024: no Car bookings at all (other lines keep 2024 in range)
    add_bookings(con, 2024, "Flight", 5, start_key=100)
    add_bookings(con, 2025, "Car", 6, start_key=200)
    result = run_q3(con)
    assert result[(2024, "Car")] == (0, 8, -100.0)          # compared with 2023, not skipped
    bookings, prev, pct = result[(2025, "Car")]
    assert (bookings, prev) == (6, 0) and pct is None        # growth from zero is undefined, not an error


def run_q2_cross_sell(con):
    # Query 2 is the second query in the Q2 file, after its "-- Query 2" header.
    text = (SQL_DIR / "02_q2_valuable_queries.sql").read_text()
    query2 = text[text.index("-- Query 2"):]
    return con.execute(query2).fetchall()


def test_cross_sell_counts_flight_orders_with_a_hotel_or_car(con):
    items = [
        # (booking_key, order_id, business_line, status)
        (1, "A", "Flight", "Confirmed"), (2, "A", "Hotel", "Confirmed"),   # flight + hotel
        (3, "B", "Flight", "Confirmed"), (4, "B", "Hotel", "Confirmed"),
        (5, "B", "Car", "Confirmed"),                                       # flight + hotel + car
        (6, "C", "Flight", "Confirmed"),                                    # flight only
        (7, "D", "Flight", "Confirmed"), (8, "D", "Hotel", "Cancelled"),   # hotel cancelled -> flight only
        (9, "E", "Hotel", "Confirmed"),                                     # no flight -> not counted
    ]
    for key, order_id, line, status in items:
        con.execute(
            "INSERT INTO fact_booking VALUES (?, ?, 1, ?, 20250615, ?, NULL, ?, 100.00)",
            [key, order_id, line, datetime(2025, 6, 15), status],
        )
    (month, flight_orders, pct_with_hotel, pct_with_car), = run_q2_cross_sell(con)
    assert flight_orders == 4                  # orders A, B, C, D
    assert pct_with_hotel == 50.0              # A and B (D's hotel was cancelled)
    assert pct_with_car == 25.0                # only B
