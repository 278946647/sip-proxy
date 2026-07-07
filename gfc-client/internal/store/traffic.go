package store

import (
	"database/sql"
	"time"
)

const trafficRetention = 49 * time.Hour

type TrafficSample struct {
	TS       int64
	Iface    string
	BytesIn  uint64
	BytesOut uint64
}

func (s *Store) InsertTrafficSample(iface string, bytesIn, bytesOut uint64, at time.Time) error {
	if iface == "" {
		iface = "gfctun"
	}
	ts := at.UTC().Unix()
	if _, err := s.db.Exec(
		`INSERT INTO traffic_samples (ts, iface, bytes_in, bytes_out) VALUES (?, ?, ?, ?)`,
		ts, iface, bytesIn, bytesOut,
	); err != nil {
		return err
	}
	cutoff := time.Now().UTC().Add(-trafficRetention).Unix()
	_, _ = s.db.Exec(`DELETE FROM traffic_samples WHERE ts < ?`, cutoff)
	return nil
}

func (s *Store) ListTrafficSamples(iface string, since time.Time) ([]TrafficSample, error) {
	if iface == "" {
		iface = "gfctun"
	}
	rows, err := s.db.Query(
		`SELECT ts, iface, bytes_in, bytes_out FROM traffic_samples WHERE iface=? AND ts>=? ORDER BY ts ASC`,
		iface, since.UTC().Unix(),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TrafficSample
	for rows.Next() {
		var item TrafficSample
		var in, bout sql.NullInt64
		if err := rows.Scan(&item.TS, &item.Iface, &in, &bout); err != nil {
			return nil, err
		}
		if in.Valid {
			item.BytesIn = uint64(in.Int64)
		}
		if bout.Valid {
			item.BytesOut = uint64(bout.Int64)
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) TrafficSummary(iface string, since time.Time) (totalIn, totalOut uint64, peakIn, peakOut uint64, err error) {
	samples, err := s.ListTrafficSamples(iface, since)
	if err != nil {
		return 0, 0, 0, 0, err
	}
	for _, sample := range samples {
		totalIn += sample.BytesIn
		totalOut += sample.BytesOut
		if sample.BytesIn > peakIn {
			peakIn = sample.BytesIn
		}
		if sample.BytesOut > peakOut {
			peakOut = sample.BytesOut
		}
	}
	return totalIn, totalOut, peakIn, peakOut, nil
}

func (s *Store) ListTrafficInterfaces(since time.Time) ([]string, error) {
	rows, err := s.db.Query(
		`SELECT DISTINCT iface FROM traffic_samples WHERE ts >= ? ORDER BY iface`,
		since.UTC().Unix(),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		out = append(out, name)
	}
	return out, rows.Err()
}
