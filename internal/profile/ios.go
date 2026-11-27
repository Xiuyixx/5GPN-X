// Package profile generates the iOS managed DNS configuration profile.
package profile

import (
	"fmt"
	"github.com/google/uuid"
)

func IOSDoT(domain, publicIP string) ([]byte, error) {
	if domain == "" || publicIP == "" {
		return nil, fmt.Errorf("domain and public IP are required")
	}
	inner, outer := uuid.New(), uuid.New()
	return []byte(fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>PayloadContent</key><array><dict>
<key>DNSSettings</key><dict><key>DNSProtocol</key><string>TLS</string><key>ServerName</key><string>%s</string><key>ServerAddresses</key><array><string>%s</string></array></dict>
<key>OnDemandRules</key><array><dict><key>Action</key><string>Connect</string><key>InterfaceTypeMatch</key><string>Cellular</string></dict><dict><key>Action</key><string>Disconnect</string><key>InterfaceTypeMatch</key><string>WiFi</string></dict><dict><key>Action</key><string>Disconnect</string></dict></array>
<key>PayloadDescription</key><string>仅在蜂窝网络启用加密 DNS（DoT），连接 Wi-Fi 时自动停用。</string><key>PayloadDisplayName</key><string>5GPN-X</string><key>PayloadIdentifier</key><string>com.5gpn.%s.dnssettings</string><key>PayloadType</key><string>com.apple.dnsSettings.managed</string><key>PayloadUUID</key><string>%s</string><key>PayloadVersion</key><integer>1</integer>
</dict></array><key>PayloadDescription</key><string>仅在蜂窝网络启用加密 DNS（DoT），连接 Wi-Fi 时自动停用。</string><key>PayloadDisplayName</key><string>5GPN-X</string><key>PayloadIdentifier</key><string>com.5gpn.%s</string><key>PayloadOrganization</key><string>5GPN-X</string><key>PayloadRemovalDisallowed</key><false/><key>PayloadType</key><string>Configuration</string><key>PayloadUUID</key><string>%s</string><key>PayloadVersion</key><integer>1</integer>
</dict></plist>
`, domain, publicIP, domain, inner, domain, outer)), nil
}
