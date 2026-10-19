"""
Enrichment source: hourly weather for Washington, DC from Open-Meteo.

Open-Meteo is free and needs no API key. We request the past 7 days plus
today, hourly, with Unix timestamps (same format as the bike feeds), and save
the response untouched to the bronze layer:

  data/raw/weather/<YYYY-MM-DD>/<fetched_epoch>.json.gz

Run it any time; each run saves a new raw file and the warehouse build keeps
the most recent value for each hour, so re-running is safe.

  python src/fetch_weather.py
"""
import gzip
import logging
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

from collect import fetch  # reuse the collector's timeout + retry logic

WEATHER_URL = "https://api.open-meteo.com/v1/forecast"
DC_LAT, DC_LON = 38.9072, -77.0369          # downtown Washington, DC
HOURLY_FIELDS = ["temperature_2m", "precipitation", "wind_speed_10m", "weather_code"]
PAST_DAYS = 7
OUT_DIR = Path("data/raw/weather")

log = logging.getLogger("weather")


def build_url() -> str:
    params = {
        "latitude": DC_LAT,
        "longitude": DC_LON,
        "hourly": ",".join(HOURLY_FIELDS),
        "past_days": PAST_DAYS,
        "forecast_days": 1,
        "timeformat": "unixtime",   # match the GBFS feeds: seconds since 1970, UTC
        "timezone": "GMT",
    }
    return WEATHER_URL + "?" + "&".join(f"{k}={v}" for k, v in params.items())


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    session = requests.Session()
    payload, raw = fetch(session, build_url())

    hours = len(payload.get("hourly", {}).get("time", []))
    if hours == 0:
        raise SystemExit("Weather response has no hourly data; nothing saved.")

    now = datetime.now(timezone.utc)
    path = OUT_DIR / now.strftime("%Y-%m-%d") / f"{int(time.time())}.json.gz"
    path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wb") as f:
        f.write(raw)  # bronze: keep the response exactly as received
    log.info("Saved %s hours of weather to %s", hours, path)


if __name__ == "__main__":
    main()
