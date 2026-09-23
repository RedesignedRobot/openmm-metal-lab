"""Read or change a local fah-client's state over its websocket API.

  ws_probe.py state         print the info.gpus dict the client sends a web UI
  ws_probe.py enable ID     enable GPU ID in the default group, cpus 0, fold

Talks only to ws://127.0.0.1:7396, the client's loopback API.
"""
import json
import sys
from datetime import datetime, timezone

from websockets.sync.client import connect

URL = "ws://127.0.0.1:7396/api/websocket"


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    with connect(URL) as ws:
        state = json.loads(ws.recv())  # The client sends its full state first

        if sys.argv[1] == "state":
            gpus = state["info"]["gpus"]
            print(json.dumps(gpus, indent=2, sort_keys=True))
            for id, gpu in gpus.items():
                # Mirrors fah-web-client-bastet GPUFieldset.vue
                print(id, "device.toString(16) =", format(gpu["device"], "x"))
            return

        gpu = sys.argv[2]
        config = {"groups": {"": {"cpus": 0, "gpus": {gpu: {"enabled": True}}}}}
        ws.send(json.dumps({"cmd": "config", "time": now(), "config": config}))
        ws.send(json.dumps({"cmd": "state", "time": now(), "state": "fold"}))
        print("sent config and fold for", gpu)


if __name__ == "__main__":
    main()
