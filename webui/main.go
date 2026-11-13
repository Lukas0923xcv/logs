// logs-webui: read-only web UI for a central log archive.
//
// It serves statistics from the daily manifests and lets you browse, view,
// filter and download logs. It never writes to the data directory.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

type config struct {
	DataDir        string
	Listen         string
	Title          string
	AuthFile       string
	IndexRefresh   time.Duration
	FilterTimeout  time.Duration
	FilterMax      int
	PageBytes      int64
	ArchiveStreams int
	ZipStreams     int
	ZstdMaxWindow  uint64
}

func envStr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int64) int64 {
	if v := os.Getenv(key); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n <= 0 {
			log.Fatalf("config: %s must be a positive integer, got %q", key, v)
		}
		return n
	}
	return def
}

func envDur(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			log.Fatalf("config: %s must be a duration like 30s or 5m, got %q", key, v)
		}
		return d
	}
	return def
}

func loadConfig() config {
	return config{
		DataDir:        envStr("LOGS_DATA_DIR", "/mnt/logs-ro"),
		Listen:         envStr("LOGS_LISTEN", "127.0.0.1:8484"),
		Title:          envStr("LOGS_TITLE", "Log archive"),
		AuthFile:       os.Getenv("LOGS_BASIC_AUTH_FILE"),
		IndexRefresh:   envDur("LOGS_INDEX_REFRESH", 5*time.Minute),
		FilterTimeout:  envDur("LOGS_FILTER_TIMEOUT", 15*time.Second),
		FilterMax:      int(envInt("LOGS_FILTER_MAX_RESULTS", 500)),
		PageBytes:      envInt("LOGS_PAGE_BYTES", 64*1024),
		ArchiveStreams: int(envInt("LOGS_ARCHIVE_STREAMS", 1)),
		ZipStreams:     int(envInt("LOGS_ZIP_STREAMS", 2)),
		ZstdMaxWindow:  uint64(envInt("LOGS_ZSTD_MAX_WINDOW_MB", 32)) << 20,
	}
}

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}
	log.SetFlags(0) // journald adds timestamps

	cfg := loadConfig()
	app, err := newApp(cfg)
	if err != nil {
		log.Fatalf("startup: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go app.index.run(ctx, cfg.IndexRefresh)

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           app.handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Printf("logs-webui %s listening on http://%s (data: %s, read-only)", version, cfg.Listen, cfg.DataDir)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server: %v", err)
	}
}
