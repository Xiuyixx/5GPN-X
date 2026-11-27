// Package ruleset loads and caches domain rule sets for the Go policy engine.
package ruleset

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

type DomainSet struct{ suffixes map[string]struct{} }

func NewDomainSet(domains []string) *DomainSet {
	s := make(map[string]struct{}, len(domains))
	for _, d := range domains {
		d = normalize(d)
		if d != "" {
			s[d] = struct{}{}
		}
	}
	return &DomainSet{suffixes: s}
}

func (s *DomainSet) Match(domain string) bool {
	if s == nil {
		return false
	}
	domain = normalize(domain)
	for domain != "" {
		if _, ok := s.suffixes[domain]; ok {
			return true
		}
		if i := strings.IndexByte(domain, '.'); i >= 0 {
			domain = domain[i+1:]
		} else {
			break
		}
	}
	return false
}

func LoadFile(path string) (*DomainSet, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var domains []string
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		line = strings.TrimPrefix(line, "+.")
		if strings.Contains(line, ",") {
			line = strings.TrimSpace(strings.Split(line, ",")[0])
		}
		domains = append(domains, line)
	}
	if err := s.Err(); err != nil {
		return nil, err
	}
	return NewDomainSet(domains), nil
}

func Fetch(ctx context.Context, client *http.Client, url, cacheDir, name string) (*DomainSet, error) {
	if client == nil {
		client = http.DefaultClient
	}
	if name == "" {
		return nil, fmt.Errorf("ruleset name is required")
	}
	path := filepath.Join(cacheDir, name+".list")
	if data, err := os.ReadFile(path); err == nil {
		return NewDomainSet(strings.Split(string(data), "\n")), nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("ruleset HTTP %s", resp.Status)
	}
	data, err := readLimited(resp.Body, 8<<20)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(cacheDir, 0o700); err != nil {
		return nil, err
	}
	tmp, err := os.CreateTemp(cacheDir, ".ruleset-*")
	if err != nil {
		return nil, err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err = tmp.Write(data); err == nil {
		err = tmp.Sync()
	}
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(tmpName, 0o600); err != nil {
		return nil, err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return nil, err
	}
	return NewDomainSet(strings.Split(string(data), "\n")), nil
}

func normalize(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.TrimPrefix(value, "||")
	value = strings.TrimPrefix(value, "*.")
	return strings.TrimSuffix(value, ".")
}

func readLimited(r interface{ Read([]byte) (int, error) }, limit int64) ([]byte, error) {
	var out []byte
	buf := make([]byte, 32*1024)
	for int64(len(out)) <= limit {
		n, err := r.Read(buf)
		out = append(out, buf[:n]...)
		if err != nil {
			if int64(len(out)) > limit {
				return nil, fmt.Errorf("ruleset exceeds %d bytes", limit)
			}
			if err == io.EOF {
				return out, nil
			}
			return nil, err
		}
	}
	return nil, fmt.Errorf("ruleset exceeds %d bytes", limit)
}
