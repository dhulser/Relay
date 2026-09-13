#!/usr/bin/env python3
"""Compare translation runs from a Relay log.

Each Start..Stop span is one run. For every run this reports which engine was
used, how quickly the first line landed, how often lines arrived, and the lines
themselves with their offset from the start of the run — so two runs over the
same video can be read side by side.

    ./scripts/compare-runs.py /tmp/relay.log
"""
import re
import sys
from datetime import datetime

TS = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)")
CAT = re.compile(r"\[co\.kevel\.Relay:(\w+)\]\s*(.*)$")


def parse(path):
    events = []
    for line in open(path, errors="ignore"):
        ts, cat = TS.match(line), CAT.search(line)
        if not (ts and cat):
            continue
        when = datetime.strptime(ts.group(1), "%Y-%m-%d %H:%M:%S.%f")
        events.append((when, cat.group(1), cat.group(2).strip()))
    return events


def runs(events):
    """Split into Start..Stop spans, noting the engine each one used."""
    out, current = [], None
    for when, cat, msg in events:
        if cat == "App" and msg.startswith("Start requested"):
            engine = msg.split("—", 1)[1].split(",")[0].strip() if "—" in msg else "?"
            current = {"start": when, "engine": engine, "lines": [], "stop": None}
            out.append(current)
        elif cat == "App" and msg.startswith("Stop requested") and current:
            current["stop"] = when
            current = None
        elif current is not None and cat == "Subtitles" and msg.startswith("line: "):
            current["lines"].append((when, msg[6:]))
    return [r for r in out if r["lines"]]


def summarise(run, index):
    start, lines = run["start"], run["lines"]
    offsets = [(w - start).total_seconds() for w, _ in lines]
    end = run["stop"] or lines[-1][0]
    duration = (end - start).total_seconds()

    gaps = [b - a for a, b in zip(offsets, offsets[1:])]
    words = sum(len(t.split()) for _, t in lines)

    print(f"\n{'='*72}\nRUN {index}: {run['engine']}")
    print(f"{'='*72}")
    print(f"  duration            {duration:6.1f}s")
    print(f"  lines               {len(lines):6d}   ({len(lines)/max(duration,1)*60:.1f}/min)")
    print(f"  words               {words:6d}   ({words/max(len(lines),1):.1f} per line)")
    print(f"  first line at       {offsets[0]:6.1f}s")
    if gaps:
        gaps_sorted = sorted(gaps)
        print(f"  gap between lines   {sum(gaps)/len(gaps):6.1f}s avg, "
              f"{gaps_sorted[len(gaps)//2]:.1f}s median, {max(gaps):.1f}s worst")
    print("\n  transcript (offset from start):")
    for off, (_, text) in zip(offsets, lines):
        print(f"    {off:6.1f}s  {text}")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/relay.log"
    found = runs(parse(path))
    if not found:
        print(f"No completed runs with subtitles found in {path}.")
        print("A run is a Start..Stop span that produced at least one line.")
        return

    for i, run in enumerate(found, 1):
        summarise(run, i)

    if len(found) >= 2:
        print(f"\n{'='*72}\nSIDE BY SIDE\n{'='*72}")
        for run in found:
            start = run["start"]
            offsets = [(w - start).total_seconds() for w, _ in run["lines"]]
            per_min = len(run["lines"]) / max((offsets[-1] or 1), 1) * 60
            print(f"  {run['engine']:<22} first line {offsets[0]:5.1f}s   "
                  f"{len(run['lines']):3d} lines   {per_min:5.1f} lines/min")


if __name__ == "__main__":
    main()
