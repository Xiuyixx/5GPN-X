#!/usr/bin/env python3
"""WLOC protobuf and Telegram management regression tests."""

import gzip
import importlib.util
import json
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


proxy = load_module("wloc_proxy", ROOT / "lib" / "wloc-proxy.py")
admin = load_module("wloc_admin", ROOT / "lib" / "wloc-admin.py")
bot = load_module("wloc_bot", ROOT / "lib" / "tgbot.py")


def field(number, wire, value):
    return proxy.encode_field(number, wire, value)


def signed(value):
    return value - (1 << 64) if value >= 1 << 63 else value


mac = b"aa:bb:cc:dd:ee:ff"
accuracy_raw = field(3, 0, 73)
location = field(1, 0, 31_230_400_000) + field(2, 0, 121_473_700_000) + accuracy_raw
wifi = field(1, 2, mac) + field(2, 2, location) + field(7, 0, 99)
payload = field(2, 2, wifi) + field(31, 0, 7)
framed = b"WLOCHEAD" + len(payload).to_bytes(2, "big") + payload

patched, stats = proxy.patch_wloc_body(framed, -33.8688, 151.2093)
assert stats == {"wifi": 1, "cell": 0, "locations": 1, "skipped": 0}
patched_payload = proxy.parse_fields(patched[10:])
patched_wifi = proxy.parse_fields(patched_payload[0].value)
patched_location = proxy.parse_fields(next(item.value for item in patched_wifi if item.number == 2))
values = {item.number: signed(item.value) for item in patched_location if item.wire == 0}
assert values[1] == -3_386_880_000
assert values[2] == 15_120_930_000
assert values[3] == 73, "Apple accuracy must be preserved"
assert patched_payload[1].raw == field(31, 0, 7), "unknown top-level fields must be preserved"

cell = field(5, 2, location) + field(9, 0, 123)
cell_payload = field(22, 2, cell) + field(24, 2, cell)
cell_frame = b"WLOCHEAD" + len(cell_payload).to_bytes(2, "big") + cell_payload
patched_cell, cell_stats = proxy.patch_wloc_body(cell_frame, 22.303611, 114.165)
assert cell_stats == {"wifi": 0, "cell": 2, "locations": 2, "skipped": 0}
for top_level in proxy.parse_fields(patched_cell[10:]):
    nested = proxy.parse_fields(top_level.value)
    coordinates = proxy.parse_fields(next(item.value for item in nested if item.number == 5))
    cell_values = {item.number: signed(item.value) for item in coordinates if item.wire == 0}
    assert cell_values[1] == 2_230_361_100 and cell_values[2] == 11_416_500_000
    assert cell_values[3] == 73

compressed, compressed_stats = proxy.patch_wloc_body(gzip.compress(framed), 35.6812, 139.7671)
assert compressed_stats["locations"] == 1
assert gzip.decompress(compressed).startswith(b"WLOCHEAD")

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    state_path = root / "state.json"
    state_path.write_text(json.dumps({
        "enabled": True,
        "latitude": 22.303611,
        "longitude": 114.165,
        "label": "香港西九龙站",
        "generation": 4,
    }), encoding="utf-8")
    assert proxy.load_target(state_path)["generation"] == 4
    state_path.write_text('{"enabled":true,"latitude":999}', encoding="utf-8")
    assert proxy.load_target(state_path) is None

    admin_state = root / "admin-state.json"
    admin.write_state(str(admin_state), "", True, "-33.8688", "151.2093", "  悉尼  ")
    assert admin.state_enabled(str(admin_state))
    saved = json.loads(admin_state.read_text(encoding="utf-8"))
    assert saved["label"] == "悉尼" and saved["generation"] == 1
    admin.write_state(str(admin_state), "", False)
    assert not admin.state_enabled(str(admin_state))

    sniproxy_path = root / "sniproxy.conf"
    sniproxy_path.write_text(
        "table tls_hosts {\n"
        "    # 5gpn-wloc routes begin (managed by 5gpn-ctl)\n"
        "    # 5gpn-wloc routes end\n"
        "    .* *:443\n}\n", encoding="utf-8")
    admin.update_sniproxy(str(sniproxy_path), True)
    enabled_config = sniproxy_path.read_text(encoding="utf-8")
    assert enabled_config.count("127.0.0.1:9080") == 1
    admin.update_sniproxy(str(sniproxy_path), True)
    assert sniproxy_path.read_text(encoding="utf-8") == enabled_config
    admin.update_sniproxy(str(sniproxy_path), False)
    assert "127.0.0.1:9080" not in sniproxy_path.read_text(encoding="utf-8")

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    bot.WLOC_STATE = str(root / "state.json")
    bot.WLOC_STATUS = str(root / "status.json")
    bot.WLOC_CA = str(root / "ca.crt")
    bot.WLOC_LOCATIONS = str(root / "locations.json")
    Path(bot.WLOC_STATE).write_text(json.dumps({
        "enabled": True,
        "latitude": 22.303611,
        "longitude": 114.165,
        "label": "香港西九龙站",
        "generation": 2,
    }), encoding="utf-8")
    Path(bot.WLOC_LOCATIONS).write_text(json.dumps({"locations": [
        {"name": "香港西九龙站", "latitude": 22.303611,
         "longitude": 114.165, "builtin": True},
    ]}), encoding="utf-8")
    bot._is_active = lambda service: "active" if service == "5gpn-wloc" else "inactive"

    assert bot._wloc_parse_coordinates("22.303611，114.165") == (22.303611, 114.165)
    for invalid in ("", "1", "91,1", "1,181"):
        try:
            bot._wloc_parse_coordinates(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid coordinates accepted: %r" % invalid)

    overview = bot.wloc_overview_text()
    keyboard = bot.wloc_menu()
    assert "WLOC 管理" in overview and "香港西九龙站" in overview
    assert any(button["text"].startswith("✅ 香港西九龙站")
               for row in keyboard for button in row)
    assert bot.op_wloc_add_location("悉尼歌剧院", -33.8568, 151.2153).startswith("✅")
    locations = bot._wloc_locations()
    assert len(locations) == 2 and locations[-1]["name"] == "悉尼歌剧院"
    token = bot._wloc_location_token(locations[-1])
    assert bot.op_wloc_delete_location(1, token).startswith("✅")
    assert len(bot._wloc_locations()) == 1

    edits = []
    bot.authorized = lambda _uid: True
    bot.answer_callback_async = lambda _callback_id: None
    bot.edit = lambda _cb, text, keyboard=None, mono=False: edits.append((text, keyboard))
    bot.handle_callback({
        "id": "callback",
        "from": {"id": 1},
        "message": {"chat": {"id": 1}, "message_id": 10},
        "data": "menu:wloc",
    })
    assert len(edits) == 1 and "功能即将上线" not in edits[0][0]

source = (ROOT / "install.sh").read_text(encoding="utf-8")
template = (ROOT / "lib" / "mosdns.yaml.template").read_text(encoding="utf-8")
sniproxy = (ROOT / "lib" / "sniproxy.conf").read_text(encoding="utf-8")
quic = (ROOT / "lib" / "quic-proxy.go").read_text(encoding="utf-8")
assert "install_wloc_runtime()" in source
assert "--wloc-set)" in source and "--wloc-off)" in source
assert "wloc_update_sniproxy()" in source
assert "wloc_restore_if_enabled" in source
assert "systemctl enable --now 5gpn-wloc" in source
assert 'cp "${ca_dir}/ca.crt" "${tmp}/ca.crt"' in source
assert "tag: wloc_domains" in template and "qname $wloc_domains" in template
assert "5gpn-wloc routes begin" in sniproxy
assert "isBlockedSNI" in quic and "wloc-quic-block.txt" in quic
assert (ROOT / "lib" / "tgbot.py").read_text(encoding="utf-8").count(
    '"📡 WLOC 管理", "callback_data": "menu:wloc"') == 1

print("wloc regression OK")
