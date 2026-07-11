#!/usr/bin/env python3
"""
Tiny inetd-style HTTP responder for the iOS DoT profile.

Invoked once per connection by systemd socket activation (Accept=yes), with the
client socket wired to stdin/stdout. Serves a couple of static files from
WWW_DIR. Zero processes when idle.
"""
import os
import signal
import sys

WWW_DIR = os.environ.get("WWW_DIR", "/opt/proxy-gateway/www")

ROUTES = {
    "/ios-dot.mobileconfig": ("ios-dot.mobileconfig", "application/x-apple-aspen-config"),
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
}


def write(out, status, ctype, body):
    head = (
        "HTTP/1.1 %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "\r\n" % (status, ctype, len(body))
    ).encode("ascii")
    out.write(head)
    out.write(body)
    out.flush()


def main():
    # Never let a stalled/half-open connection linger as a live process.
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(0))
    signal.alarm(10)

    inp = sys.stdin.buffer
    out = sys.stdout.buffer

    line = inp.readline(8192).decode("latin1", "replace")
    parts = line.split()
    if len(parts) < 2 or parts[0] != "GET":
        write(out, "400 Bad Request", "text/plain", b"bad request\n")
        return
    path = parts[1].split("?", 1)[0]

    route = ROUTES.get(path)
    if not route:
        write(out, "404 Not Found", "text/plain", b"not found\n")
        return

    filename, ctype = route
    full = os.path.join(WWW_DIR, filename)
    try:
        with open(full, "rb") as f:
            body = f.read()
    except OSError:
        write(out, "404 Not Found", "text/plain", b"not found\n")
        return
    write(out, "200 OK", ctype, body)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
