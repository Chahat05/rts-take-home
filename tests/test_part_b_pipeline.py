"""
Tests for the Part B warehouse build (bronze -> silver -> gold -> quality).

Each test writes a few tiny, hand-made raw snapshot files into a temporary
folder, runs the real build, and checks the results.

Run:  pytest -q tests/test_part_b_pipeline.py
"""
import gzip
import json
import shutil
import sys
from pathlib import Path

import duckdb
import pytest

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT / "src"))
import build_warehouse  # noqa: E402

T1, T2 = 1792200000, 1792200120          # two snapshots, 2 minutes apart
UNION_STATION = (38.89696, -77.00493)    # hub 1 in reference/travel_hubs.csv


def write(root: Path, feed: str, last_updated: int, data: dict) -> None:
    path = root / "data" / "raw" / feed / "2026-10-17" / f"{last_updated}.json.gz"
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"data": data, "last_updated": last_updated, "ttl": 60, "version": "2.3"}
    with gzip.open(path, "wt") as f:
        json.dump(payload, f)


def bike(bike_id, lat, lon, range_m=20000):
    return {"bike_id": bike_id, "lat": lat, "lon": lon, "is_reserved": 0, "is_disabled": 0,
            "current_range_meters": range_m, "vehicle_type_id": "2"}


def station_status(station_id, bikes, ebikes, docks):
    return {"station_id": station_id, "num_bikes_available": bikes, "num_ebikes_available": ebikes,
            "num_docks_available": docks, "num_bikes_disabled": 0, "num_docks_disabled": 0,
            "is_installed": 1, "is_renting": 1, "is_returning": 1, "last_reported": T1}


@pytest.fixture
def project(tmp_path, monkeypatch):
    """A temporary project folder with the real SQL + hub list and tiny raw data."""
    shutil.copytree(PROJECT / "sql", tmp_path / "sql")
    shutil.copytree(PROJECT / "reference", tmp_path / "reference")
    monkeypatch.chdir(tmp_path)

    lat, lon = UNION_STATION
    write(tmp_path, "vehicle_types", T1, {"vehicle_types": [
        {"vehicle_type_id": "2", "form_factor": "bicycle", "propulsion_type": "electric_assist",
         "max_range_meters": 55000}]})
    write(tmp_path, "station_information", T1, {"stations": [
        {"station_id": "S1", "name": "Next to Union Station", "short_name": "1",
         "lat": lat + 0.001, "lon": lon, "region_id": "42", "capacity": 20}]})
    for t in (T1, T2):
        write(tmp_path, "station_status", t, {"stations": [station_status("S1", 5, 2, 15)]})
    # T1: two bikes near Union Station (one with a nearly empty battery), one far away.
    write(tmp_path, "free_bike_status", T1, {"bikes": [
        bike("a", lat + 0.0005, lon), bike("b", lat, lon + 0.0005, range_m=1000),
        bike("far", 38.95, -77.10)]})
    # T2: no bikes at all anywhere.
    write(tmp_path, "free_bike_status", T2, {"bikes": []})
    return tmp_path


def availability(con, snapshot):
    return con.execute(
        """SELECT total_bikes, free_ebikes, usable_free_ebikes, docked_bikes, open_docks
           FROM gold_hub_availability
           WHERE hub_id = 1 AND snapshot_ts = to_timestamp(?)""", [snapshot]).fetchone()


def test_counts_bikes_near_a_hub(project):
    con = duckdb.connect()
    build_warehouse.build(con)
    # 5 docked + 2 free nearby (the far bike is excluded); only 1 free e-bike has >= 5 km range
    assert availability(con, T1) == (7, 2, 1, 5, 15)


def test_snapshot_with_zero_bikes_still_has_a_row(project):
    con = duckdb.connect()
    build_warehouse.build(con)
    # The spine guarantees a row for T2 even though the feed had no bikes.
    assert availability(con, T2) == (5, 0, 0, 5, 15)


def test_build_is_idempotent(project):
    con = duckdb.connect()
    build_warehouse.build(con)
    first = con.execute("SELECT COUNT(*), SUM(total_bikes) FROM gold_hub_availability").fetchone()
    build_warehouse.build(con)
    second = con.execute("SELECT COUNT(*), SUM(total_bikes) FROM gold_hub_availability").fetchone()
    assert first == second


def test_duplicate_raw_rows_are_removed(project):
    lat, lon = UNION_STATION
    write(project, "free_bike_status", T1, {"bikes": [bike("a", lat, lon), bike("a", lat, lon)]})
    con = duckdb.connect()
    build_warehouse.build(con)
    assert con.execute(
        "SELECT COUNT(*) FROM silver_free_bikes WHERE bike_id = 'a' AND snapshot_ts = to_timestamp(?)",
        [T1]).fetchone()[0] == 1


def test_negative_counts_fail_the_quality_gate(project):
    write(project, "station_status", T2, {"stations": [station_status("S1", -1, 0, 15)]})
    con = duckdb.connect()
    results = {name: (severity, failed) for name, severity, failed in build_warehouse.build(con)}
    assert results["Negative station counts"] == ("ERROR", 1)
