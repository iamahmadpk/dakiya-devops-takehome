"""Send sample scan events to the API and print one parcel's status.

Usage: python scripts/send_scans.py [API_URL] [COUNT]
"""
import json
import random
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

API = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000"
COUNT = int(sys.argv[2]) if len(sys.argv) > 2 else 20
STATUSES = ["booked", "in_transit", "out_for_delivery", "delivered"]
DEPOTS = ["ISB-01", "RWP-02", "LHE-01", "KHI-03"]


def post(path, body):
    req = urllib.request.Request(
        API + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return resp.status


start = datetime.now(timezone.utc) - timedelta(hours=6)
ids = [f"DKY-{1000 + i}" for i in range(max(1, COUNT // 4))]
sent = 0
for tracking_id in ids:
    for step, status in enumerate(STATUSES):
        post("/scans", {
            "tracking_id": tracking_id,
            "status": status,
            "depot": random.choice(DEPOTS),
            "scanned_at": (start + timedelta(hours=step)).isoformat(),
        })
        sent += 1
print(f"sent {sent} scans")

time.sleep(2)
try:
    with urllib.request.urlopen(f"{API}/parcels/{ids[0]}", timeout=5) as resp:
        print(json.dumps(json.load(resp), indent=2))
except urllib.error.HTTPError as err:
    print(f"GET /parcels/{ids[0]} -> HTTP {err.code}")
