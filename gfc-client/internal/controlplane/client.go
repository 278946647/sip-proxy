package controlplane

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type ClientState struct {
	DeviceID       int    `json:"device_id"`
	DeviceKey      string `json:"device_key"`
	ClientToken    string `json:"client_token"`
	LineID         int    `json:"line_id"`
	TID            string `json:"tid"`
	AppliedVersion string `json:"applied_version,omitempty"`
}

type ConfigBundle struct {
	Version string         `json:"version"`
	Payload map[string]any `json:"payload"`
}

type Client struct {
	servers   []string
	token     string
	activeIdx int
	http      *http.Client
}

func New(servers []string, token string) (*Client, error) {
	normalized := normalizeURLs(servers)
	if len(normalized) == 0 {
		return nil, fmt.Errorf("no control plane URL configured")
	}
	return &Client{
		servers: normalized,
		token:   token,
		http:    &http.Client{Timeout: 30 * time.Second},
	}, nil
}

func normalizeURLs(urls []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, u := range urls {
		u = strings.TrimSpace(u)
		u = strings.TrimRight(u, "/")
		if u == "" || seen[u] {
			continue
		}
		seen[u] = true
		out = append(out, u)
	}
	return out
}

func (c *Client) ActiveServer() string {
	return c.servers[c.activeIdx]
}

func (c *Client) CheckReachable() bool {
	_, err := c.request("GET", "/health", nil, false)
	return err == nil
}

func (c *Client) Activate(lineCode, deviceName, lanMAC, deviceID, proxyMode, agentVersion string) (*ClientState, error) {
	body := map[string]any{
		"line_code_b32": lineCode,
		"device_name":   deviceName,
		"lan_mac":       lanMAC,
		"device_id":     deviceID,
		"proxy_mode":    proxyMode,
		"agent_version": agentVersion,
	}
	var resp ClientState
	if err := c.requestJSON("POST", "/clients/activate", body, false, &resp); err != nil {
		return nil, err
	}
	c.token = resp.ClientToken
	return &resp, nil
}

type HeartbeatResult struct {
	ReverseSSH          map[string]any `json:"reverse_ssh"`
	WebSSHAuthorizedKey string         `json:"webssh_authorized_key"`
	DeviceCommand       *DeviceCommand `json:"device_command"`
}

type DeviceCommand struct {
	Action    string `json:"action"`
	RequestID string `json:"request_id"`
}

func (c *Client) Heartbeat(
	metrics map[string]any,
	deviceName string,
	reverseSSHPort, reverseHTTPPort *int,
	sshPublicKey string,
	reverseSSHStatus map[string]any,
	proxyMode, agentVersion string,
	deviceCommandAck map[string]any,
) (*HeartbeatResult, error) {
	body := map[string]any{
		"metrics":       metrics,
		"device_name":   deviceName,
		"agent_version": agentVersion,
		"proxy_mode":    proxyMode,
	}
	if reverseSSHPort != nil {
		body["reverse_ssh_port"] = *reverseSSHPort
	}
	if reverseHTTPPort != nil {
		body["reverse_http_port"] = *reverseHTTPPort
	}
	if strings.TrimSpace(sshPublicKey) != "" {
		body["ssh_public_key"] = strings.TrimSpace(sshPublicKey)
	}
	if reverseSSHStatus != nil {
		body["reverse_ssh_status"] = reverseSSHStatus
	}
	if deviceCommandAck != nil {
		body["device_command_ack"] = deviceCommandAck
	}
	var resp HeartbeatResult
	if err := c.requestJSON("POST", "/clients/heartbeat", body, true, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (c *Client) PullConfig() (*ConfigBundle, error) {
	var bundle ConfigBundle
	if err := c.requestJSON("GET", "/clients/me/config", nil, true, &bundle); err != nil {
		return nil, err
	}
	return &bundle, nil
}

func (c *Client) AckConfig(version, status, message string) error {
	body := map[string]any{
		"version": version,
		"status":  status,
		"message": message,
	}
	return c.requestJSON("POST", "/clients/me/config/ack", body, true, nil)
}

func (c *Client) UpdateRuntime(routingScheme, proxyMode string) error {
	body := map[string]any{}
	if strings.TrimSpace(routingScheme) != "" {
		body["routing_scheme"] = strings.ToLower(strings.TrimSpace(routingScheme))
	}
	if strings.TrimSpace(proxyMode) != "" {
		body["proxy_mode"] = strings.ToLower(strings.TrimSpace(proxyMode))
	}
	if len(body) == 0 {
		return nil
	}
	return c.requestJSON("PATCH", "/clients/me/runtime", body, true, nil)
}

func (c *Client) requestJSON(method, path string, body any, auth bool, out any) error {
	var r io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		r = bytes.NewReader(raw)
	}
	resp, err := c.request(method, path, r, auth)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *Client) request(method, path string, body io.Reader, auth bool) (*http.Response, error) {
	var lastErr error
	for idx, base := range c.servers {
		req, err := http.NewRequest(method, base+path, body)
		if err != nil {
			return nil, err
		}
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		if auth && c.token != "" {
			req.Header.Set("Authorization", "Bearer "+c.token)
		}
		resp, err := c.http.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		if resp.StatusCode >= 400 {
			b, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			lastErr = fmt.Errorf("%s %s: %s", method, path, strings.TrimSpace(string(b)))
			if resp.StatusCode == 401 {
				return nil, lastErr
			}
			continue
		}
		if idx != c.activeIdx {
			c.activeIdx = idx
		}
		return resp, nil
	}
	if lastErr != nil {
		return nil, lastErr
	}
	return nil, fmt.Errorf("no control plane URL")
}
