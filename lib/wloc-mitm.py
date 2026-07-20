#!/usr/bin/env python3
"""
mitmproxy addon for 5GPN-X WLOC (Apple network-location) rewriting.

Runs as the ``5gpn-wloc`` systemd service on loopback only, one reverse
listener per Apple host:

    mitmdump --mode reverse:https://gs-loc.apple.com@127.0.0.1:9080 \
             --mode reverse:https://gs-loc-cn.apple.com@127.0.0.1:9081 \
             --set confdir=/var/lib/5gpn-wloc/mitmproxy \
             -s /opt/5gpn/bin/wloc-mitm.py

Data path: mosdns hijacks gs-loc(.cn).apple.com to the gateway IP; the phone's
TLS to :443 is fronted by wa-shim and failed open to sniproxy (127.0.0.1:8443),
which forwards each Apple host to a per-host reverse listener on this sidecar
(gs-loc.apple.com -> 127.0.0.1:9080, gs-loc-cn.apple.com -> 127.0.0.1:9081).
mitmproxy runs one ``--mode reverse:https://<host>`` listener per host, so the
real Apple upstream is resolved by mitmproxy's own (clean) resolver and never
touched by the local DNS hijack. Only the two Apple hosts are ever rewritten;
any non-target host, non-``/clls/wloc`` path, non-200 response, or parse error
fails open (original bytes preserved).

Coordinate rewriting lives in the dependency-free lib/wloc-core.py so it can be
unit-tested without mitmproxy installed.

Inspired by Loading886/Home-Location-Endpoint (MIT) and
gibaragibara/privdns-gateway-mihomo (MIT); no code copied.
"""
import importlib.util
import os
import sys

CORE_PATH = os.environ.get("WLOC_CORE", "/opt/5gpn/bin/wloc-core.py")
CONFIG_PATH = os.environ.get("WLOC_CONFIG", "/var/lib/5gpn-wloc/wloc.json")

if not os.path.exists(CORE_PATH):
    CORE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "wloc-core.py")
_spec = importlib.util.spec_from_file_location("wloc_core", CORE_PATH)
wc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(wc)


def _log(msg):
    print("[wloc] %s" % msg, file=sys.stderr)


class WlocRewriter:
    """mitmproxy addon: rewrite Apple WLOC responses when WLOC is enabled."""

    def _host_of(self, conn_host):
        return (conn_host or "").lower().rstrip(".")

    def _request_host(self, req):
        """Best host identity for a request: prefer the Host header (the client's
        intended Apple hostname) then the connection's pretty_host."""
        host = self._host_of(req.host_header)
        if host in wc.WLOC_HOSTS:
            return host
        return self._host_of(req.pretty_host)

    def response(self, flow):
        try:
            req = flow.request
            host = self._request_host(req)
            if host not in wc.WLOC_HOSTS:
                return
            if req.path.split("?", 1)[0] != wc.WLOC_PATH:
                return

            cfg = wc.load_config(CONFIG_PATH)
            if not cfg.get("enabled"):
                return
            lat, lon = cfg.get("latitude"), cfg.get("longitude")
            if not (wc.valid_lat(lat) and wc.valid_lon(lon)):
                return

            original = flow.response.raw_content
            if not original:
                return
            rewritten = wc.rewrite_wloc_response(original, lat, lon)
            if rewritten is not None and rewritten != original:
                flow.response.raw_content = rewritten
                _log("rewrote %s%s -> (%.6f, %.6f)" % (host, wc.WLOC_PATH, lat, lon))
        except Exception as exc:  # fail-open: never break the flow
            _log("response passthrough after error: %r" % exc)


addons = [WlocRewriter()]
