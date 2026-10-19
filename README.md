# RTS Labs Data Engineering Challenge – Chahat Ajmera

Two parts:

- **Part A: XYZ Travel data warehouse.** Data model, design decisions and SQL → [`docs/part_a_data_model.md`](docs/part_a_data_model.md)
- **Part B: Capital Bikeshare pipeline.** Architecture, data sources, and answers to Q5–Q7 → [`docs/part_b_pipeline.md`](docs/part_b_pipeline.md)

## Part B in one line

A pipeline that collects Capital Bikeshare's live feed every 2 minutes, adds travel hub locations and hourly weather, and answers: **when an XYZ traveller arrives at a DC travel hub, can they find a bike, an e-bike, and an empty dock nearby?**

## Project layout

```
src/
  collect.py            collects the live GBFS feeds every 2 min (bronze)
  fetch_weather.py      collects hourly DC weather from Open-Meteo (bronze)
  build_warehouse.py    runs the SQL: silver -> gold -> quality checks
  ai_summary.py         AI layer: plain-English tips per hub from the gold tables
sql/
  part_a/               Part A schema and queries
  part_b/               10_silver, 15_silver_weather, 20_gold, 30_quality_checks
reference/
  travel_hubs.csv       the 10 travel hubs (enrichment)
tests/                  small tests with hand-made data where I know the right answer
docs/                   written answers + ai_summary.md (example AI layer output)
```

The numbers in the SQL file names are the order they run in (10 → 15 → 20 → 30).

## How to run

Needs Python 3.12. Everything runs locally; DuckDB is the database (one file, no server).

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 1. Collect data (leave it running; caffeinate keeps a Mac awake)
caffeinate -i python src/collect.py
#    or one cycle only, to try it:  python src/collect.py --once

# 2. Get the weather
python src/fetch_weather.py

# 3. Build the warehouse (silver -> gold -> checks) and print the results
python src/build_warehouse.py

# 4. AI layer (optional key: export ANTHROPIC_API_KEY=... ; without it a template is used)
python src/ai_summary.py

# Tests
pytest -q
```

Raw data, logs and the warehouse file are not in the repo (see `.gitignore`). Running steps 1–3 recreates them.
