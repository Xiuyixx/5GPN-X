#!/usr/bin/env python3
"""
Generate an iOS ``.mobileconfig`` that installs the WLOC MITM CA (public cert
ONLY) as a trusted root.

Usage:
    wloc-ca-profile.py <ca-cert.pem> <out.mobileconfig> [display-name]

Reads a PEM X.509 certificate (the mitmproxy CA *public* certificate), strips
the ``-----BEGIN/END-----`` armor, and embeds the DER bytes as an
``com.apple.security.root`` payload. The private key is never read and can never
be embedded (this tool only accepts a certificate file).

The profile intentionally sets PayloadRemovalDisallowed=false so the user can
remove it later. iOS still requires the user to manually enable full trust under
Settings -> General -> About -> Certificate Trust Settings.
"""
import base64
import re
import sys
import uuid


def die(msg):
    print("error: %s" % msg, file=sys.stderr)
    sys.exit(1)


def load_cert_der(path):
    try:
        with open(path, "r", encoding="ascii", errors="ignore") as f:
            pem = f.read()
    except OSError as exc:
        die("cannot read cert: %s" % exc)
    # Reject anything that looks like a private key to avoid operator mistakes.
    if "PRIVATE KEY" in pem:
        die("refusing to build profile from a file containing a PRIVATE KEY")
    m = re.search(r"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", pem, re.S)
    if not m:
        die("no PEM CERTIFICATE block found")
    b64 = re.sub(r"\s+", "", m.group(1))
    try:
        return base64.b64decode(b64)
    except Exception as exc:  # noqa: BLE001
        die("invalid base64 in certificate: %s" % exc)


def wrap_b64(data, width=52):
    b64 = base64.b64encode(data).decode("ascii")
    lines = [b64[i:i + width] for i in range(0, len(b64), width)]
    return "\n".join("            " + ln for ln in lines)


def main():
    if len(sys.argv) < 3:
        die("usage: wloc-ca-profile.py <ca-cert.pem> <out.mobileconfig> [name]")
    cert_path, out_path = sys.argv[1], sys.argv[2]
    name = sys.argv[3] if len(sys.argv) > 3 else "5GPN WLOC CA"
    der = load_cert_der(cert_path)
    cert_b64 = wrap_b64(der)
    payload_uuid = str(uuid.uuid4()).upper()
    top_uuid = str(uuid.uuid4()).upper()

    profile = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadCertificateFileName</key>
            <string>5gpn-wloc-ca.cer</string>
            <key>PayloadContent</key>
            <data>
%s
            </data>
            <key>PayloadDescription</key>
            <string>Installs the 5GPN WLOC MITM root certificate (public key only).</string>
            <key>PayloadDisplayName</key>
            <string>%s</string>
            <key>PayloadIdentifier</key>
            <string>com.5gpn.wloc.ca</string>
            <key>PayloadType</key>
            <string>com.apple.security.root</string>
            <key>PayloadUUID</key>
            <string>%s</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Installs the 5GPN WLOC root certificate so the gateway can rewrite Apple network-location responses. After installing, enable full trust under Settings -&gt; General -&gt; About -&gt; Certificate Trust Settings.</string>
    <key>PayloadDisplayName</key>
    <string>%s</string>
    <key>PayloadIdentifier</key>
    <string>com.5gpn.wloc</string>
    <key>PayloadOrganization</key>
    <string>5GPN</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>%s</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
""" % (cert_b64, name, payload_uuid, name, top_uuid)

    try:
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(profile)
    except OSError as exc:
        die("cannot write profile: %s" % exc)
    print(out_path)


if __name__ == "__main__":
    main()
