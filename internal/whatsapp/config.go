package whatsapp

import "fmt"

type Config struct {
	Listen   string
	Upstream string
	DNS      string
}

func (c Config) Validate() error {
	if c.Listen == "" {
		return fmt.Errorf("WhatsApp listen address is required")
	}
	if c.Upstream == "" {
		return fmt.Errorf("WhatsApp upstream is required")
	}
	return nil
}
