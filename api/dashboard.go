package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const eventsPerPage = 50

// DashboardHandler holds dependencies for all dashboard routes.
type DashboardHandler struct {
	store  *Store
	broker *Broker
	tmpl   *template.Template
}

// eventView is the template-friendly representation of a stored event.
type eventView struct {
	ID                string
	AppID             string
	EventName         string
	Timestamp         string
	Properties        string
	Context           string
	CreatedAt         string
	FormattedTime     string
	PropertiesPreview string
	PropertiesFormatted string
	ContextFormatted    string
}

func newEventView(e StoredEvent) eventView {
	return eventView{
		ID:                  e.ID,
		AppID:               e.AppID,
		EventName:           e.EventName,
		Timestamp:           e.Timestamp,
		Properties:          e.Properties,
		Context:             e.Context,
		CreatedAt:           e.CreatedAt,
		FormattedTime:       formatTimestamp(e.Timestamp),
		PropertiesPreview:   truncate(flatJSON(e.Properties), 80),
		PropertiesFormatted: prettyJSON(e.Properties),
		ContextFormatted:    prettyJSON(e.Context),
	}
}

func newEventViewFromEvent(e Event) eventView {
	return eventView{
		ID:                  e.ID,
		AppID:               e.AppID,
		EventName:           e.EventName,
		Timestamp:           e.Timestamp,
		Properties:          e.Properties,
		Context:             e.Context,
		FormattedTime:       formatTimestamp(e.Timestamp),
		PropertiesPreview:   truncate(flatJSON(e.Properties), 80),
		PropertiesFormatted: prettyJSON(e.Properties),
		ContextFormatted:    prettyJSON(e.Context),
	}
}

// eventsPageData is the data passed to the events.html template.
type eventsPageData struct {
	Events      []eventView
	AppIDs      []string
	EventTypes  []string
	ActiveAppID string
	ActiveEvent string
	ActiveFrom  string
	ActiveTo    string
	Page        int
	PrevPage    int
	NextPage    int
	HasMore     bool
	FilterQuery string
}

// HandleDashboard serves the main dashboard page.
func (d *DashboardHandler) HandleDashboard(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Parse filter params.
	filters, page := d.parseFilters(r)

	events, err := d.store.QueryEvents(filters, page, eventsPerPage+1)
	if err != nil {
		http.Error(w, "failed to query events", http.StatusInternalServerError)
		log.Printf("dashboard: query events: %v", err)
		return
	}

	hasMore := len(events) > eventsPerPage
	if hasMore {
		events = events[:eventsPerPage]
	}

	appIDs, _ := d.store.GetDistinctAppIDs()
	eventTypes, _ := d.store.GetDistinctEventTypes()

	views := make([]eventView, len(events))
	for i, e := range events {
		views[i] = newEventView(e)
	}

	data := eventsPageData{
		Events:      views,
		AppIDs:      appIDs,
		EventTypes:  eventTypes,
		ActiveAppID: filters.AppID,
		ActiveEvent: filters.EventType,
		ActiveFrom:  r.URL.Query().Get("from"),
		ActiveTo:    r.URL.Query().Get("to"),
		Page:        page,
		PrevPage:    page - 1,
		NextPage:    page + 1,
		HasMore:     hasMore,
		FilterQuery: d.filterQueryString(filters),
	}

	d.render(w, "layout.html", data)
}

// HandleEventsPartial serves the htmx partial for the events table.
func (d *DashboardHandler) HandleEventsPartial(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	filters, page := d.parseFilters(r)

	events, err := d.store.QueryEvents(filters, page, eventsPerPage+1)
	if err != nil {
		http.Error(w, "failed to query events", http.StatusInternalServerError)
		log.Printf("dashboard: query events: %v", err)
		return
	}

	hasMore := len(events) > eventsPerPage
	if hasMore {
		events = events[:eventsPerPage]
	}

	views := make([]eventView, len(events))
	for i, e := range events {
		views[i] = newEventView(e)
	}

	data := eventsPageData{
		Events:      views,
		Page:        page,
		PrevPage:    page - 1,
		NextPage:    page + 1,
		HasMore:     hasMore,
		FilterQuery: d.filterQueryString(filters),
	}

	d.renderPartial(w, "events_table", data)
}

// HandleEventDetail serves the htmx partial for a single event's detail.
func (d *DashboardHandler) HandleEventDetail(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Extract event ID from path: /dashboard/events/{id}
	id := strings.TrimPrefix(r.URL.Path, "/dashboard/events/")
	if id == "" || id == "stream" {
		http.NotFound(w, r)
		return
	}

	event, err := d.store.GetEvent(id)
	if err != nil {
		http.Error(w, "failed to get event", http.StatusInternalServerError)
		log.Printf("dashboard: get event: %v", err)
		return
	}
	if event == nil {
		http.NotFound(w, r)
		return
	}

	view := newEventView(*event)
	d.renderPartial(w, "event_detail", view)
}

// HandleEventsStream serves the SSE endpoint for real-time event updates.
func (d *DashboardHandler) HandleEventsStream(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	ch := d.broker.Subscribe()
	defer d.broker.Unsubscribe(ch)

	ctx := r.Context()
	keepalive := time.NewTicker(15 * time.Second)
	defer keepalive.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-keepalive.C:
			// Send SSE comment to keep the connection alive.
			fmt.Fprintf(w, ": keepalive\n\n")
			flusher.Flush()
		case events, ok := <-ch:
			if !ok {
				return
			}

			var buf bytes.Buffer
			for _, e := range events {
				view := newEventViewFromEvent(e)
				if err := d.tmpl.ExecuteTemplate(&buf, "event_row", view); err != nil {
					log.Printf("sse: render event_row: %v", err)
					continue
				}
			}

			// Write as SSE with the "new-events" event name that htmx listens for.
			lines := strings.Split(buf.String(), "\n")
			fmt.Fprintf(w, "event: new-events\n")
			for _, line := range lines {
				fmt.Fprintf(w, "data: %s\n", line)
			}
			fmt.Fprintf(w, "\n")
			flusher.Flush()
		}
	}
}

// parseFilters extracts filter and pagination params from the request.
func (d *DashboardHandler) parseFilters(r *http.Request) (EventFilters, int) {
	q := r.URL.Query()

	page, _ := strconv.Atoi(q.Get("page"))
	if page < 1 {
		page = 1
	}

	from := q.Get("from")
	to := q.Get("to")

	// Convert datetime-local format (2026-03-15T10:30) to RFC3339 if needed.
	if from != "" && !strings.Contains(from, "Z") && !strings.Contains(from, "+") {
		from = from + ":00Z"
	}
	if to != "" && !strings.Contains(to, "Z") && !strings.Contains(to, "+") {
		to = to + ":00Z"
	}

	return EventFilters{
		AppID:     q.Get("app_id"),
		EventType: q.Get("event"),
		From:      from,
		To:        to,
	}, page
}

// filterQueryString builds query parameters for pagination links (excludes page).
func (d *DashboardHandler) filterQueryString(f EventFilters) string {
	var parts []string
	if f.AppID != "" {
		parts = append(parts, "&app_id="+url.QueryEscape(f.AppID))
	}
	if f.EventType != "" {
		parts = append(parts, "&event="+url.QueryEscape(f.EventType))
	}
	if f.From != "" {
		parts = append(parts, "&from="+url.QueryEscape(f.From))
	}
	if f.To != "" {
		parts = append(parts, "&to="+url.QueryEscape(f.To))
	}
	return strings.Join(parts, "")
}

// render executes a full-page template.
func (d *DashboardHandler) render(w http.ResponseWriter, name string, data interface{}) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.tmpl.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("dashboard: render %s: %v", name, err)
	}
}

// renderPartial executes a named template block (htmx partial).
func (d *DashboardHandler) renderPartial(w http.ResponseWriter, name string, data interface{}) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.tmpl.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("dashboard: render partial %s: %v", name, err)
	}
}

// ---------- helpers ----------

func formatTimestamp(ts string) string {
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return ts
	}
	return t.Format("Jan 02 15:04:05")
}

func prettyJSON(raw string) string {
	var buf bytes.Buffer
	if err := json.Indent(&buf, []byte(raw), "", "  "); err != nil {
		return raw
	}
	return buf.String()
}

func flatJSON(raw string) string {
	// Compact the JSON onto one line for preview.
	var buf bytes.Buffer
	if err := json.Compact(&buf, []byte(raw)); err != nil {
		return raw
	}
	return buf.String()
}

func truncate(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + "..."
}
