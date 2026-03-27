import asyncio
import os
import sys

import nats
from google.protobuf.json_format import MessageToJson
from telemetry_pb2 import TelemetryMessage

NATS_URL = os.environ.get("NATS_URL", "nats://nats:4222")
SUBJECT = os.environ.get("SUBJECT", "telemetry.>")
RETRY_INTERVAL = 2


async def main():
    nc = None
    while not nc:
        try:
            print(f"Connecting to {NATS_URL}...")
            nc = await nats.connect(NATS_URL)
        except Exception as e:
            print(f"Connection failed: {e}. Retrying in {RETRY_INTERVAL}s...")
            await asyncio.sleep(RETRY_INTERVAL)

    print(f"Subscribed to '{SUBJECT}'. Waiting for messages...\n")

    sub = await nc.subscribe(SUBJECT)
    async for msg in sub.messages:
        tm = TelemetryMessage()
        tm.ParseFromString(msg.data)
        print(f"Subject: {msg.subject}")
        print(MessageToJson(tm, indent=2))
        print()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
