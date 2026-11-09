package policyguard

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type PolicyDocument struct {
	FilesystemPolicy struct {
		MaskedPaths []string `yaml:"masked_paths"`
	} `yaml:"filesystem_policy"`
	NetworkPolicies map[string]any `yaml:"network_policies"`
}

type Guard struct {
	Active         bool
	PolicyPath     string
	RepoRoot       string
	MaskedPaths    []string
	AllowedHostPort map[string]bool
}

func LoadFromEnv(defaultRepoRoot string) *Guard {
	policyPath := os.Getenv("OPENSHELL_POLICY_FILE")
	repoRoot := os.Getenv("OPENSHELL_REPO_ROOT")
	if repoRoot == "" {
		repoRoot = defaultRepoRoot
	}
	absRoot, err := filepath.Abs(repoRoot)
	if err == nil {
		repoRoot = absRoot
	}

	g := &Guard{
		Active:          policyPath != "",
		PolicyPath:      policyPath,
		RepoRoot:        repoRoot,
		AllowedHostPort: make(map[string]bool),
	}

	if !g.Active {
		return g
	}

	data, err := os.ReadFile(policyPath)
	if err != nil {
		return g
	}

	var doc PolicyDocument
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return g
	}

	for _, rel := range doc.FilesystemPolicy.MaskedPaths {
		clean := strings.TrimPrefix(strings.TrimPrefix(rel, "./"), "/")
		target := filepath.Clean(filepath.Join(repoRoot, clean))
		g.MaskedPaths = append(g.MaskedPaths, target)
	}

	for key, rawRule := range doc.NetworkPolicies {
		if key == "default_egress" {
			continue
		}
		ruleMap, ok := rawRule.(map[string]any)
		if !ok {
			continue
		}
		eps, ok := ruleMap["endpoints"].([]any)
		if !ok {
			continue
		}
		for _, epRaw := range eps {
			ep, ok := epRaw.(map[string]any)
			if !ok {
				continue
			}
			host := fmt.Sprintf("%v", ep["host"])
			var port int
			switch p := ep["port"].(type) {
			case int:
				port = p
			case string:
				port, _ = strconv.Atoi(p)
			}
			if port <= 0 {
				continue
			}
			g.allowEndpoint(host, port)
		}
	}

	g.installHTTPTransportGuard()
	return g
}

func (g *Guard) allowEndpoint(host string, port int) {
	pStr := strconv.Itoa(port)
	g.AllowedHostPort[net.JoinHostPort(host, pStr)] = true
	if host == "127.0.0.1" || host == "localhost" {
		g.AllowedHostPort[net.JoinHostPort("127.0.0.1", pStr)] = true
		g.AllowedHostPort[net.JoinHostPort("localhost", pStr)] = true
		g.AllowedHostPort[net.JoinHostPort("::1", pStr)] = true
		g.AllowedHostPort[net.JoinHostPort("host.docker.internal", pStr)] = true
	}
}

func (g *Guard) IsPathMasked(targetPath string) bool {
	if !g.Active {
		return false
	}
	absTarget, err := filepath.Abs(targetPath)
	if err != nil {
		absTarget = filepath.Clean(targetPath)
	}
	for _, masked := range g.MaskedPaths {
		if absTarget == masked || strings.HasPrefix(absTarget, masked+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func (g *Guard) installHTTPTransportGuard() {
	baseDialer := &net.Dialer{
		Timeout:   4 * time.Second,
		KeepAlive: 15 * time.Second,
	}

	http.DefaultTransport = &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			if !g.isAddrAllowed(addr) {
				return nil, fmt.Errorf("[OpenShell Network Policy] Egress to %s denied (default_egress: deny)", addr)
			}
			return baseDialer.DialContext(ctx, network, addr)
		},
	}
}

func (g *Guard) isAddrAllowed(addr string) bool {
	if !g.Active {
		return true
	}
	if g.AllowedHostPort[addr] {
		return true
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if g.AllowedHostPort[net.JoinHostPort(host, port)] {
		return true
	}
	// Support Docker Desktop on macOS resolving host.docker.internal
	if ips, err := net.LookupHost("host.docker.internal"); err == nil {
		for _, ip := range ips {
			if ip == host && g.AllowedHostPort[net.JoinHostPort("host.docker.internal", port)] {
				return true
			}
		}
	}
	return false
}
