package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/google/uuid"
)

// handleHealth responds with a simple health check.
//
//	GET /v1/health -> {"status":"ok"}
func handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

// maxBodySize is the maximum allowed request body size (1 MB).
const maxBodySize = 1 << 20

// maxBatchSize is the maximum number of events per batch.
const maxBatchSize = 100

// ingestRequest is the expected JSON payload for POST /v1/events.
type ingestRequest struct {
	Events []ingestEvent `json:"events"`
}

// ingestEvent is a single event in the ingest batch.
type ingestEvent struct {
	ID         string          `json:"id"`
	AppID      string          `json:"app_id"`
	EventName  string          `json:"event"`
	Timestamp  string          `json:"timestamp"`
	Properties json.RawMessage `json:"properties"`
	Context    json.RawMessage `json:"context"`
}

// IngestHandler holds dependencies for the event ingest endpoint.
type IngestHandler struct {
	store  *Store
	broker *Broker
}

// ServeHTTP handles POST /v1/events.
func (h *IngestHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Enforce body size limit.
	r.Body = http.MaxBytesReader(w, r.Body, maxBodySize)

	body, err := io.ReadAll(r.Body)
	if err != nil {
		// MaxBytesReader returns a specific error when the limit is exceeded.
		writeError(w, http.StatusRequestEntityTooLarge, "request body exceeds 1MB limit", "PAYLOAD_TOO_LARGE")
		return
	}

	var req ingestRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body", "VALIDATION_ERROR")
		return
	}

	if len(req.Events) == 0 {
		writeError(w, http.StatusBadRequest, "events array is empty", "VALIDATION_ERROR")
		return
	}

	if len(req.Events) > maxBatchSize {
		writeError(w, http.StatusRequestEntityTooLarge,
			fmt.Sprintf("batch exceeds maximum of %d events", maxBatchSize), "PAYLOAD_TOO_LARGE")
		return
	}

	// Retrieve the authenticated app_id from the auth middleware.
	authedAppID := AppIDFromContext(r.Context())

	events := make([]Event, 0, len(req.Events))
	for i, e := range req.Events {
		// Validate required field: event name.
		if e.EventName == "" {
			writeError(w, http.StatusBadRequest,
				fmt.Sprintf("events[%d]: missing required field 'event'", i), "VALIDATION_ERROR")
			return
		}

		// Validate required field: timestamp (must be valid RFC3339).
		if e.Timestamp == "" {
			writeError(w, http.StatusBadRequest,
				fmt.Sprintf("events[%d]: missing required field 'timestamp'", i), "VALIDATION_ERROR")
			return
		}
		if _, err := time.Parse(time.RFC3339, e.Timestamp); err != nil {
			writeError(w, http.StatusBadRequest,
				fmt.Sprintf("events[%d]: invalid timestamp (must be RFC3339)", i), "VALIDATION_ERROR")
			return
		}

		// Validate app_id matches the API key's app_id.
		if e.AppID != "" && e.AppID != authedAppID {
			writeError(w, http.StatusForbidden,
				fmt.Sprintf("events[%d]: app_id %q does not match API key", i, e.AppID),
				"FORBIDDEN")
			return
		}

		// Generate UUID if not provided.
		id := e.ID
		if id == "" {
			id = uuid.New().String()
		}

		// Default app_id to the authenticated one.
		appID := e.AppID
		if appID == "" {
			appID = authedAppID
		}

		// Validate and default properties JSON.
		props := "{}"
		if len(e.Properties) > 0 {
			if !json.Valid(e.Properties) {
				writeError(w, http.StatusBadRequest,
					fmt.Sprintf("events[%d]: properties is not valid JSON", i), "VALIDATION_ERROR")
				return
			}
			props = string(e.Properties)
		}

		// Validate and default context JSON.
		ctx := "{}"
		if len(e.Context) > 0 {
			if !json.Valid(e.Context) {
				writeError(w, http.StatusBadRequest,
					fmt.Sprintf("events[%d]: context is not valid JSON", i), "VALIDATION_ERROR")
				return
			}
			ctx = string(e.Context)
		}

		events = append(events, Event{
			ID:         id,
			AppID:      appID,
			EventName:  e.EventName,
			Timestamp:  e.Timestamp,
			Properties: props,
			Context:    ctx,
		})
	}

	inserted, err := h.store.InsertEvents(events)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to store events", "INTERNAL_ERROR")
		return
	}

	// Broadcast to SSE subscribers after successful insert.
	if h.broker != nil && len(events) > 0 {
		h.broker.Broadcast(events)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	json.NewEncoder(w).Encode(map[string]int64{"accepted": inserted})
}
