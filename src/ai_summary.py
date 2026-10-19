"""
AI layer: turns the gold answer tables into a short, plain-English tip for
travellers at each hub.

Where it sits:  at the very end of the pipeline (serving), after gold.
What it reads:  the small answer views (answer_hub_reliability and
                answer_by_hour_of_day), never the raw data.
What it writes: docs/ai_summary.md

If ANTHROPIC_API_KEY is set, an LLM (Claude) writes the summary from the
numbers. If not, or if the API call fails, a simple template writes it
instead, so this step always works.

The AI only explains numbers the pipeline already calculated and checked.
It never does the maths itself, so it can't invent figures.

Run from the project folder (after build_warehouse.py):
  python src/ai_summary.py
"""
import json
import os
from pathlib import Path

import duckdb
import requests

WAREHOUSE_PATH = "data/warehouse.duckdb"
OUTPUT_PATH = Path("docs/ai_summary.md")
API_URL = "https://api.anthropic.com/v1/messages"
MODEL = "claude-haiku-5-5"


def hour_label(hour):
    """15 -> '3 PM', 0 -> '12 AM'."""
    if hour == 0:
        return "12 AM"
    if hour < 12:
        return f"{hour} AM"
    if hour == 12:
        return "12 PM"
    return f"{hour - 12} PM"


def load_facts(con):
    """Get a few numbers per hub from the gold answer views."""
    facts = []
    hubs = con.execute("""
        SELECT hub_name, min_bikes, pct_time_with_ebike, min_open_docks
        FROM answer_hub_reliability
    """).fetchall()

    for hub_name, min_bikes, pct_with_ebike, min_open_docks in hubs:
        # The hour of day when this hub has the fewest open docks, on average.
        tightest_hour = con.execute("""
            SELECT hour_of_day
            FROM answer_by_hour_of_day
            WHERE hub_name = ?
            ORDER BY avg_open_docks
            LIMIT 1
        """, [hub_name]).fetchone()[0]

        facts.append({
            "hub": hub_name,
            "min_bikes": int(min_bikes),
            "pct_time_with_ebike": float(pct_with_ebike),
            "min_open_docks": int(min_open_docks),
            "tightest_dock_hour": hour_label(tightest_hour),
        })
    return facts


def template_summary(facts):
    """Simple rules, no AI. Used when there's no API key or the call fails."""
    lines = []
    for f in facts:
        problems = []
        if f["pct_time_with_ebike"] < 100:
            problems.append(f"E-bikes sometimes ran out (available {f['pct_time_with_ebike']}% of the time).")
        if f["min_open_docks"] < 10:
            problems.append(f"Returning a bike is the tight spot: open docks dropped to {f['min_open_docks']},"
                            f" and on average fewest around {f['tightest_dock_hour']}.")

        if problems:
            line = f"- **{f['hub']}**: always had bikes nearby (never fewer than {f['min_bikes']}). " + " ".join(problems)
        else:
            line = f"- **{f['hub']}**: plenty of bikes and docks the whole time (never fewer than {f['min_bikes']} bikes)."
        lines.append(line)
    return "\n".join(lines)


def ai_summary(facts, api_key):
    """Ask the LLM to turn the numbers into short traveller tips."""
    prompt = (
        "You are helping XYZ Travel tell its customers whether they can rely on "
        "Capital Bikeshare bikes near DC travel hubs.\n"
        "Below are measured facts per hub (within 400 m, about a 5 minute walk).\n"
        "Write one bullet per hub, 1-2 short sentences, plain English, for a traveller.\n"
        "Use ONLY these numbers. Do not invent or estimate any other numbers.\n"
        "Start each bullet with the hub name in bold. No intro or outro text.\n\n"
        + json.dumps(facts, indent=2)
    )
    response = requests.post(
        API_URL,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        json={"model": MODEL, "max_tokens": 800, "messages": [{"role": "user", "content": prompt}]},
        timeout=60,
    )
    response.raise_for_status()
    return response.json()["content"][0]["text"].strip()


def main():
    con = duckdb.connect(WAREHOUSE_PATH, read_only=True)
    facts = load_facts(con)

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    text = None
    written_by = "Template version (no AI key set)"

    if api_key:
        try:
            text = ai_summary(facts, api_key)
            written_by = f"Written by Claude ({MODEL})"
        except Exception as error:
            print(f"AI call failed ({error}). Using the template instead.")
            written_by = "Template version (the AI call failed)"

    if text is None:
        text = template_summary(facts)

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(
        "# Traveller bike tips (AI layer output)\n\n"
        f"*{written_by}. All numbers come from the gold tables.*\n\n"
        f"{text}\n"
    )
    print(OUTPUT_PATH.read_text())


if __name__ == "__main__":
    main()
