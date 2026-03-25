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
	ID                  string
	AppID               string
	EventName           string
	Timestamp           string
	Properties          string
	Context             string
	CreatedAt           string
	FormattedTime       string
	PropertiesPreview   string
	PropertiesFormatted string
	ContextFormatted    string
	Cost                string // formatted dollar amount, empty for non-LLM events
	CallType            string // e.g. "agent", "extraction", empty for non-LLM events
	TokensIn            string // formatted token count
	TokensOut           string // formatted token count
	Model               string // e.g. "claude-haiku-4.5"
	RequestID           string // shared request_id linking llm.request and credits.charged
	GroupPos            string // "first", "last", or "" (ungrouped)
	DeviceID            string // full device_id from context
	DeviceIDShort       string // first 8 chars for display
}

func newEventView(e StoredEvent) eventView {
	v := eventView{
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
	extractPropsFields(&v, e.Properties)
	extractContextFields(&v, e.Context)
	return v
}

func newEventViewFromEvent(e Event) eventView {
	v := eventView{
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
	extractPropsFields(&v, e.Properties)
	extractContextFields(&v, e.Context)
	return v
}

// extractPropsFields parses display fields from properties JSON into the view.
func extractPropsFields(v *eventView, propsJSON string) {
	var props struct {
		CostMicros *int64  `json:"cost_micros"`
		CallType   *string `json:"call_type"`
		TokensIn   *int64  `json:"tokens_in"`
		TokensOut  *int64  `json:"tokens_out"`
		Model      *string `json:"model"`
		RequestID  *string `json:"request_id"`
	}
	if json.Unmarshal([]byte(propsJSON), &props) != nil {
		return
	}
	if props.CostMicros != nil {
		v.Cost = formatCost(*props.CostMicros)
	}
	if props.CallType != nil {
		v.CallType = *props.CallType
	}
	if props.TokensIn != nil {
		v.TokensIn = formatInt(*props.TokensIn)
	}
	if props.TokensOut != nil {
		v.TokensOut = formatInt(*props.TokensOut)
	}
	if props.Model != nil {
		// Strip provider prefix (e.g. "anthropic/claude-haiku-4.5" -> "claude-haiku-4.5")
		m := *props.Model
		if idx := strings.LastIndex(m, "/"); idx >= 0 {
			m = m[idx+1:]
		}
		v.Model = m
	}
	if props.RequestID != nil {
		v.RequestID = *props.RequestID
	}
}

// extractContextFields parses device_id from context JSON into the view.
func extractContextFields(v *eventView, ctxJSON string) {
	var ctx struct {
		DeviceID *string `json:"device_id"`
	}
	if json.Unmarshal([]byte(ctxJSON), &ctx) != nil {
		return
	}
	if ctx.DeviceID != nil && *ctx.DeviceID != "" {
		v.DeviceID = *ctx.DeviceID
		if len(*ctx.DeviceID) > 8 {
			v.DeviceIDShort = (*ctx.DeviceID)[:8]
		} else {
			v.DeviceIDShort = *ctx.DeviceID
		}
	}
}

// applyGrouping clusters events that share a request_id so they are adjacent,
// then marks them with GroupPos ("first"/"last") for visual styling.
func applyGrouping(views []eventView) {
	// Build map of request_id -> list of indices (in current order).
	groups := make(map[string][]int)
	for i := range views {
		if views[i].RequestID != "" {
			groups[views[i].RequestID] = append(groups[views[i].RequestID], i)
		}
	}

	// Collect request_ids that actually form groups (2+ events).
	type groupInfo struct {
		requestID string
		first     int // index of first member in original order
	}
	var toCluster []groupInfo
	for rid, indices := range groups {
		if len(indices) >= 2 {
			toCluster = append(toCluster, groupInfo{rid, indices[0]})
		}
	}

	// For each group, ensure members are adjacent: pull later members
	// to right after the first member.
	for _, g := range toCluster {
		indices := groups[g.requestID]
		anchor := -1
		// Find current position of the first member.
		for i, v := range views {
			if v.RequestID == g.requestID {
				anchor = i
				break
			}
		}
		if anchor < 0 {
			continue
		}
		// Move other group members right after the anchor.
		insertAt := anchor + 1
		for pass := 0; pass < len(indices)-1; pass++ {
			for i := insertAt + 1; i < len(views); i++ {
				if views[i].RequestID == g.requestID {
					// Shift element at i to insertAt.
					v := views[i]
					copy(views[insertAt+1:i+1], views[insertAt:i])
					views[insertAt] = v
					insertAt++
					break
				}
			}
		}
	}

	// Now mark positions within each group.
	i := 0
	for i < len(views) {
		if views[i].RequestID == "" {
			i++
			continue
		}
		rid := views[i].RequestID
		start := i
		for i < len(views) && views[i].RequestID == rid {
			i++
		}
		if i-start < 2 {
			continue
		}
		views[start].GroupPos = "first"
		for j := start + 1; j < i-1; j++ {
			views[j].GroupPos = "mid"
		}
		views[i-1].GroupPos = "last"
	}
}

// DashboardMetrics holds aggregate metrics for the top of the dashboard.
type DashboardMetrics struct {
	TotalCost  string
	TotalUsers int
	Heatmap    []HeatmapRow
	Engagement EngagementMetrics
}

// EngagementMetrics holds Murmur entry engagement data.
type EngagementMetrics struct {
	EntryViews     int
	EntryEdits     int
	AvgTimeToEdit  string // human-readable duration
	UniqueEntries  int
	TopCategories  []CategoryCount
}

// HeatmapRow is one row (day) in the token usage heatmap.
type HeatmapRow struct {
	Day   string
	Cells []HeatmapCell
}

// HeatmapCell is a single hour bucket in the heatmap.
type HeatmapCell struct {
	Tokens  int64
	Color   template.CSS
	Tooltip string
}

// eventsPageData is the data passed to the events.html template.
type eventsPageData struct {
	Metrics      DashboardMetrics
	Events       []eventView
	AppIDs       []string
	EventTypes   []string
	ActiveAppID         string
	ActiveEvent         string
	ActiveDeviceID      string
	ActiveDeviceIDShort string
	Page                int
	PrevPage     int
	NextPage     int
	HasMore      bool
	TotalCount   int
	FilterQuery  string
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
	metrics := d.buildMetrics()
	totalCount, _ := d.store.CountEvents(filters)

	views := make([]eventView, len(events))
	for i, e := range events {
		views[i] = newEventView(e)
	}
	applyGrouping(views)

	data := eventsPageData{
		Metrics:      metrics,
		Events:       views,
		AppIDs:       appIDs,
		EventTypes:   eventTypes,
		ActiveAppID:         filters.AppID,
		ActiveEvent:         filters.EventType,
		ActiveDeviceID:      filters.DeviceID,
		ActiveDeviceIDShort: truncate(filters.DeviceID, 8),
		Page:         page,
		PrevPage:     page - 1,
		NextPage:     page + 1,
		HasMore:      hasMore,
		TotalCount:   totalCount,
		FilterQuery:  d.filterQueryString(filters),
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

	totalCount, _ := d.store.CountEvents(filters)

	views := make([]eventView, len(events))
	for i, e := range events {
		views[i] = newEventView(e)
	}
	applyGrouping(views)

	data := eventsPageData{
		Events:             views,
		ActiveAppID:         filters.AppID,
		ActiveEvent:         filters.EventType,
		ActiveDeviceID:      filters.DeviceID,
		ActiveDeviceIDShort: truncate(filters.DeviceID, 8),

		Page:         page,
		PrevPage:     page - 1,
		NextPage:     page + 1,
		HasMore:      hasMore,
		TotalCount:   totalCount,
		FilterQuery:  d.filterQueryString(filters),
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
				if err := d.getTemplate().ExecuteTemplate(&buf, "event_row", view); err != nil {
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

	return EventFilters{
		AppID:     q.Get("app_id"),
		EventType: q.Get("event"),
		DeviceID:  q.Get("device_id"),
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
	if f.DeviceID != "" {
		parts = append(parts, "&device_id="+url.QueryEscape(f.DeviceID))
	}
	return strings.Join(parts, "")
}

// getTemplate returns the dashboard template, re-parsing from disk in dev mode.
func (d *DashboardHandler) getTemplate() *template.Template {
	if devMode {
		t, err := template.ParseFiles(
			"templates/layout.html",
			"templates/events.html",
			"templates/event_row.html",
			"templates/event_detail.html",
		)
		if err != nil {
			log.Printf("dashboard: dev parse templates: %v", err)
			return d.tmpl
		}
		return t
	}
	return d.tmpl
}

// render executes a full-page template.
func (d *DashboardHandler) render(w http.ResponseWriter, name string, data interface{}) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.getTemplate().ExecuteTemplate(w, name, data); err != nil {
		log.Printf("dashboard: render %s: %v", name, err)
	}
}

// renderPartial executes a named template block (htmx partial).
func (d *DashboardHandler) renderPartial(w http.ResponseWriter, name string, data interface{}) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := d.getTemplate().ExecuteTemplate(w, name, data); err != nil {
		log.Printf("dashboard: render partial %s: %v", name, err)
	}
}

// buildMetrics fetches aggregate metrics for the dashboard header.
func (d *DashboardHandler) buildMetrics() DashboardMetrics {
	costMicros, err := d.store.GetTotalLLMCostMicros()
	if err != nil {
		log.Printf("dashboard: metrics cost: %v", err)
	}

	users, err := d.store.GetTotalUniqueDevices()
	if err != nil {
		log.Printf("dashboard: metrics users: %v", err)
	}

	tokenData, err := d.store.TokensByDayHour()
	if err != nil {
		log.Printf("dashboard: metrics heatmap: %v", err)
	}

	return DashboardMetrics{
		TotalCost:  formatCost(costMicros),
		TotalUsers: users,
		Heatmap:    buildHeatmap(tokenData),
		Engagement: d.buildEngagementMetrics(),
	}
}

// buildEngagementMetrics fetches Murmur entry engagement data.
func (d *DashboardHandler) buildEngagementMetrics() EngagementMetrics {
	views, err := d.store.GetEntryViewCount()
	if err != nil {
		log.Printf("dashboard: engagement views: %v", err)
	}

	edits, err := d.store.GetEntryEditCount()
	if err != nil {
		log.Printf("dashboard: engagement edits: %v", err)
	}

	avgMs, err := d.store.GetAvgTimeToEditMs()
	if err != nil {
		log.Printf("dashboard: engagement avg edit time: %v", err)
	}

	unique, err := d.store.GetUniqueEntriesEngaged()
	if err != nil {
		log.Printf("dashboard: engagement unique entries: %v", err)
	}

	categories, err := d.store.GetTopCategories(5)
	if err != nil {
		log.Printf("dashboard: engagement categories: %v", err)
	}

	return EngagementMetrics{
		EntryViews:    views,
		EntryEdits:    edits,
		AvgTimeToEdit: formatDurationMs(avgMs),
		UniqueEntries: unique,
		TopCategories: categories,
	}
}

// ---------- helpers ----------

func formatTimestamp(ts string) string {
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		t, err = time.Parse(time.RFC3339Nano, ts)
		if err != nil {
			return ts
		}
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

func formatInt(n int64) string {
	s := strconv.FormatInt(n, 10)
	// Insert commas for thousands separators.
	if len(s) <= 3 {
		return s
	}
	var result []byte
	for i, c := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			result = append(result, ',')
		}
		result = append(result, byte(c))
	}
	return string(result)
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

func formatDurationMs(ms int64) string {
	if ms == 0 {
		return "--"
	}
	d := time.Duration(ms) * time.Millisecond
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		h := int(d.Hours())
		m := int(d.Minutes()) % 60
		if m == 0 {
			return fmt.Sprintf("%dh", h)
		}
		return fmt.Sprintf("%dh %dm", h, m)
	default:
		days := int(d.Hours()) / 24
		h := int(d.Hours()) % 24
		if h == 0 {
			return fmt.Sprintf("%dd", days)
		}
		return fmt.Sprintf("%dd %dh", days, h)
	}
}

func formatCost(micros int64) string {
	dollars := float64(micros) / 1_000_000.0
	if dollars >= 0.01 || micros == 0 {
		return fmt.Sprintf("$%.2f", dollars)
	}
	return fmt.Sprintf("$%.4f", dollars)
}

func buildHeatmap(data map[[2]int]int64) []HeatmapRow {
	if data == nil {
		data = make(map[[2]int]int64)
	}

	days := []string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
	// SQLite strftime('%w'): 0=Sun, 1=Mon, ..., 6=Sat
	dowMap := []int{1, 2, 3, 4, 5, 6, 0}

	var maxVal int64
	for _, v := range data {
		if v > maxVal {
			maxVal = v
		}
	}

	rows := make([]HeatmapRow, 7)
	for i, day := range days {
		dow := dowMap[i]
		cells := make([]HeatmapCell, 24)
		for h := 0; h < 24; h++ {
			tokens := data[[2]int{dow, h}]
			cells[h] = HeatmapCell{
				Tokens:  tokens,
				Color:   template.CSS(heatmapColor(tokens, maxVal)),
				Tooltip: fmt.Sprintf("%s %02d:00 – %d tokens", day, h, tokens),
			}
		}
		rows[i] = HeatmapRow{Day: day, Cells: cells}
	}
	return rows
}

func heatmapColor(value, maxValue int64) string {
	if value == 0 {
		return "rgba(88,166,255,0.04)"
	}
	ratio := float64(value) / float64(maxValue)
	// 4 discrete levels using accent color at varying opacity
	switch {
	case ratio <= 0.25:
		return "rgba(88,166,255,0.2)"
	case ratio <= 0.50:
		return "rgba(88,166,255,0.4)"
	case ratio <= 0.75:
		return "rgba(88,166,255,0.65)"
	default:
		return "rgba(88,166,255,0.95)"
	}
}
