package main

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"sync"

	_ "modernc.org/sqlite"
)

// Store wraps a SQLite database for event storage.
type Store struct {
	db *sql.DB
	mu sync.Mutex // serializes writes to avoid SQLITE_BUSY
}

// OpenStore opens (or creates) the SQLite database at the configured path
// inside dataDir, sets pragmas, and ensures the schema exists.
func OpenStore(dataDir string) (*Store, error) {
	dbPath := filepath.Join(dataDir, "studio.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}

	// Force a single-connection pool so that pragmas are applied to every
	// query. This is fine for the expected single-app analytics volume.
	db.SetMaxOpenConns(1)

	// Verify connectivity.
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}

	// Set pragmas on the connection.
	pragmas := []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA busy_timeout=5000",
		"PRAGMA synchronous=NORMAL",
		"PRAGMA foreign_keys=ON",
	}
	for _, p := range pragmas {
		if _, err := db.Exec(p); err != nil {
			db.Close()
			return nil, fmt.Errorf("set pragma %s: %w", p, err)
		}
	}

	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}

	return s, nil
}

// migrate creates the events table and indexes if they don't already exist.
func (s *Store) migrate() error {
	const schema = `
CREATE TABLE IF NOT EXISTS events (
    id         TEXT PRIMARY KEY,
    app_id     TEXT NOT NULL,
    event      TEXT NOT NULL,
    timestamp  TEXT NOT NULL,
    properties TEXT DEFAULT '{}',
    context    TEXT DEFAULT '{}',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_events_time  ON events (timestamp);
CREATE INDEX IF NOT EXISTS idx_events_app   ON events (app_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_events_event ON events (event, timestamp);
`
	s.mu.Lock()
	defer s.mu.Unlock()

	_, err := s.db.Exec(schema)
	return err
}

// Event represents a single analytics event for insertion.
type Event struct {
	ID         string
	AppID      string
	EventName  string
	Timestamp  string
	Properties string // validated JSON
	Context    string // validated JSON
}

// StoredEvent is an event as read from the database, including the server-generated created_at.
type StoredEvent struct {
	ID         string
	AppID      string
	EventName  string
	Timestamp  string
	Properties string
	Context    string
	CreatedAt  string
}

// InsertEvents inserts a batch of events in a single transaction.
// Duplicate IDs are silently ignored (INSERT OR IGNORE).
func (s *Store) InsertEvents(events []Event) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	tx, err := s.db.Begin()
	if err != nil {
		return 0, fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
		INSERT OR IGNORE INTO events (id, app_id, event, timestamp, properties, context)
		VALUES (?, ?, ?, ?, ?, ?)
	`)
	if err != nil {
		return 0, fmt.Errorf("prepare statement: %w", err)
	}
	defer stmt.Close()

	var inserted int64
	for _, e := range events {
		res, err := stmt.Exec(e.ID, e.AppID, e.EventName, e.Timestamp, e.Properties, e.Context)
		if err != nil {
			return inserted, fmt.Errorf("insert event %s: %w", e.ID, err)
		}
		n, _ := res.RowsAffected()
		inserted += n
	}

	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit transaction: %w", err)
	}

	return inserted, nil
}

// EventFilters holds the filter parameters for querying events.
type EventFilters struct {
	AppID     string
	EventType string
	From      string // RFC3339
	To        string // RFC3339
	Search    string // free-text search across properties, context, event, app_id
}

// QueryEvents returns events matching the given filters, paginated.
// Results are ordered newest first.
func (s *Store) QueryEvents(filters EventFilters, page, pageSize int) ([]StoredEvent, error) {
	var clauses []string
	var args []interface{}

	if filters.AppID != "" {
		clauses = append(clauses, "app_id = ?")
		args = append(args, filters.AppID)
	}
	if filters.EventType != "" {
		clauses = append(clauses, "event = ?")
		args = append(args, filters.EventType)
	}
	if filters.From != "" {
		clauses = append(clauses, "timestamp >= ?")
		args = append(args, filters.From)
	}
	if filters.To != "" {
		clauses = append(clauses, "timestamp <= ?")
		args = append(args, filters.To)
	}
	if filters.Search != "" {
		like := "%" + filters.Search + "%"
		clauses = append(clauses, "(properties LIKE ? OR context LIKE ? OR event LIKE ? OR app_id LIKE ? OR id LIKE ?)")
		args = append(args, like, like, like, like, like)
	}

	query := "SELECT id, app_id, event, timestamp, properties, context, created_at FROM events"
	if len(clauses) > 0 {
		query += " WHERE " + strings.Join(clauses, " AND ")
	}
	query += " ORDER BY timestamp DESC"

	offset := (page - 1) * pageSize
	query += fmt.Sprintf(" LIMIT %d OFFSET %d", pageSize, offset)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("query events: %w", err)
	}
	defer rows.Close()

	var events []StoredEvent
	for rows.Next() {
		var e StoredEvent
		if err := rows.Scan(&e.ID, &e.AppID, &e.EventName, &e.Timestamp,
			&e.Properties, &e.Context, &e.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan event: %w", err)
		}
		events = append(events, e)
	}
	return events, rows.Err()
}

// CountEvents returns the total number of events matching the given filters.
func (s *Store) CountEvents(filters EventFilters) (int, error) {
	var clauses []string
	var args []interface{}

	if filters.AppID != "" {
		clauses = append(clauses, "app_id = ?")
		args = append(args, filters.AppID)
	}
	if filters.EventType != "" {
		clauses = append(clauses, "event = ?")
		args = append(args, filters.EventType)
	}
	if filters.From != "" {
		clauses = append(clauses, "timestamp >= ?")
		args = append(args, filters.From)
	}
	if filters.To != "" {
		clauses = append(clauses, "timestamp <= ?")
		args = append(args, filters.To)
	}
	if filters.Search != "" {
		like := "%" + filters.Search + "%"
		clauses = append(clauses, "(properties LIKE ? OR context LIKE ? OR event LIKE ? OR app_id LIKE ? OR id LIKE ?)")
		args = append(args, like, like, like, like, like)
	}

	query := "SELECT COUNT(*) FROM events"
	if len(clauses) > 0 {
		query += " WHERE " + strings.Join(clauses, " AND ")
	}

	var count int
	err := s.db.QueryRow(query, args...).Scan(&count)
	return count, err
}

// GetEvent returns a single event by ID.
func (s *Store) GetEvent(id string) (*StoredEvent, error) {
	var e StoredEvent
	err := s.db.QueryRow(
		"SELECT id, app_id, event, timestamp, properties, context, created_at FROM events WHERE id = ?",
		id,
	).Scan(&e.ID, &e.AppID, &e.EventName, &e.Timestamp, &e.Properties, &e.Context, &e.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get event: %w", err)
	}
	return &e, nil
}

// GetDistinctAppIDs returns all unique app_id values in the events table.
func (s *Store) GetDistinctAppIDs() ([]string, error) {
	rows, err := s.db.Query("SELECT DISTINCT app_id FROM events ORDER BY app_id")
	if err != nil {
		return nil, fmt.Errorf("distinct app_ids: %w", err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// GetDistinctEventTypes returns all unique event type values in the events table.
func (s *Store) GetDistinctEventTypes() ([]string, error) {
	rows, err := s.db.Query("SELECT DISTINCT event FROM events ORDER BY event")
	if err != nil {
		return nil, fmt.Errorf("distinct event types: %w", err)
	}
	defer rows.Close()

	var types []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		types = append(types, t)
	}
	return types, rows.Err()
}

// GetTotalLLMCostMicros returns the sum of cost_micros from all llm.request events.
func (s *Store) GetTotalLLMCostMicros() (int64, error) {
	var cost int64
	err := s.db.QueryRow(`
		SELECT COALESCE(SUM(CAST(json_extract(properties, '$.cost_micros') AS INTEGER)), 0)
		FROM events WHERE event = 'llm.request'
	`).Scan(&cost)
	return cost, err
}

// GetTotalUniqueDevices returns the count of distinct device_id values across all events.
func (s *Store) GetTotalUniqueDevices() (int, error) {
	var count int
	err := s.db.QueryRow(`
		SELECT COUNT(DISTINCT json_extract(context, '$.device_id'))
		FROM events
		WHERE json_extract(context, '$.device_id') IS NOT NULL
		  AND json_extract(context, '$.device_id') != ''
	`).Scan(&count)
	return count, err
}

// TokensByDayHour returns a map of (day_of_week, hour) -> total tokens for llm.request events.
func (s *Store) TokensByDayHour() (map[[2]int]int64, error) {
	rows, err := s.db.Query(`
		SELECT
			CAST(strftime('%w', timestamp) AS INTEGER),
			CAST(strftime('%H', timestamp) AS INTEGER),
			COALESCE(SUM(
				COALESCE(CAST(json_extract(properties, '$.tokens_in') AS INTEGER), 0) +
				COALESCE(CAST(json_extract(properties, '$.tokens_out') AS INTEGER), 0)
			), 0)
		FROM events
		WHERE event = 'llm.request'
		GROUP BY 1, 2
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	result := make(map[[2]int]int64)
	for rows.Next() {
		var dow, hour int
		var tokens int64
		if err := rows.Scan(&dow, &hour, &tokens); err != nil {
			return nil, err
		}
		result[[2]int{dow, hour}] = tokens
	}
	return result, rows.Err()
}

// Close closes the underlying database connection.
func (s *Store) Close() error {
	return s.db.Close()
}
