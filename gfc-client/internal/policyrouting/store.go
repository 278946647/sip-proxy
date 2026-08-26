package policyrouting

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/278946647/sip-proxy/gfc-client/internal/config"
)

type Store struct {
	cfg *config.Config
	mu  sync.Mutex
}

func NewStore(cfg *config.Config) *Store {
	return &Store{cfg: cfg}
}

func (s *Store) dir() string {
	return filepath.Join(s.cfg.Paths.Etc, DirName)
}

func (s *Store) groupsPath() string {
	return filepath.Join(s.dir(), GroupsFile)
}

func (s *Store) policiesPath() string {
	return filepath.Join(s.dir(), PoliciesFile)
}

func (s *Store) Ensure() error {
	return os.MkdirAll(s.dir(), 0o755)
}

func (s *Store) LoadGroups() ([]Group, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadGroupsLocked()
}

func (s *Store) LoadPolicies() ([]Policy, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadPoliciesLocked()
}

func (s *Store) LoadAll() ([]Group, []Policy, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	groups, err := s.loadGroupsLocked()
	if err != nil {
		return nil, nil, err
	}
	policies, err := s.loadPoliciesLocked()
	if err != nil {
		return nil, nil, err
	}
	return groups, policies, nil
}

func (s *Store) SaveAll(groups []Group, policies []Policy) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.Ensure(); err != nil {
		return err
	}
	if err := writeJSON(s.groupsPath(), groupsFile{Groups: groups}); err != nil {
		return err
	}
	return writeJSON(s.policiesPath(), policiesFile{Policies: policies})
}

func (s *Store) loadGroupsLocked() ([]Group, error) {
	data, err := os.ReadFile(s.groupsPath())
	if err != nil {
		if os.IsNotExist(err) {
			return []Group{}, nil
		}
		return nil, err
	}
	var f groupsFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("解析 groups.json: %w", err)
	}
	if f.Groups == nil {
		return []Group{}, nil
	}
	return f.Groups, nil
}

func (s *Store) loadPoliciesLocked() ([]Policy, error) {
	data, err := os.ReadFile(s.policiesPath())
	if err != nil {
		if os.IsNotExist(err) {
			return []Policy{}, nil
		}
		return nil, err
	}
	var f policiesFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("解析 policies.json: %w", err)
	}
	if f.Policies == nil {
		return []Policy{}, nil
	}
	return f.Policies, nil
}

func writeJSON(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func newID(prefix string) string {
	var b [6]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("%s%d", prefix, time.Now().UnixNano())
	}
	return prefix + hex.EncodeToString(b[:])
}

func sortPoliciesByRank(policies []Policy) {
	sort.SliceStable(policies, func(i, j int) bool {
		if policies[i].Rank != policies[j].Rank {
			return policies[i].Rank < policies[j].Rank
		}
		return policies[i].ID < policies[j].ID
	})
}

func cloneGroups(in []Group) []Group {
	out := make([]Group, len(in))
	copy(out, in)
	for i := range out {
		out[i].Members = append([]string{}, in[i].Members...)
	}
	return out
}

func clonePolicies(in []Policy) []Policy {
	out := make([]Policy, len(in))
	copy(out, in)
	for i := range out {
		out[i].DangerTexts = append([]string{}, in[i].DangerTexts...)
	}
	return out
}

func groupMap(groups []Group) map[string]Group {
	m := make(map[string]Group, len(groups))
	for _, g := range groups {
		m[g.ID] = g
	}
	return m
}

func trimID(id string) string {
	return strings.TrimSpace(id)
}
