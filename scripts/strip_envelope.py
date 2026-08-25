#!/usr/bin/env python3
"""usage: strip_envelope.py stream.bin out.aac — MARKER는 stderr에 출력"""
import sys, json
data = open(sys.argv[1], "rb").read()
out = open(sys.argv[2], "wb"); i = 0
while i + 3 <= len(data):
    t, ln = data[i], int.from_bytes(data[i+1:i+3], "big")
    payload = data[i+3:i+3+ln]; i += 3 + ln
    if t == 0x01: out.write(payload)
    elif t == 0x02: print("MARKER:", json.loads(payload), file=sys.stderr)
print(f"audio bytes: {out.tell()}", file=sys.stderr)
