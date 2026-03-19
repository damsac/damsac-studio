package main

import (
	"fmt"
	"os"
	"strings"
)

// Config holds the server configuration loaded from environment variables.
type Config struct {
	Port                  string
	DataDir               string
	APIKeys               map[string]string // key -> app_id
	DashboardPasswordFile string
}

// LoadConfig reads configuration from environment variables.
//
//	PORT                   — listen port (default "8080")
//	DATA_DIR               — directory for SQLite DB (default ".")
//	API_KEYS               — comma-separated "key:app_id" pairs
//	DASHBOARD_PASSWORD_FILE — path to file containing dashboard password
func LoadConfig() (*Config, error) {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	dataDir := os.Getenv("DATA_DIR")
	if dataDir == "" {
		dataDir = "."
	}

	apiKeys := make(map[string]string)
	raw := os.Getenv("API_KEYS")
	if raw != "" {
		for _, pair := range strings.Split(raw, ",") {
			pair = strings.TrimSpace(pair)
			if pair == "" {
				continue
			}
			parts := strings.SplitN(pair, ":", 2)
			if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
				return nil, fmt.Errorf("invalid API_KEYS entry: %q (expected key:app_id)", pair)
			}
			apiKeys[parts[0]] = parts[1]
		}
	}

	if len(apiKeys) == 0 {
		return nil, fmt.Errorf("API_KEYS is required (comma-separated key:app_id pairs)")
	}

	dashPwFile := os.Getenv("DASHBOARD_PASSWORD_FILE")
	if dashPwFile == "" {
		return nil, fmt.Errorf("DASHBOARD_PASSWORD_FILE is required")
	}

	return &Config{
		Port:                  port,
		DataDir:               dataDir,
		APIKeys:               apiKeys,
		DashboardPasswordFile: dashPwFile,
	}, nil
}
