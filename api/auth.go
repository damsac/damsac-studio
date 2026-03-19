package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"html/template"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// contextKey is an unexported type for context keys in this package.
type contextKey string

const appIDKey contextKey = "app_id"

// AppIDFromContext retrieves the authenticated app_id from the request context.
// Returns empty string if not set.
func AppIDFromContext(ctx context.Context) string {
	v, _ := ctx.Value(appIDKey).(string)
	return v
}

// APIKeyAuth returns middleware that validates the X-API-Key header against
// the configured key:app_id map. On success the matched app_id is added to the
// request context. On failure the request is rejected with 401.
func APIKeyAuth(keys map[string]string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			key := r.Header.Get("X-API-Key")
			if key == "" {
				writeError(w, http.StatusUnauthorized, "missing API key", "UNAUTHORIZED")
				return
			}

			appID := matchAPIKey(keys, key)
			if appID == "" {
				writeError(w, http.StatusUnauthorized, "invalid API key", "UNAUTHORIZED")
				return
			}

			ctx := context.WithValue(r.Context(), appIDKey, appID)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// matchAPIKey performs a constant-time comparison of the provided key against
// all configured keys. It always compares against every entry to avoid timing
// side channels that reveal which keys exist.
func matchAPIKey(keys map[string]string, provided string) string {
	var matched string
	providedBytes := []byte(provided)

	for k, appID := range keys {
		keyBytes := []byte(k)
		if subtle.ConstantTimeCompare(keyBytes, providedBytes) == 1 {
			matched = appID
		}
	}

	return matched
}

// writeError sends a JSON error response with the specified status code.
func writeError(w http.ResponseWriter, status int, message, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{
		"error": message,
		"code":  code,
	})
}

// ---------- Dashboard session auth ----------

// session holds data for a single authenticated dashboard session.
type session struct {
	createdAt time.Time
}

// SessionStore manages in-memory dashboard sessions.
type SessionStore struct {
	mu       sync.RWMutex
	sessions map[string]session // token -> session
	ttl      time.Duration
}

// NewSessionStore creates a session store with the given TTL.
func NewSessionStore(ttl time.Duration) *SessionStore {
	return &SessionStore{
		sessions: make(map[string]session),
		ttl:      ttl,
	}
}

// Create generates a new session token and stores it.
func (s *SessionStore) Create() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	token := hex.EncodeToString(b)

	s.mu.Lock()
	s.sessions[token] = session{createdAt: time.Now()}
	s.mu.Unlock()

	return token, nil
}

// Valid checks whether a token corresponds to a non-expired session.
func (s *SessionStore) Valid(token string) bool {
	s.mu.RLock()
	sess, ok := s.sessions[token]
	s.mu.RUnlock()
	if !ok {
		return false
	}
	return time.Since(sess.createdAt) < s.ttl
}

// Delete removes a session.
func (s *SessionStore) Delete(token string) {
	s.mu.Lock()
	delete(s.sessions, token)
	s.mu.Unlock()
}

const sessionCookieName = "damsac_session"

// loginTemplate is set by main() after parsing templates.
var loginTemplate *template.Template

// renderLogin renders the login page with an optional error message.
func renderLogin(w http.ResponseWriter, errMsg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	data := struct{ Error string }{Error: errMsg}
	if loginTemplate != nil {
		loginTemplate.Execute(w, data)
	} else {
		http.Error(w, "login template not loaded", http.StatusInternalServerError)
	}
}

// ReadDashboardPassword reads and trims the password from the configured file.
func ReadDashboardPassword(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(data)), nil
}

// DashboardAuth returns middleware that checks for a valid session cookie.
// If the session is invalid or missing, the user is redirected to the login page.
func DashboardAuth(sessions *SessionStore) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			cookie, err := r.Cookie(sessionCookieName)
			if err != nil || !sessions.Valid(cookie.Value) {
				http.Redirect(w, r, "/dashboard/login", http.StatusSeeOther)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// HandleLogin renders the login form (GET) or processes login (POST).
func HandleLogin(sessions *SessionStore, passwordFile string, isSecure bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			renderLogin(w, "")
		case http.MethodPost:
			r.ParseForm()
			submitted := r.FormValue("password")

			password, err := ReadDashboardPassword(passwordFile)
			if err != nil {
				renderLogin(w, "server configuration error")
				return
			}

			// Constant-time compare.
			if subtle.ConstantTimeCompare([]byte(submitted), []byte(password)) != 1 {
				renderLogin(w, "invalid password")
				return
			}

			token, err := sessions.Create()
			if err != nil {
				renderLogin(w, "session error")
				return
			}

			cookie := &http.Cookie{
				Name:     sessionCookieName,
				Value:    token,
				Path:     "/",
				HttpOnly: true,
				Secure:   isSecure,
				SameSite: http.SameSiteStrictMode,
				MaxAge:   86400, // 24 hours
			}
			http.SetCookie(w, cookie)
			http.Redirect(w, r, "/dashboard", http.StatusSeeOther)

		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	}
}

// HandleLogout clears the session cookie and redirects to login.
func HandleLogout(sessions *SessionStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if cookie, err := r.Cookie(sessionCookieName); err == nil {
			sessions.Delete(cookie.Value)
		}

		// Expire the cookie.
		http.SetCookie(w, &http.Cookie{
			Name:     sessionCookieName,
			Value:    "",
			Path:     "/",
			HttpOnly: true,
			MaxAge:   -1,
		})

		http.Redirect(w, r, "/dashboard/login", http.StatusSeeOther)
	}
}
