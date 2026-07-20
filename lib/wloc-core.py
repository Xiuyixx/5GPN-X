#!/usr/bin/env python3
"""
Shared WLOC (Apple Wi-Fi/cell network location) helpers for 5GPN-X.

This module is intentionally dependency-free (stdlib only) so it can be imported
by the mitmproxy addon (lib/wloc-mitm.py), the Telegram bot, and the test suite
without pulling mitmproxy into every context.

Responsibilities:
  * Parse/validate the operator-facing WLOC config (target coordinates).
  * Atomically persist that config with 0600 permissions.
  * Rewrite the protobuf body of an Apple ``/clls/wloc`` response so every
    returned Wi-Fi access point reports the operator's target coordinate.

Design rules (see project requirements):
  * Rewrites apply ONLY to the two Apple location hosts. Host gating happens in
    the mitmproxy addon; this module still refuses to touch anything that does
    not look like a valid WLOC protobuf payload.
  * Every rewrite path is fail-open: on ANY parse/encoding anomaly we return the
    original bytes unchanged so the client still gets Apple's real answer.
  * Latitude is clamped to [-90, 90] and longitude to [-180, 180]; Apple encodes
    both as int64 microdegrees-scaled-by-1e8 (i.e. degrees * 1e8).

Apple WLOC response protobuf shape (reverse-engineered, stable for years):

    message Response {
      repeated WifiEntry wifi = 2;   // one per returned AP
    }
    message WifiEntry {
      optional string mac      = 1;
      optional Location loc    = 2;
    }
    message Location {
      optional sint64 lat_1e8  = 1;  // degrees * 1e8, varint (NOT zigzag)
      optional sint64 lon_1e8  = 2;  // degrees * 1e8, varint (NOT zigzag)
      optional int64  hacc     = 3;  // horizontal accuracy (meters), optional
      // ... other fields (altitude, zacc, ...) preserved verbatim
    }

Apple sends lat/lon as plain (two's-complement) varints, so a southern/western
coordinate is a very large unsigned varint. We preserve that encoding exactly.
"""
import json
import os
import struct
import tempfile

SCALE = 100_000_000  # 1e8: Apple stores degrees * 1e8 as an integer.

# The two Apple hosts we are allowed to touch. The mitmproxy addon enforces
# this; the constant lives here so tests and the addon agree on one source.
WLOC_HOSTS = ("gs-loc.apple.com", "gs-loc-cn.apple.com")
WLOC_PATH = "/clls/wloc"

# Field numbers per the schema above.
_F_RESP_WIFI = 2
_F_ENTRY_LOC = 2
_F_LOC_LAT = 1
_F_LOC_LON = 2

# Wire types.
_WT_VARINT = 0
_WT_I64 = 1
_WT_LEN = 2
_WT_I32 = 5


# --------------------------------------------------------------------------- #
# Coordinate validation / config persistence
# --------------------------------------------------------------------------- #
def valid_lat(value):
    try:
        v = float(value)
    except (TypeError, ValueError):
        return False
    return -90.0 <= v <= 90.0 and v == v  # reject NaN


def valid_lon(value):
    try:
        v = float(value)
    except (TypeError, ValueError):
        return False
    return -180.0 <= v <= 180.0 and v == v


def parse_latlon(text):
    """Parse a user-entered "lat,lon" string.

    Returns (lat, lon) floats on success or None on any invalid input. Accepts
    comma or whitespace separators and an optional accuracy is NOT consumed here
    (kept minimal for v1).
    """
    if not isinstance(text, str):
        return None
    parts = [p for p in text.replace(",", " ").split() if p]
    if len(parts) != 2:
        return None
    lat_s, lon_s = parts
    if not valid_lat(lat_s) or not valid_lon(lon_s):
        return None
    return (float(lat_s), float(lon_s))


def deg_to_scaled(deg):
    """Convert degrees (float) to Apple's int64 (degrees * 1e8), rounded."""
    return int(round(float(deg) * SCALE))


def scaled_to_deg(scaled):
    return float(scaled) / SCALE


def default_config():
    return {"enabled": False, "latitude": None, "longitude": None, "accuracy": 25}


def load_config(path):
    """Load WLOC config; return default_config() on any error (fail-safe)."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return default_config()
    if not isinstance(data, dict):
        return default_config()
    cfg = default_config()
    cfg["enabled"] = bool(data.get("enabled", False))
    lat, lon = data.get("latitude"), data.get("longitude")
    if valid_lat(lat) and valid_lon(lon):
        cfg["latitude"] = float(lat)
        cfg["longitude"] = float(lon)
    else:
        # Invalid stored coordinates cannot be "enabled".
        cfg["enabled"] = False
    try:
        acc = int(data.get("accuracy", 25))
        cfg["accuracy"] = acc if 1 <= acc <= 10000 else 25
    except (TypeError, ValueError):
        cfg["accuracy"] = 25
    return cfg


def save_config(path, cfg):
    """Atomically write cfg as JSON with 0600 perms.

    Raises ValueError if cfg is enabled but coordinates are invalid, so a bad
    input never clobbers a good stored config (the caller validates first, this
    is the last line of defence).
    """
    out = default_config()
    out["enabled"] = bool(cfg.get("enabled", False))
    lat, lon = cfg.get("latitude"), cfg.get("longitude")
    if out["enabled"]:
        if not (valid_lat(lat) and valid_lon(lon)):
            raise ValueError("enabled config requires valid latitude/longitude")
    if valid_lat(lat) and valid_lon(lon):
        out["latitude"] = float(lat)
        out["longitude"] = float(lon)
    try:
        acc = int(cfg.get("accuracy", 25))
        out["accuracy"] = acc if 1 <= acc <= 10000 else 25
    except (TypeError, ValueError):
        out["accuracy"] = 25

    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".wloc.", suffix=".tmp")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return out


# --------------------------------------------------------------------------- #
# Minimal protobuf wire codec (varint / length-delimited only)
# --------------------------------------------------------------------------- #
def _read_varint(buf, pos):
    """Return (value, new_pos). Raises ValueError on truncation/overlong."""
    result = 0
    shift = 0
    while True:
        if pos >= len(buf):
            raise ValueError("truncated varint")
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint too long")


def _encode_varint(value):
    if value < 0:
        # Two's-complement 64-bit, matching protobuf int64 semantics.
        value &= (1 << 64) - 1
    out = bytearray()
    while True:
        b = value & 0x7F
        value >>= 7
        if value:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _encode_tag(field, wire):
    return _encode_varint((field << 3) | wire)


def _skip_field(buf, pos, wire):
    """Advance pos past one field's value. Raises ValueError on bad data."""
    if wire == _WT_VARINT:
        _, pos = _read_varint(buf, pos)
        return pos
    if wire == _WT_I64:
        if pos + 8 > len(buf):
            raise ValueError("truncated i64")
        return pos + 8
    if wire == _WT_LEN:
        length, pos = _read_varint(buf, pos)
        if pos + length > len(buf):
            raise ValueError("truncated length-delimited")
        return pos + length
    if wire == _WT_I32:
        if pos + 4 > len(buf):
            raise ValueError("truncated i32")
        return pos + 4
    raise ValueError("unsupported wire type %d" % wire)


def _rewrite_location(loc_bytes, lat_scaled, lon_scaled):
    """Return a new Location submessage with lat(field1)/lon(field2) replaced.

    All other fields (accuracy, altitude, ...) are copied verbatim. If field 1
    or 2 is absent we append it. Raises ValueError on malformed input.
    """
    out = bytearray()
    pos = 0
    saw_lat = saw_lon = False
    while pos < len(loc_bytes):
        key, pos = _read_varint(loc_bytes, pos)
        field = key >> 3
        wire = key & 0x07
        start = pos
        pos = _skip_field(loc_bytes, pos, wire)
        if field == _F_LOC_LAT and wire == _WT_VARINT:
            out += _encode_tag(_F_LOC_LAT, _WT_VARINT) + _encode_varint(lat_scaled)
            saw_lat = True
        elif field == _F_LOC_LON and wire == _WT_VARINT:
            out += _encode_tag(_F_LOC_LON, _WT_VARINT) + _encode_varint(lon_scaled)
            saw_lon = True
        else:
            out += _emit(loc_bytes, key, start, pos)
    if not saw_lat:
        out += _encode_tag(_F_LOC_LAT, _WT_VARINT) + _encode_varint(lat_scaled)
    if not saw_lon:
        out += _encode_tag(_F_LOC_LON, _WT_VARINT) + _encode_varint(lon_scaled)
    return bytes(out)


def _tag_len(key):
    return len(_encode_varint(key))


def _emit(buf, key, value_start, value_end):
    """Re-emit a field (tag + raw value bytes) unchanged."""
    return _encode_varint(key) + bytes(buf[value_start:value_end])


def _rewrite_entry(entry_bytes, lat_scaled, lon_scaled):
    """Rewrite the Location submessage (field 2) inside one WifiEntry."""
    out = bytearray()
    pos = 0
    saw_loc = False
    while pos < len(entry_bytes):
        key, pos = _read_varint(entry_bytes, pos)
        field = key >> 3
        wire = key & 0x07
        if field == _F_ENTRY_LOC and wire == _WT_LEN:
            length, pos = _read_varint(entry_bytes, pos)
            if pos + length > len(entry_bytes):
                raise ValueError("truncated location submessage")
            loc = entry_bytes[pos:pos + length]
            pos += length
            new_loc = _rewrite_location(loc, lat_scaled, lon_scaled)
            out += _encode_tag(_F_ENTRY_LOC, _WT_LEN) + _encode_varint(len(new_loc)) + new_loc
            saw_loc = True
        else:
            start = pos
            pos = _skip_field(entry_bytes, pos, wire)
            out += _emit(entry_bytes, key, start, pos)
    return bytes(out), saw_loc


def rewrite_wloc_response(body, lat, lon):
    """Rewrite every Wi-Fi entry's coordinate in an Apple WLOC protobuf body.

    Args:
        body: raw response bytes (may be prefixed by Apple's 10-byte header).
        lat, lon: target coordinate in degrees.

    Returns rewritten bytes, or the ORIGINAL body unchanged on any anomaly
    (fail-open) or when no Wi-Fi location entries were found.
    """
    if not isinstance(body, (bytes, bytearray)):
        return body
    if not (valid_lat(lat) and valid_lon(lon)):
        return bytes(body)
    body = bytes(body)

    # Apple prefixes the protobuf with a small binary header (commonly 10 bytes:
    # 0x00 0x01 then a big-endian length or similar). We locate the protobuf by
    # trying candidate offsets and keeping the first that parses cleanly AND
    # contains at least one rewritable Wi-Fi entry.
    lat_scaled = deg_to_scaled(lat)
    lon_scaled = deg_to_scaled(lon)
    for header_len in (0, 2, 10):
        if header_len > len(body):
            continue
        header, payload = body[:header_len], body[header_len:]
        try:
            new_payload, changed = _rewrite_response_payload(payload, lat_scaled, lon_scaled)
        except ValueError:
            continue
        if changed:
            return header + new_payload
    return body


def _rewrite_response_payload(payload, lat_scaled, lon_scaled):
    """Rewrite the top-level Response message. Returns (bytes, changed)."""
    out = bytearray()
    pos = 0
    changed = False
    while pos < len(payload):
        key, pos = _read_varint(payload, pos)
        field = key >> 3
        wire = key & 0x07
        if field == _F_RESP_WIFI and wire == _WT_LEN:
            length, pos = _read_varint(payload, pos)
            if pos + length > len(payload):
                raise ValueError("truncated wifi entry")
            entry = payload[pos:pos + length]
            pos += length
            new_entry, saw_loc = _rewrite_entry(entry, lat_scaled, lon_scaled)
            out += _encode_tag(_F_RESP_WIFI, _WT_LEN) + _encode_varint(len(new_entry)) + new_entry
            changed = changed or saw_loc
        else:
            start = pos
            pos = _skip_field(payload, pos, wire)
            out += _emit(payload, key, start, pos)
    return bytes(out), changed


# --------------------------------------------------------------------------- #
# Test/helper encoders (used by the unit tests to build synthetic responses)
# --------------------------------------------------------------------------- #
def _t_location(lat_scaled, lon_scaled, hacc=None):
    out = bytearray()
    out += _encode_tag(_F_LOC_LAT, _WT_VARINT) + _encode_varint(lat_scaled)
    out += _encode_tag(_F_LOC_LON, _WT_VARINT) + _encode_varint(lon_scaled)
    if hacc is not None:
        out += _encode_tag(3, _WT_VARINT) + _encode_varint(hacc)
    return bytes(out)


def _t_entry(mac, lat_scaled, lon_scaled, hacc=None):
    out = bytearray()
    mac_b = mac.encode("utf-8")
    out += _encode_tag(1, _WT_LEN) + _encode_varint(len(mac_b)) + mac_b
    loc = _t_location(lat_scaled, lon_scaled, hacc)
    out += _encode_tag(_F_ENTRY_LOC, _WT_LEN) + _encode_varint(len(loc)) + loc
    return bytes(out)


def build_test_response(entries, header=b""):
    """entries: list of (mac, lat_deg, lon_deg[, hacc]); returns full body."""
    payload = bytearray()
    for e in entries:
        mac, lat, lon = e[0], e[1], e[2]
        hacc = e[3] if len(e) > 3 else None
        entry = _t_entry(mac, deg_to_scaled(lat), deg_to_scaled(lon), hacc)
        payload += _encode_tag(_F_RESP_WIFI, _WT_LEN) + _encode_varint(len(entry)) + entry
    return header + bytes(payload)


def read_first_coord(body, header_len=0):
    """Test helper: return (lat_deg, lon_deg) of the first Wi-Fi entry."""
    payload = body[header_len:]
    pos = 0
    while pos < len(payload):
        key, pos = _read_varint(payload, pos)
        field, wire = key >> 3, key & 0x07
        if field == _F_RESP_WIFI and wire == _WT_LEN:
            length, pos = _read_varint(payload, pos)
            entry = payload[pos:pos + length]
            pos += length
            lat, lon = _read_entry_coord(entry)
            if lat is not None:
                return (scaled_to_deg(lat), scaled_to_deg(lon))
        else:
            pos = _skip_field(payload, pos, wire)
    return (None, None)


def _read_entry_coord(entry):
    pos = 0
    while pos < len(entry):
        key, pos = _read_varint(entry, pos)
        field, wire = key >> 3, key & 0x07
        if field == _F_ENTRY_LOC and wire == _WT_LEN:
            length, pos = _read_varint(entry, pos)
            loc = entry[pos:pos + length]
            pos += length
            return _read_loc_coord(loc)
        pos = _skip_field(entry, pos, wire)
    return (None, None)


def _read_loc_coord(loc):
    pos = 0
    lat = lon = None
    while pos < len(loc):
        key, pos = _read_varint(loc, pos)
        field, wire = key >> 3, key & 0x07
        if field == _F_LOC_LAT and wire == _WT_VARINT:
            lat, pos = _read_varint(loc, pos)
            lat = _as_signed64(lat)
        elif field == _F_LOC_LON and wire == _WT_VARINT:
            lon, pos = _read_varint(loc, pos)
            lon = _as_signed64(lon)
        else:
            pos = _skip_field(loc, pos, wire)
    return (lat, lon)


def _as_signed64(value):
    value &= (1 << 64) - 1
    if value >= (1 << 63):
        value -= (1 << 64)
    return value


# struct import kept for potential header parsing; referenced to satisfy linters.
_ = struct
