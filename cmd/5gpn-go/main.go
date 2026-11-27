// Command 5gpn-go is the Go management CLI during the architecture migration.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/Xiuyixx/5GPN-X/internal/config"
	"github.com/Xiuyixx/5GPN-X/internal/manage"
	"github.com/Xiuyixx/5GPN-X/internal/migrate"
)

const (
	defaultConfig = "/opt/5gpn/etc/5gpn-go.json"
	legacyConf    = "/opt/5gpn/etc"
	legacyExits   = "/etc/5gpn/exits"
	legacyRules   = "/etc/5gpn/rules.conf"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	configPath := os.Getenv("PGW_GO_CONFIG")
	if configPath == "" {
		configPath = defaultConfig
	}
	cmd := os.Args[1]
	args := os.Args[2:]
	if cmd == "help" || cmd == "--help" || cmd == "-h" {
		usage()
		return
	}
	if cmd == "version" {
		fmt.Println("5gpn-go dev")
		return
	}
	if err := run(cmd, args, configPath); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func run(cmd string, args []string, configPath string) error {
	paths := manage.Paths{Config: configPath, Legacy: migrate.Paths{ConfDir: legacyConf, ExitsDir: legacyExits, Rules: legacyRules}}
	if cmd == "migrate" {
		cfg, err := migrate.LoadLegacy(paths.Legacy)
		if err != nil {
			return err
		}
		if err := cfg.Save(configPath); err != nil {
			return err
		}
		fmt.Printf("migrated Go config: %s\n", configPath)
		return nil
	}
	m, err := manage.Open(paths)
	if err != nil {
		return err
	}
	switch cmd {
	case "status":
		return printStatus(m.Snapshot())
	case "list-exits":
		return printExits(m.Snapshot())
	case "show-rules":
		for _, rule := range m.Snapshot().Rules {
			fmt.Println(rule)
		}
		return nil
	case "set-exit":
		if len(args) != 1 {
			return fmt.Errorf("usage: set-exit <name|DIRECT>")
		}
		if err := m.SetDefault(args[0]); err != nil {
			return err
		}
		fmt.Printf("default egress: %s\n", args[0])
		return nil
	case "set-app":
		if len(args) != 2 {
			return fmt.Errorf("usage: set-app <app-key> <target|DIRECT|->")
		}
		target := args[1]
		if target == "-" {
			target = ""
		}
		if err := m.SetApp(args[0], target); err != nil {
			return err
		}
		fmt.Printf("application %s: %s\n", args[0], displayTarget(target))
		return nil
	case "check":
		return check(m.Snapshot())
	default:
		return fmt.Errorf("unknown command %q", cmd)
	}
}

func printStatus(cfg config.Config) error {
	return printJSON(map[string]any{"final": cfg.Final, "egress": len(cfg.Egress), "apps": len(cfg.Apps), "rules": len(cfg.Rules)})
}

func printExits(cfg config.Config) error {
	for _, e := range cfg.Egress {
		mark := "○"
		if e.Name == cfg.Final || (e.Name == "DIRECT" && cfg.Final == "DIRECT") {
			mark = "●"
		}
		fmt.Printf("%s %s\t%s\n", mark, e.Name, e.Type)
	}
	return nil
}

func check(cfg config.Config) error {
	if cfg.Final == "" {
		return fmt.Errorf("default egress is empty")
	}
	for app, target := range cfg.Apps {
		if err := validateTarget(cfg, target); err != nil {
			return fmt.Errorf("app %s: %w", app, err)
		}
	}
	fmt.Println("configuration OK")
	return nil
}

func validateTarget(cfg config.Config, target string) error {
	if target == "" || target == "DIRECT" {
		return nil
	}
	for _, e := range cfg.Egress {
		if e.Name == target {
			return nil
		}
	}
	return fmt.Errorf("unknown target %q", target)
}

func displayTarget(target string) string {
	if target == "" {
		return "follow default"
	}
	return target
}
func printJSON(value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(data))
	return nil
}
func usage() {
	fmt.Printf("5gpn-go: Go gateway management CLI\n\ncommands: status, list-exits, set-exit, set-app, show-rules, migrate, check, version\nconfig: PGW_GO_CONFIG (default %s)\n", defaultConfig)
}
