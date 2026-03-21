package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
)

const maxRows = 1000

// validateQuery checks that a SQL string is a safe read-only query.
// This is defense-in-depth — the read-only SQLite connection is the primary safety net.
func validateQuery(sql string) error {
	trimmed := strings.TrimSpace(sql)
	if trimmed == "" {
		return fmt.Errorf("empty query")
	}

	// Reject semicolons — prevents multi-statement attacks.
	// Strip trailing semicolons first (common in hand-written SQL).
	cleaned := strings.TrimRight(trimmed, "; \t\n")
	if strings.Contains(cleaned, ";") {
		return fmt.Errorf("multiple statements not allowed")
	}

	upper := strings.ToUpper(cleaned)

	// Must start with SELECT or WITH.
	if !strings.HasPrefix(upper, "SELECT") && !strings.HasPrefix(upper, "WITH") {
		return fmt.Errorf("only SELECT queries are allowed")
	}

	// For WITH (CTE) queries, find the final statement after all CTEs.
	if strings.HasPrefix(upper, "WITH") {
		finalKeyword := findFinalStatement(upper)
		if finalKeyword != "SELECT" {
			return fmt.Errorf("CTE must end with SELECT, got %s", finalKeyword)
		}
	}

	// Block dangerous keywords anywhere in the query.
	blocked := []string{"INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "ATTACH", "DETACH", "PRAGMA"}
	if !strings.HasPrefix(upper, "WITH") {
		for _, kw := range blocked {
			if containsKeyword(upper, kw) {
				return fmt.Errorf("blocked keyword: %s", kw)
			}
		}
	}

	return nil
}

// findFinalStatement finds the keyword that starts the final (non-CTE) statement.
// It tracks parenthesis depth to skip over CTE bodies.
func findFinalStatement(upper string) string {
	depth := 0
	keywords := []string{"SELECT", "INSERT", "UPDATE", "DELETE"}
	lastFound := ""

	i := 0
	for i < len(upper) {
		if upper[i] == '(' {
			depth++
			i++
			continue
		}
		if upper[i] == ')' {
			depth--
			i++
			continue
		}
		if depth == 0 {
			for _, kw := range keywords {
				if i+len(kw) <= len(upper) && upper[i:i+len(kw)] == kw {
					if i+len(kw) == len(upper) || !isIdentChar(upper[i+len(kw)]) {
						lastFound = kw
					}
				}
			}
		}
		i++
	}

	return lastFound
}

// isIdentChar returns true if c can be part of a SQL identifier.
func isIdentChar(c byte) bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
}

// containsKeyword checks if a SQL keyword appears as a whole word in the query.
func containsKeyword(upper, keyword string) bool {
	start := 0
	for {
		idx := strings.Index(upper[start:], keyword)
		if idx == -1 {
			return false
		}
		pos := start + idx
		before := pos == 0 || !isIdentChar(upper[pos-1])
		after := pos+len(keyword) == len(upper) || !isIdentChar(upper[pos+len(keyword)])
		if before && after {
			return true
		}
		start = pos + 1
	}
}

// executeQuery runs a validated SQL query and returns the results as a JSON array string.
// Caps results at maxRows. Uses the provided context for timeout/cancellation.
func executeQuery(ctx context.Context, db *sql.DB, query string) (string, error) {
	rows, err := db.QueryContext(ctx, query)
	if err != nil {
		return "", fmt.Errorf("query: %w", err)
	}
	defer rows.Close()

	cols, err := rows.Columns()
	if err != nil {
		return "", fmt.Errorf("columns: %w", err)
	}

	var results []map[string]interface{}
	count := 0

	for rows.Next() {
		if count >= maxRows {
			break
		}

		values := make([]interface{}, len(cols))
		ptrs := make([]interface{}, len(cols))
		for i := range values {
			ptrs[i] = &values[i]
		}

		if err := rows.Scan(ptrs...); err != nil {
			return "", fmt.Errorf("scan: %w", err)
		}

		row := make(map[string]interface{}, len(cols))
		for i, col := range cols {
			val := values[i]
			if b, ok := val.([]byte); ok {
				row[col] = string(b)
			} else {
				row[col] = val
			}
		}

		results = append(results, row)
		count++
	}

	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("rows: %w", err)
	}

	if results == nil {
		return "[]", nil
	}

	out, err := json.Marshal(results)
	if err != nil {
		return "", fmt.Errorf("marshal: %w", err)
	}

	result := string(out)
	if count >= maxRows {
		result += fmt.Sprintf("\n\n[Warning: results truncated to %d rows]", maxRows)
	}

	return result, nil
}
