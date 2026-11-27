package quic

import "fmt"

type Config struct {
	Listen  string
	DNSFile string
}

func (c Config) Validate() error {
	if c.Listen == "" {
		return fmt.Errorf("QUIC listen address is required")
	}
	if c.DNSFile == "" {
		return fmt.Errorf("QUIC DNS file is required")
	}
	return nil
}
