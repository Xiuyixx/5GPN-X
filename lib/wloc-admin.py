#!/usr/bin/env python3
"""Atomic WLOC state and sniproxy configuration helper."""

import datetime
import json
import math
import os
import sys


def state_enabled(path):
    try:
        with open(path, encoding="utf-8") as source:
            return bool(json.load(source).get("enabled"))
    except (OSError, ValueError, TypeError, AttributeError):
        return False


def write_state(path, owner, enabled, latitude="", longitude="", label=""):
    try:
        with open(path, encoding="utf-8") as source:
            state = json.load(source)
        if not isinstance(state, dict):
            state = {}
    except (OSError, ValueError, TypeError):
        state = {}
    if latitude or longitude:
        latitude, longitude = float(latitude), float(longitude)
        if not math.isfinite(latitude) or not -90 <= latitude <= 90:
            raise SystemExit("纬度需在 -90~90")
        if not math.isfinite(longitude) or not -180 <= longitude <= 180:
            raise SystemExit("经度需在 -180~180")
        label = " ".join(label.split())[:40]
        state.update({"latitude": latitude, "longitude": longitude,
                      "label": label or None})
    elif enabled and (state.get("latitude") is None or state.get("longitude") is None):
        raise SystemExit("尚未设置 WLOC 坐标")
    state["enabled"] = enabled
    state["generation"] = int(state.get("generation") or 0) + 1
    state["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as target:
        json.dump(state, target, ensure_ascii=False, separators=(",", ":"))
        target.flush()
        os.fsync(target.fileno())
    if owner:
        import pwd
        os.chown(temporary, 0, pwd.getpwnam(owner).pw_gid)
    os.chmod(temporary, 0o640)
    os.replace(temporary, path)


def update_sniproxy(path, enabled):
    with open(path, encoding="utf-8") as source:
        lines = source.read().splitlines()
    begin = "    # 5gpn-wloc routes begin (managed by 5gpn-ctl)"
    end = "    # 5gpn-wloc routes end"
    try:
        first, last = lines.index(begin), lines.index(end)
    except ValueError:
        table = next((i for i, line in enumerate(lines)
                      if line.strip() == "table tls_hosts {"), None)
        if table is None:
            raise SystemExit("tls_hosts table not found")
        last = next((i for i in range(table + 1, len(lines))
                     if lines[i].strip() == "}"), None)
        if last is None:
            raise SystemExit("tls_hosts table is incomplete")
        first = last
        lines[first:first] = [begin, end]
        last = first + 1
    routes = []
    if enabled:
        routes = [
            r"    ^gs-loc\.apple\.com$ 127.0.0.1:9080",
            r"    ^gs-loc-cn\.apple\.com$ 127.0.0.1:9081",
        ]
    lines[first + 1:last] = routes
    temporary = path + ".wloc.tmp"
    with open(temporary, "w", encoding="utf-8") as target:
        target.write("\n".join(lines) + "\n")
    os.chmod(temporary, os.stat(path).st_mode & 0o777)
    os.replace(temporary, path)


def main(argv):
    if len(argv) == 3 and argv[1] == "state-enabled":
        print("1" if state_enabled(argv[2]) else "0")
    elif len(argv) == 8 and argv[1] == "write-state":
        write_state(argv[2], argv[3], argv[4] == "1", argv[5], argv[6], argv[7])
    elif len(argv) == 4 and argv[1] == "update-sniproxy":
        update_sniproxy(argv[2], argv[3] == "1")
    else:
        raise SystemExit("invalid WLOC admin arguments")


if __name__ == "__main__":
    main(sys.argv)
