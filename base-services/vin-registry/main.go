// vin-registry — records which vehicle identities exist on this Nexus platform.
//
// Increment 1 records exactly two facts, both reported by the services that
// issue the certificates:
//
//	factory-helper       → a factory certificate was issued for a VIN
//	registration server  → an operational certificate was issued for a VIN
//
// On a successful issuance the VIN is also added to the nexus-fleet group, so
// it shows up in FleetView without anyone maintaining a list by hand. That is
// the whole point: on a platform that has been running for weeks, the fleet
// view should reflect reality rather than whatever was seeded on day one.
//
// Deliberately NOT in increment 1: telemetry statistics (they belong in a
// scheduled scan over BigTable, not in the hot ingestion path) and any
// reconciliation against the CA pools.
//
// Callers must tolerate this service being absent — reporting is best effort
// and must never block a certificate from being issued.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"regexp"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// Every VIN that receives a certificate joins this group. Single fleet by
// design — multiple fleets would be a schema and UI change, not a setting.
const defaultFleet = "nexus-fleet"

var (
	vinPattern = regexp.MustCompile(`^[A-Za-z0-9-]{1,32}$`)

	// Closed sets rather than free text: these values are queried and grouped
	// by, so a typo in a caller would silently create a second category.
	validSources = map[string]bool{"factory-helper": true, "registration": true}
	validActions = map[string]bool{
		"factory-certificate-issued":     true,
		"operational-certificate-issued": true,
	}
	validResults = map[string]bool{"success": true, "failure": true}
)

type eventRequest struct {
	VIN    string `json:"vin"`
	Source string `json:"source"`
	Action string `json:"action"`
	Result string `json:"result"`
	Detail string `json:"detail,omitempty"`
}

// validate checks every field before anything touches the database. Returns the
// first problem found, naming the field, so a miswired caller gets a usable
// message instead of a 500 from the driver.
func (e *eventRequest) validate() error {
	if !vinPattern.MatchString(e.VIN) {
		return errors.New("vin must be 1-32 characters of [A-Za-z0-9-]")
	}
	if !validSources[e.Source] {
		return errors.New("source must be one of: factory-helper, registration")
	}
	if !validActions[e.Action] {
		return errors.New("action must be one of: factory-certificate-issued, operational-certificate-issued")
	}
	if !validResults[e.Result] {
		return errors.New("result must be one of: success, failure")
	}
	if len(e.Detail) > 512 {
		return errors.New("detail must be at most 512 characters")
	}
	return nil
}

type server struct{ db *sql.DB }

const schema = `
CREATE TABLE IF NOT EXISTS vin_events (
  id         SERIAL      PRIMARY KEY,
  vin        TEXT        NOT NULL,
  source     TEXT        NOT NULL,
  action     TEXT        NOT NULL,
  result     TEXT        NOT NULL,
  detail     TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS vin_events_vin_idx ON vin_events (vin, created_at DESC);
`

func (s *server) migrate(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, schema)
	return err
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}

func (s *server) postEvent(w http.ResponseWriter, r *http.Request) {
	var req eventRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed JSON body"})
		return
	}
	if err := req.validate(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	ctx := r.Context()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		log.Printf("begin tx: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "database unavailable"})
		return
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO vin_events (vin, source, action, result, detail) VALUES ($1,$2,$3,$4,NULLIF($5,''))`,
		req.VIN, req.Source, req.Action, req.Result, req.Detail); err != nil {
		log.Printf("insert event: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not record event"})
		return
	}

	// Only a successful issuance grants fleet membership. A failed attempt is
	// worth recording but must not put the VIN in front of anyone's eyes.
	enrolled := false
	if req.Result == "success" {
		res, err := tx.ExecContext(ctx,
			`INSERT INTO vehicle_groups (group_name, vehicle_id) VALUES ($1,$2)
			 ON CONFLICT (group_name, vehicle_id) DO NOTHING`,
			defaultFleet, req.VIN)
		if err != nil {
			log.Printf("enrol %s: %v", req.VIN, err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not enrol vin"})
			return
		}
		if n, _ := res.RowsAffected(); n > 0 {
			enrolled = true
			log.Printf("vin %s enrolled into %s", req.VIN, defaultFleet)
		}
	}

	if err := tx.Commit(); err != nil {
		log.Printf("commit: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not record event"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"recorded": true, "enrolled": enrolled})
}

type vinSummary struct {
	VIN        string    `json:"vin"`
	Events     int       `json:"events"`
	FirstSeen  time.Time `json:"first_seen"`
	LastSeen   time.Time `json:"last_seen"`
	LastAction string    `json:"last_action"`
	LastResult string    `json:"last_result"`
}

func (s *server) listVINs(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.QueryContext(r.Context(), `
		SELECT e.vin, COUNT(*), MIN(e.created_at), MAX(e.created_at),
		       (array_agg(e.action ORDER BY e.created_at DESC))[1],
		       (array_agg(e.result ORDER BY e.created_at DESC))[1]
		FROM vin_events e GROUP BY e.vin ORDER BY MAX(e.created_at) DESC`)
	if err != nil {
		log.Printf("list vins: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "database unavailable"})
		return
	}
	defer rows.Close()

	out := []vinSummary{}
	for rows.Next() {
		var v vinSummary
		if err := rows.Scan(&v.VIN, &v.Events, &v.FirstSeen, &v.LastSeen, &v.LastAction, &v.LastResult); err != nil {
			log.Printf("scan vin: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "database unavailable"})
			return
		}
		out = append(out, v)
	}
	writeJSON(w, http.StatusOK, map[string]any{"vins": out})
}

// maxEvents caps one vehicle's history. A VIN accumulates one row per
// certificate issuance, so this is far above anything a real vehicle reaches —
// it is here so a pathological row count cannot turn one request into a large
// response.
const maxEvents = 200

type vinEvent struct {
	CreatedAt time.Time `json:"created_at"`
	Action    string    `json:"action"`
	Source    string    `json:"source"`
	Result    string    `json:"result"`
	Detail    string    `json:"detail,omitempty"`
}

// listEvents returns one vehicle's complete history, newest first.
//
// A VIN with no events answers with an empty list rather than 404: the caller
// asked a question about a vehicle, and "nothing was recorded" is the answer.
// Whether the caller may see this vehicle at all is decided a layer up, in the
// web client, which knows the user's groups.
func (s *server) listEvents(w http.ResponseWriter, r *http.Request) {
	vin := r.PathValue("vin")
	// Before the database, so a malformed value never reaches SQL — and so this
	// path is testable without one.
	if !vinPattern.MatchString(vin) {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "vin must be 1-32 chars of [A-Za-z0-9-]"})
		return
	}

	rows, err := s.db.QueryContext(r.Context(), `
		SELECT created_at, action, source, result, COALESCE(detail, '')
		FROM vin_events WHERE vin = $1
		ORDER BY created_at DESC LIMIT $2`, vin, maxEvents)
	if err != nil {
		log.Printf("list events for %s: %v", vin, err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "database unavailable"})
		return
	}
	defer rows.Close()

	out := []vinEvent{}
	for rows.Next() {
		var e vinEvent
		if err := rows.Scan(&e.CreatedAt, &e.Action, &e.Source, &e.Result, &e.Detail); err != nil {
			log.Printf("scan event for %s: %v", vin, err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "database unavailable"})
			return
		}
		out = append(out, e)
	}
	writeJSON(w, http.StatusOK, map[string]any{"vin": vin, "events": out})
}

func newRouter(s *server) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("POST /v1/events", s.postEvent)
	mux.HandleFunc("GET /v1/vins", s.listVINs)
	mux.HandleFunc("GET /v1/vins/{vin}/events", s.listEvents)
	return mux
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	dsn := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		env("DB_HOST", "localhost"), env("DB_PORT", "5432"),
		os.Getenv("DB_USER"), os.Getenv("DB_PASSWORD"), os.Getenv("DB_NAME"))

	db, err := sql.Open("pgx", dsn)
	if err != nil {
		log.Fatalf("open database: %v", err)
	}
	db.SetMaxOpenConns(10)
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	for i := 1; ; i++ {
		if err = db.PingContext(ctx); err == nil {
			break
		}
		if i >= 15 {
			log.Fatalf("database not reachable after %d attempts: %v", i, err)
		}
		log.Printf("waiting for database (%d/15): %v", i, err)
		time.Sleep(2 * time.Second)
	}

	s := &server{db: db}
	if err := s.migrate(ctx); err != nil {
		log.Fatalf("apply schema: %v", err)
	}

	addr := ":" + env("PORT", "8080")
	log.Printf("vin-registry listening on %s", addr)
	srv := &http.Server{
		Addr:              addr,
		Handler:           newRouter(s),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}
