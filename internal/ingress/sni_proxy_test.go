package ingress

import "testing"

func TestClientHelloRejectsInvalidData(t *testing.T) {
	if _, ok := ClientHelloSNI([]byte("not tls")); ok {
		t.Fatal("invalid hello accepted")
	}
}
