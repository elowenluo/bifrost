package handlers

import (
	"context"
	"net"
	"strings"
	"testing"
	"time"

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
		h.handleTranscriptionUpgrade(ctx, preReqCtx, cancel, &authHeaders{}, "/v1/realtime")
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
