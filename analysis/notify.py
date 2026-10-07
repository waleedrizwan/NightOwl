#!/usr/bin/env python3
"""Push "last night is ready" to the Night Owl app through Apple's push service (APNs).

Needs an APNs auth key from developer.apple.com (Keys → + → Apple Push Notifications
service), saved as <data>/apns/AuthKey_<KEYID>.p8. Device tokens come from devices.json,
which the app writes into the iCloud folder. Without a key or a device it skips quietly.
"""
import base64
import json
import os
import time
from pathlib import Path

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from dashboard import hm, label, load
from publish import CLOUD

DATA = Path(os.environ.get("OWL_DATA", Path.home() / "NightOwl"))
TEAM_ID = os.environ.get("OWL_TEAM_ID", "CCY6PYVHZW")
BUNDLE_ID = "com.waleedrizwan.NightOwl"
HOSTS = {"development": "https://api.sandbox.push.apple.com",
         "production": "https://api.push.apple.com"}


def b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def provider_token(key_file: Path) -> str:
    key_id = key_file.stem.removeprefix("AuthKey_")
    key = serialization.load_pem_private_key(key_file.read_bytes(), password=None)
    head = b64(json.dumps({"alg": "ES256", "kid": key_id}).encode())
    claims = b64(json.dumps({"iss": TEAM_ID, "iat": int(time.time())}).encode())
    r, s = decode_dss_signature(key.sign(f"{head}.{claims}".encode(), ec.ECDSA(hashes.SHA256())))
    return f"{head}.{claims}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def main():
    keys = sorted((DATA / "apns").glob("AuthKey_*.p8"))
    devices_file = CLOUD / "devices.json"
    if not keys or not devices_file.exists():
        print("  notify: skipped (no APNs key in ~/NightOwl/apns or no phone registered yet)")
        return
    devices = json.loads(devices_file.read_text())
    s = load(DATA)[-1]
    gasps = len(s.get("gaspCandidates", []))
    payload = {
        "aps": {"alert": {
            "title": f"Snore Score {s['score']} · {s['band']}",
            "body": (f"{label(s)}: {hm(s['snoreMs']) if s['snoreMs'] else 'no'} snoring "
                     f"({s['percentOfNight']}% of {hm(s['recordedMs'])})"
                     + (f" · {gasps} possible gasp{'s' * (gasps > 1)}" if gasps else "")),
        }, "sound": "default"},
        "night": s["dir"],
    }
    jwt = provider_token(keys[-1])
    with httpx.Client(http2=True, timeout=15) as client:
        for token, env in devices.items():
            r = client.post(f"{HOSTS.get(env, HOSTS['development'])}/3/device/{token}", json=payload,
                            headers={"authorization": f"bearer {jwt}", "apns-topic": BUNDLE_ID,
                                     "apns-push-type": "alert", "apns-priority": "10"})
            print(f"  notify: {token[:8]}… {env} → {r.status_code} {r.text}".rstrip())


if __name__ == "__main__":
    main()
