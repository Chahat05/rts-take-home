"""
Tests for the AI layer (src/ai_summary.py). No API key or network needed.
"""
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT / "src"))
import ai_summary  # noqa: E402

FACTS = [
    {"hub": "Union Station", "min_bikes": 70, "pct_time_with_ebike": 100.0,
     "min_open_docks": 6, "tightest_dock_hour": "3 PM"},
    {"hub": "L'Enfant Plaza", "min_bikes": 28, "pct_time_with_ebike": 95.1,
     "min_open_docks": 62, "tightest_dock_hour": "4 PM"},
]


def test_hour_label():
    assert ai_summary.hour_label(0) == "12 AM"
    assert ai_summary.hour_label(9) == "9 AM"
    assert ai_summary.hour_label(12) == "12 PM"
    assert ai_summary.hour_label(15) == "3 PM"


def test_template_mentions_the_tight_spots():
    text = ai_summary.template_summary(FACTS)
    assert "**Union Station**" in text and "dropped to 6" in text and "3 PM" in text
    assert "**L'Enfant Plaza**" in text and "95.1%" in text
    assert "dropped to 62" not in text        # plenty of docks -> no warning
