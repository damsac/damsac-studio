package main

import (
	"context"
	"embed"
	"html/template"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static/*
var staticFS embed.FS

func main() {
	cfg, err := LoadConfig()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	store, err := OpenStore(cfg.DataDir)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	defer store.Close()

	broker := NewBroker()

	// Parse templates.
	tmpl, err := template.ParseFS(templateFS,
		"templates/layout.html",
		"templates/events.html",
		"templates/event_row.html",
		"templates/event_detail.html",
	)
	if err != nil {
		log.Fatalf("templates: %v", err)
	}

	// Parse login template separately (it has its own full HTML structure).
	loginTmpl, err := template.ParseFS(templateFS, "templates/login.html")
	if err != nil {
		log.Fatalf("login template: %v", err)
	}

	// Set the package-level login template for use by renderLogin.
	loginTemplate = loginTmpl

	ingest := &IngestHandler{
		store:  store,
		broker: broker,
	}

	dashboard := &DashboardHandler{
		store:  store,
		broker: broker,
		tmpl:   tmpl,
	}

	sessions := NewSessionStore(24 * time.Hour)

	// Determine if we should set Secure flag on cookies.
	// In dev (no HTTPS), we skip Secure so cookies work on localhost.
	isSecure := os.Getenv("DASHBOARD_SECURE_COOKIE") == "true"

	mux := http.NewServeMux()

	// Health endpoint -- unauthenticated.
	mux.HandleFunc("/v1/health", handleHealth)

	// Ingest endpoint -- protected by API key middleware.
	authMiddleware := APIKeyAuth(cfg.APIKeys)
	mux.Handle("/v1/events", authMiddleware(ingest))

	// Static files -- unauthenticated (CSS, JS).
	staticSub, err := fs.Sub(staticFS, "static")
	if err != nil {
		log.Fatalf("static fs: %v", err)
	}
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.FS(staticSub))))

	// Dashboard login/logout -- unauthenticated.
	mux.HandleFunc("/dashboard/login", HandleLogin(sessions, cfg.DashboardPasswordFile, isSecure))
	mux.HandleFunc("/dashboard/logout", HandleLogout(sessions))

	// Dashboard routes -- protected by session auth.
	dashAuth := DashboardAuth(sessions)
	mux.Handle("/dashboard/events/stream", dashAuth(http.HandlerFunc(dashboard.HandleEventsStream)))
	mux.Handle("/dashboard/events/", dashAuth(http.HandlerFunc(dashboard.HandleEventDetail)))
	mux.Handle("/dashboard/events", dashAuth(http.HandlerFunc(dashboard.HandleEventsPartial)))
	mux.Handle("/dashboard", dashAuth(http.HandlerFunc(dashboard.HandleDashboard)))

	// Redirect bare /dashboard/ to /dashboard.
	mux.HandleFunc("/dashboard/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		if path == "/dashboard/" {
			http.Redirect(w, r, "/dashboard", http.StatusMovedPermanently)
			return
		}
		// For any other /dashboard/... path not matched above, check auth and 404.
		if strings.HasPrefix(path, "/dashboard/") {
			cookie, err := r.Cookie(sessionCookieName)
			if err != nil || !sessions.Valid(cookie.Value) {
				http.Redirect(w, r, "/dashboard/login", http.StatusSeeOther)
				return
			}
			http.NotFound(w, r)
		}
	})

	srv := &http.Server{
		Addr:         net.JoinHostPort("", cfg.Port),
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0, // disabled: SSE needs long-lived connections; keepalives sent in handler
		IdleTimeout:  60 * time.Second,
	}

	// Start server in a goroutine.
	go func() {
		log.Printf("listening on :%s (data_dir=%s)", cfg.Port, cfg.DataDir)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	// Wait for interrupt signal.
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	sig := <-quit
	log.Printf("received %s, shutting down...", sig)

	// Graceful shutdown with 10-second timeout.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("shutdown: %v", err)
	}

	log.Println("server stopped")
}
