#!/usr/bin/env python3
"""usage: update_status.py <task_id> <pending|in_progress|done|failed> [note]"""
import json, sys, datetime

PATH = "status.json"
tid, st = sys.argv[1], sys.argv[2]
note = sys.argv[3] if len(sys.argv) > 3 else None
assert st in ("pending", "in_progress", "done", "failed"), f"invalid status: {st}"

d = json.load(open(PATH))
hit = False
for t in d["phases"]["phase0"]["tasks"]:
    if str(t["id"]) == tid:
        t["status"] = st
        if note: t["note"] = note
        hit = True
assert hit, f"task {tid} not found"
d["updated"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
running = [t["id"] for t in d["phases"]["phase0"]["tasks"] if t["status"] == "in_progress"]
d["current"]["task"] = running[0] if running else None
done = all(t["status"] == "done" for t in d["phases"]["phase0"]["tasks"])
d["phases"]["phase0"]["status"] = "done" if done else "in_progress"
json.dump(d, open(PATH, "w"), ensure_ascii=False, indent=2)
print(f"task {tid} -> {st}")
