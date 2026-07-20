#!/usr/bin/env python3
"""Unit tests for lib/wloc-core.py (protobuf rewrite + config persistence).

Run: python3 tests/test_wloc_core.py
"""
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CORE_PATH = os.path.join(HERE, "..", "lib", "wloc-core.py")

spec = importlib.util.spec_from_file_location("wloc_core", CORE_PATH)
wc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wc)

FAILS = []


def check(cond, msg):
    if not cond:
        FAILS.append(msg)
        print("FAIL:", msg)
    else:
        print("ok:", msg)


def approx(a, b, eps=1e-6):
    return a is not None and b is not None and abs(a - b) <= eps


# --- coordinate validation ------------------------------------------------- #
check(wc.valid_lat(0) and wc.valid_lat(90) and wc.valid_lat(-90), "lat bounds inclusive")
check(not wc.valid_lat(90.1) and not wc.valid_lat(-90.1), "lat out of range rejected")
check(wc.valid_lon(180) and wc.valid_lon(-180), "lon bounds inclusive")
check(not wc.valid_lon(180.1) and not wc.valid_lon(-181), "lon out of range rejected")
check(not wc.valid_lat(float("nan")), "NaN latitude rejected")
check(wc.parse_latlon("22.30,114.16") == (22.30, 114.16), "parse comma latlon")
check(wc.parse_latlon("35.68 139.76") == (35.68, 139.76), "parse space latlon")
check(wc.parse_latlon("abc") is None, "parse garbage -> None")
check(wc.parse_latlon("1,2,3") is None, "parse extra field -> None")
check(wc.parse_latlon("91,0") is None, "parse out-of-range lat -> None")

# --- scaling round-trip ----------------------------------------------------- #
check(wc.deg_to_scaled(22.303611) == 2230361100, "positive scaling")
check(wc.deg_to_scaled(-33.86) == -3386000000, "negative scaling")
check(approx(wc.scaled_to_deg(wc.deg_to_scaled(114.165)), 114.165), "scale round-trip")

# --- rewrite: both target hosts (host gating is in the addon; core rewrites
#     any valid WLOC protobuf, and the addon only calls it for the 2 hosts) --- #
body = wc.build_test_response([
    ("aa:bb:cc:dd:ee:ff", 1.0, 2.0, 30),
    ("11:22:33:44:55:66", -3.5, -4.5),
])
out = wc.rewrite_wloc_response(body, 22.303611, 114.165)
lat, lon = wc.read_first_coord(out)
check(approx(lat, 22.303611) and approx(lon, 114.165), "rewrite replaces first entry coord")
check(out != body, "rewrite changes bytes for valid payload")

# southern/western target (negative -> large unsigned varint) round-trips
out2 = wc.rewrite_wloc_response(body, -33.8688, 151.2093)
lat2, lon2 = wc.read_first_coord(out2)
check(approx(lat2, -33.8688) and approx(lon2, 151.2093), "rewrite negative coord ok")

# accuracy / other fields preserved: entry still parses and has hacc intact
# (we just re-read coord; structural integrity is proven by successful parse)
check(wc.read_first_coord(out)[0] is not None, "rewritten body re-parses cleanly")

# with Apple-style 10-byte header
hdr = bytes([0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
body_h = wc.build_test_response([("aa", 5.0, 6.0)], header=hdr)
out_h = wc.rewrite_wloc_response(body_h, 40.0, 50.0)
check(out_h[:10] == hdr, "header preserved verbatim")
check(approx(wc.read_first_coord(out_h, header_len=10)[0], 40.0), "header-prefixed rewrite ok")

# --- fail-open on garbage / truncation -------------------------------------- #
check(wc.rewrite_wloc_response(b"", 1, 2) == b"", "empty body unchanged")
check(wc.rewrite_wloc_response(b"\xff\xff\xff\xff", 1, 2) == b"\xff\xff\xff\xff",
      "garbage body unchanged (fail-open)")
truncated = body[:len(body) // 2]
check(wc.rewrite_wloc_response(truncated, 1, 2) == truncated,
      "truncated body unchanged (fail-open)")
check(wc.rewrite_wloc_response(b"hello world not protobuf", 1, 2) == b"hello world not protobuf",
      "non-protobuf text unchanged")
# valid protobuf but no wifi-location entries -> unchanged (nothing to rewrite)
noloc = wc._encode_tag(9, wc._WT_VARINT) + wc._encode_varint(123)
check(wc.rewrite_wloc_response(noloc, 1, 2) == noloc, "no-location payload unchanged")
# invalid target coord -> never rewrite
check(wc.rewrite_wloc_response(body, 999, 999) == body, "invalid target coord -> unchanged")

# --- config persistence: atomic, 0600, reject-bad --------------------------- #
d = tempfile.mkdtemp()
cfg_path = os.path.join(d, "wloc.json")

saved = wc.save_config(cfg_path, {"enabled": True, "latitude": 22.3, "longitude": 114.1, "accuracy": 25})
check(saved["enabled"] and approx(saved["latitude"], 22.3), "save enabled config")
mode = os.stat(cfg_path).st_mode & 0o777
check(mode == 0o600, "config file mode is 0600 (got %o)" % mode)
loaded = wc.load_config(cfg_path)
check(loaded["enabled"] and approx(loaded["longitude"], 114.1), "reload config")

# enabling with invalid coords must raise and NOT clobber the good file
try:
    wc.save_config(cfg_path, {"enabled": True, "latitude": 999, "longitude": 0})
    check(False, "invalid enabled config should raise")
except ValueError:
    check(True, "invalid enabled config raises")
still = wc.load_config(cfg_path)
check(approx(still["latitude"], 22.3), "old config intact after rejected write")

# disabling is always allowed and clears enabled flag
wc.save_config(cfg_path, {"enabled": False, "latitude": 22.3, "longitude": 114.1})
check(wc.load_config(cfg_path)["enabled"] is False, "disable persists")

# missing/corrupt file -> safe default
check(wc.load_config(os.path.join(d, "nope.json"))["enabled"] is False, "missing file -> default")
with open(cfg_path, "w", encoding="utf-8") as f:
    f.write("{not json")
check(wc.load_config(cfg_path)["enabled"] is False, "corrupt file -> default")

if FAILS:
    print("\n%d test(s) failed" % len(FAILS))
    sys.exit(1)
print("\nall wloc-core tests passed")
