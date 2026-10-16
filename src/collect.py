"""
Bronze-layer collector for Capital Bikeshare (GBFS 2.3) live feeds.

What it does, every cycle:
  1. Fetches each live feed (free_bike_status, station_status).
  2. Saves every NEW snapshot exactly as received (gzip-compressed) under
     data/raw/<feed>/<YYYY-MM-DD>/<last_updated>.json.gz
  3. Skips snapshots it already has (same last_updated) -> idempotent.
  4. Writes one row per attempt to data/manifest.csv (saved / duplicate / error),
     so gaps and failures are visible later.

Reference feeds (vehicle_types, station_information, system_regions,
system_information) change slowly, so they are refreshed every 6 hours.
Feed URLs are read from gbfs.json (discovery) instead of being hard-coded.

Run:
  python src/collect.py --once            # single cycle, for testing
  caffeinate -i python src/collect.py     # keep polling; Mac stays awake
"""
import argparse
import csv
import gzip
import json
import logging
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import requests

GBFS_DISCOVERY_URL = "https://gbfs.lyft.com/gbfs/2.3/dca-cabi/gbfs.json"
LANGUAGE = "en"

REALTIME_FEEDS = ["free_bike_status", "station_status"]
REFERENCE_FEEDS = ["vehicle_types", "station_information", "system_regions", "system_information"]
REFERENCE_REFRESH_SECONDS = 6 * 60 * 60  # 6 hours

DATA_DIR = Path("data/raw")
MANIFEST_PATH = Path("data/manifest.csv")
LOG_PATH = Path("logs/collector.log")

HTTP_TIMEOUT_SECONDS = 20
MAX_RETRIES = 3
DEFAULT_INTERVAL_SECONDS = 120

MANIFEST_COLUMNS = [
    "run_id", "fetched_at_utc", "feed", "last_updated", "last_updated_utc",
    "ttl", "record_count", "status", "file_path", "error",
]

log = logging.getLogger("collector")


def setup_logging() -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    for handler in (logging.StreamHandler(), logging.FileHandler(LOG_PATH)):
        handler.setFormatter(fmt)
        log.addHandler(handler)
    log.setLevel(logging.INFO)


def fetch(session: requests.Session, url: str) -> tuple[dict, bytes]:
    """GET a URL with a timeout and simple retries. Returns (parsed JSON, raw bytes)."""
    last_error = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            response = session.get(url, timeout=HTTP_TIMEOUT_SECONDS)
            response.raise_for_status()
            return response.json(), response.content
        except (requests.RequestException, ValueError) as exc:
            last_error = exc
            wait = 2 ** attempt  # 2s, 4s, 8s: exponential backoff
            log.warning("Fetch failed (attempt %s/%s) for %s: %s. Retrying in %ss",
                        attempt, MAX_RETRIES, url, exc, wait)
            time.sleep(wait)
    raise RuntimeError(f"Giving up on {url}: {last_error}")


def discover_feeds(session: requests.Session) -> dict[str, str]:
    """Read gbfs.json and return {feed_name: url} for our language."""
    payload, _ = fetch(session, GBFS_DISCOVERY_URL)
    feeds = payload["data"][LANGUAGE]["feeds"]
    return {feed["name"]: feed["url"] for feed in feeds}


def count_records(payload: dict) -> int:
    data = payload.get("data", {})
    for key in ("bikes", "stations", "vehicle_types", "regions"):
        if isinstance(data.get(key), list):
            return len(data[key])
    return 0


def append_manifest(row: dict) -> None:
    is_new_file = not MANIFEST_PATH.exists()
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    with MANIFEST_PATH.open("a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=MANIFEST_COLUMNS)
        if is_new_file:
            writer.writeheader()
        writer.writerow(row)


def collect_feed(session, feed: str, url: str, run_id: str) -> dict:
    """Fetch one feed and save it if it's a new snapshot. Returns the manifest row."""
    fetched_at = datetime.now(timezone.utc)
    row = {"run_id": run_id, "fetched_at_utc": fetched_at.isoformat(), "feed": feed,
           "last_updated": "", "last_updated_utc": "", "ttl": "", "record_count": "",
           "status": "", "file_path": "", "error": ""}
    try:
        payload, raw = fetch(session, url)
        last_updated = payload.get("last_updated")
        if last_updated is None:
            raise ValueError("response has no last_updated field")
        last_updated_dt = datetime.fromtimestamp(int(last_updated), tz=timezone.utc)
        path = DATA_DIR / feed / last_updated_dt.strftime("%Y-%m-%d") / f"{last_updated}.json.gz"

        row.update(last_updated=last_updated, last_updated_utc=last_updated_dt.isoformat(),
                   ttl=payload.get("ttl", ""), record_count=count_records(payload),
                   file_path=str(path))

        if path.exists():
            row["status"] = "duplicate"  # same snapshot already stored: skip (idempotent)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            with gzip.open(path, "wb") as f:
                f.write(raw)  # raw bytes, untouched: bronze keeps the truth
            row["status"] = "saved"
    except Exception as exc:  # one bad feed must not stop the others
        row.update(status="error", error=str(exc)[:300])
        log.error("Feed %s failed: %s", feed, exc)

    append_manifest(row)
    log.info("%-20s %-9s records=%-5s last_updated=%s", feed, row["status"],
             row["record_count"], row["last_updated_utc"])
    return row


def run(interval: int, once: bool) -> None:
    run_id = uuid.uuid4().hex[:8]
    session = requests.Session()
    session.headers["User-Agent"] = "rts-take-home-collector/1.0"
    log.info("Collector started. run_id=%s interval=%ss", run_id, interval)

    feed_urls: dict[str, str] = {}
    last_reference_refresh = 0.0

    while True:
        cycle_start = time.time()

        if not feed_urls or cycle_start - last_reference_refresh >= REFERENCE_REFRESH_SECONDS:
            try:
                feed_urls = discover_feeds(session)
                for feed in REFERENCE_FEEDS:
                    if feed in feed_urls:
                        collect_feed(session, feed, feed_urls[feed], run_id)
                    else:
                        log.warning("Optional feed %s not published; skipping", feed)
                last_reference_refresh = cycle_start
            except Exception as exc:
                log.error("Discovery failed: %s (will retry next cycle)", exc)

        ttl = 60
        for feed in REALTIME_FEEDS:
            if feed not in feed_urls:
                log.warning("Live feed %s not in discovery; skipping", feed)
                continue
            row = collect_feed(session, feed, feed_urls[feed], run_id)
            if row["ttl"] not in ("", None):
                ttl = int(row["ttl"])

        if once:
            break
        # Never poll faster than the feed's TTL.
        sleep_for = max(interval, ttl) - (time.time() - cycle_start)
        time.sleep(max(sleep_for, 1))


def main() -> None:
    parser = argparse.ArgumentParser(description="Collect Capital Bikeshare GBFS snapshots.")
    parser.add_argument("--interval", type=int, default=DEFAULT_INTERVAL_SECONDS,
                        help="Seconds between polls (never less than the feed TTL).")
    parser.add_argument("--once", action="store_true", help="Run a single cycle and exit.")
    args = parser.parse_args()
    setup_logging()
    try:
        run(args.interval, args.once)
    except KeyboardInterrupt:
        log.info("Stopped by user.")


if __name__ == "__main__":
    main()
