package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(1)")
	if err != nil {
		return nil, err
	}
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) migrate() error {
	schema := `
CREATE TABLE IF NOT EXISTS device (
    id INTEGER PRIMARY KEY,
    device_key TEXT UNIQUE,
    device_name TEXT NOT NULL DEFAULT '',
    lan_mac TEXT,
    device_id TEXT,
    line_id INTEGER,
    tid TEXT,
    client_token TEXT,
    control_plane_url TEXT,
    proxy_mode TEXT NOT NULL DEFAULT 'gateway',
    agent_version TEXT,
    state TEXT NOT NULL DEFAULT 'idle',
    applied_version TEXT,
    activated_at TEXT,
    last_seen_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS activation (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    line_code_b32 TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    flashed_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS nodes (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL DEFAULT 'vless',
    server TEXT NOT NULL,
    port INTEGER NOT NULL,
    uuid TEXT,
    config_json TEXT NOT NULL,
    latency_ms INTEGER,
    enabled INTEGER NOT NULL DEFAULT 1,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS policy_groups (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    outbounds_json TEXT NOT NULL,
    config_json TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS policy_selection (
    group_id TEXT PRIMARY KEY,
    selected_outbound TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    routing_mode TEXT NOT NULL DEFAULT 'split',
    singbox_log_level TEXT NOT NULL DEFAULT 'error',
    singbox_verbose INTEGER NOT NULL DEFAULT 0,
    dns_domestic TEXT NOT NULL DEFAULT '223.5.5.5',
    dns_intl TEXT NOT NULL DEFAULT '1.1.1.1',
    easymosdns_source TEXT NOT NULL DEFAULT 'github',
    easymosdns_updated_at TEXT,
    easymosdns_auto_update INTEGER NOT NULL DEFAULT 1
);
INSERT OR IGNORE INTO settings (id) VALUES (1);
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL DEFAULT (datetime('now')),
    action TEXT NOT NULL,
    detail_json TEXT,
    result TEXT
);
`
	if _, err := s.db.Exec(schema); err != nil {
		return err
	}
	return nil
}

type Device struct {
	DeviceKey       string
	DeviceName      string
	LanMAC          string
	DeviceID        string
	LineID          int
	TID             string
	ClientToken     string
	ControlPlaneURL string
	ProxyMode       string
	State           string
	AppliedVersion  string
}

func (s *Store) SaveDevice(d Device) error {
	_, err := s.db.Exec(`
INSERT INTO device (id, device_key, device_name, lan_mac, device_id, line_id, tid, client_token,
    control_plane_url, proxy_mode, state, applied_version, activated_at, last_seen_at)
VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
ON CONFLICT(id) DO UPDATE SET
    device_key=excluded.device_key, device_name=excluded.device_name, lan_mac=excluded.lan_mac,
    device_id=excluded.device_id, line_id=excluded.line_id, tid=excluded.tid,
    client_token=excluded.client_token, control_plane_url=excluded.control_plane_url,
    proxy_mode=excluded.proxy_mode, state=excluded.state, applied_version=excluded.applied_version,
    last_seen_at=datetime('now')
`, d.DeviceKey, d.DeviceName, d.LanMAC, d.DeviceID, d.LineID, d.TID, d.ClientToken,
		d.ControlPlaneURL, d.ProxyMode, d.State, d.AppliedVersion)
	return err
}

func (s *Store) GetDevice() (*Device, error) {
	row := s.db.QueryRow(`SELECT device_key, device_name, lan_mac, device_id, line_id, tid,
        client_token, control_plane_url, proxy_mode, state, applied_version FROM device WHERE id=1`)
	var d Device
	var lineID sql.NullInt64
	err := row.Scan(&d.DeviceKey, &d.DeviceName, &d.LanMAC, &d.DeviceID, &lineID, &d.TID,
		&d.ClientToken, &d.ControlPlaneURL, &d.ProxyMode, &d.State, &d.AppliedVersion)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if lineID.Valid {
		d.LineID = int(lineID.Int64)
	}
	return &d, nil
}

func (s *Store) ClearDevice() error {
	_, err := s.db.Exec(`DELETE FROM device WHERE id=1`)
	return err
}

func (s *Store) SaveActivation(code string, payload map[string]any) error {
	raw, _ := json.Marshal(payload)
	_, err := s.db.Exec(`INSERT INTO activation (line_code_b32, payload_json) VALUES (?, ?)`, code, string(raw))
	return err
}

func (s *Store) UpsertNode(id, name, server string, port int, uuid string, config map[string]any) error {
	raw, _ := json.Marshal(config)
	_, err := s.db.Exec(`
INSERT INTO nodes (id, name, server, port, uuid, config_json, updated_at)
VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
ON CONFLICT(id) DO UPDATE SET name=excluded.name, server=excluded.server, port=excluded.port,
    uuid=excluded.uuid, config_json=excluded.config_json, updated_at=datetime('now')
`, id, name, server, port, uuid, string(raw))
	return err
}

func (s *Store) ListNodes() ([]map[string]any, error) {
	rows, err := s.db.Query(`SELECT id, name, type, server, port, uuid, latency_ms, enabled FROM nodes ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []map[string]any
	for rows.Next() {
		var id, name, typ, server, uuid string
		var port, latency, enabled int
		if err := rows.Scan(&id, &name, &typ, &server, &port, &uuid, &latency, &enabled); err != nil {
			return nil, err
		}
		list = append(list, map[string]any{
			"id": id, "name": name, "type": typ, "server": server, "port": port,
			"uuid": uuid, "latency_ms": latency, "enabled": enabled == 1,
		})
	}
	return list, nil
}

func (s *Store) GetSettings() (map[string]any, error) {
	row := s.db.QueryRow(`SELECT routing_mode, singbox_log_level, singbox_verbose, dns_domestic, dns_intl,
        easymosdns_source, easymosdns_updated_at, easymosdns_auto_update FROM settings WHERE id=1`)
	var routing, logLevel, dnsDom, dnsIntl, source string
	var verbose, autoUpdate int
	var updatedAt sql.NullString
	if err := row.Scan(&routing, &logLevel, &verbose, &dnsDom, &dnsIntl, &source, &updatedAt, &autoUpdate); err != nil {
		return nil, err
	}
	m := map[string]any{
		"routing_mode": routing, "singbox_log_level": logLevel, "singbox_verbose": verbose == 1,
		"dns_domestic": dnsDom, "dns_intl": dnsIntl, "easymosdns_source": source,
		"easymosdns_auto_update": autoUpdate == 1,
	}
	if updatedAt.Valid {
		m["easymosdns_updated_at"] = updatedAt.String
	}
	return m, nil
}

func (s *Store) UpdateSettings(fields map[string]any) error {
	allowed := map[string]string{
		"routing_mode": "routing_mode", "singbox_log_level": "singbox_log_level",
		"dns_domestic": "dns_domestic", "dns_intl": "dns_intl", "easymosdns_source": "easymosdns_source",
	}
	for k, col := range allowed {
		if v, ok := fields[k]; ok {
			if _, err := s.db.Exec(fmt.Sprintf(`UPDATE settings SET %s=? WHERE id=1`, col), v); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Store) Audit(action string, detail map[string]any, result string) {
	raw, _ := json.Marshal(detail)
	_, _ = s.db.Exec(`INSERT INTO audit_log (action, detail_json, result) VALUES (?, ?, ?)`, action, string(raw), result)
}

func (s *Store) DefaultPolicyGroups() error {
	_, err := s.db.Exec(`
INSERT OR IGNORE INTO policy_groups (id, name, type, outbounds_json, sort_order)
VALUES ('proxy', '手动选择', 'selector', '["proxy"]', 0),
       ('auto', '延迟最低', 'urltest', '["proxy"]', 1),
       ('fallback', '故障转移', 'fallback', '["proxy"]', 2)
`)
	return err
}

func (s *Store) ListPolicyGroups() ([]map[string]any, error) {
	rows, err := s.db.Query(`SELECT id, name, type, outbounds_json FROM policy_groups ORDER BY sort_order`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []map[string]any
	for rows.Next() {
		var id, name, typ, outJSON string
		if err := rows.Scan(&id, &name, &typ, &outJSON); err != nil {
			return nil, err
		}
		var outbounds []string
		_ = json.Unmarshal([]byte(outJSON), &outbounds)
		selected := "proxy"
		row := s.db.QueryRow(`SELECT selected_outbound FROM policy_selection WHERE group_id=?`, id)
		_ = row.Scan(&selected)
		list = append(list, map[string]any{
			"id": id, "name": name, "type": typ, "outbounds": outbounds, "selected": selected,
		})
	}
	return list, nil
}

func (s *Store) SelectPolicy(groupID, outbound string) error {
	_, err := s.db.Exec(`
INSERT INTO policy_selection (group_id, selected_outbound, updated_at) VALUES (?, ?, datetime('now'))
ON CONFLICT(group_id) DO UPDATE SET selected_outbound=excluded.selected_outbound, updated_at=datetime('now')
`, groupID, outbound)
	return err
}

func NowRFC3339() string {
	return time.Now().UTC().Format(time.RFC3339)
}
