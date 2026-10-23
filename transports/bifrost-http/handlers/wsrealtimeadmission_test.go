package handlers

import (
	"context"
	"net"
	"strings"
	"testing"
	"time"

	bifrost "github.com/capsohq/bifrost/core"
	"github.com/capsohq/bifrost/core/schemas"
	bfws "github.com/capsohq/bifrost/transports/bifrost-http/websocket"
	"github.com/fasthttp/router"
	ws "github.com/fasthttp/websocket"
	"github.com/valyala/fasthttp"
)

// TestTranscriptionUpgradeCountsAgainstMaxConnectionsDuringBootstrap: a transcription
// client can hold its socket through the whole bootstrap window without sending a
// model, so it must be admitted (and counted against MaxConnections, and reachable
// by CloseAll) before the bootstrap read, not after it.
func TestTranscriptionUpgradeCountsAgainstMaxConnectionsDuringBootstrap(t *testing.T) {
	h := &WSRealtimeHandler{sessions: bfws.NewSessionManager(1)}
	r := router.New()
	r.GET("/v1/realtime", func(ctx *fasthttp.RequestCtx) {
		preReqCtx, cancel := schemas.NewBifrostContextWithCancel(context.Background())
		h.handleTranscriptionUpgrade(ctx, preReqCtx, cancel, &authHeaders{}, "/v1/realtime", "")
	})
	ln, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	srv := &fasthttp.Server{Handler: r.Handler}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Shutdown() //nolint:errcheck
	url := "ws://" + ln.Addr().String() + "/v1/realtime?intent=transcription"

	// First client upgrades and sends nothing: it is waiting in the bootstrap.
	idle, _, err := ws.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial idle client: %v", err)
	}
	defer idle.Close()
	deadline := time.Now().Add(2 * time.Second)
	for h.sessions.Count() != 1 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := h.sessions.Count(); got != 1 {
		t.Fatalf("sessions during bootstrap = %d, want 1: an idle bootstrap must already hold its slot", got)
	}

	// The second is refused at once, well inside the 15s bootstrap window.
	second, _, err := ws.DefaultDialer.Dial(url, nil)
	if err != nil {
		t.Fatalf("dial second client: %v", err)
	}
	defer second.Close()
	_ = second.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, msg, err := second.ReadMessage()
	if err != nil {
		t.Fatalf("second client got no refusal: %v", err)
	}
	if !strings.Contains(string(msg), "rate_limit_exceeded") {
		t.Fatalf("second client got %s, want a rate_limit_exceeded refusal", msg)
	}

	h.Close()
	_ = idle.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err := idle.ReadMessage(); err == nil {
		t.Fatal("CloseAll left the bootstrapping connection open")
	}
}

// TestTranscriptionUpgradeWithQueryModelSkipsTheBootstrap: with ?model= the provider
// and key are known up front, so the handler must go straight to opening the
// upstream session instead of waiting up to 15s for a model-bearing update, which
// a client that waits for session.created first would never send. Here no
// realtime provider is configured, so "straight on" shows as an immediate refusal.
func TestTranscriptionUpgradeWithQueryModelSkipsTheBootstrap(t *testing.T) {
	client, err := bifrost.Init(context.Background(), schemas.BifrostConfig{
		Account: wsSpanTestAccount{},
		Logger:  bifrost.NewDefaultLogger(schemas.LogLevelError),
	})
	if err != nil {
		t.Fatalf("init bifrost: %v", err)
	}
	defer client.Shutdown()
	h := &WSRealtimeHandler{client: client, sessions: bfws.NewSessionManager(0)}
	r := router.New()
	r.GET("/v1/realtime", func(ctx *fasthttp.RequestCtx) {
		preReqCtx, cancel := schemas.NewBifrostContextWithCancel(context.Background())
		h.handleTranscriptionUpgrade(ctx, preReqCtx, cancel, &authHeaders{}, "/v1/realtime", "elevenlabs/scribe_v2_realtime")
	})
	ln, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	srv := &fasthttp.Server{Handler: r.Handler}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Shutdown() //nolint:errcheck

	conn, _, err := ws.DefaultDialer.Dial("ws://"+ln.Addr().String()+"/v1/realtime?intent=transcription&model=elevenlabs/scribe_v2_realtime", nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	start := time.Now()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, msg, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("no answer without a bootstrap update: %v", err)
	}
	if strings.Contains(string(msg), "bootstrap") {
		t.Fatalf("handler waited for a bootstrap update despite ?model=: %s", msg)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("answered after %v, want it at once", elapsed)
	}
}
