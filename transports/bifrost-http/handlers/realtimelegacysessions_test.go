package handlers

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	bifrost "github.com/capsohq/bifrost/core"
	"github.com/capsohq/bifrost/core/schemas"
	"github.com/capsohq/bifrost/framework/configstore"
	"github.com/capsohq/bifrost/transports/bifrost-http/lib"
	"github.com/fasthttp/router"
	"github.com/stretchr/testify/require"
	"github.com/valyala/fasthttp"
)

func TestLegacyRealtimeSessionRequestTranslatesToGAClientSecret(t *testing.T) {
	legacy := `{"model":"gpt-realtime","voice":"alloy","speed":1.1,"modalities":["audio","text"],"instructions":"be brief",
	"input_audio_format":"pcm16","output_audio_format":"g711_ulaw","input_audio_transcription":{"model":"whisper-1"},
	"turn_detection":{"type":"server_vad"},"input_audio_noise_reduction":{"type":"near_field"},"tools":[{"type":"function","name":"f"}],
	"tool_choice":"auto","max_response_output_tokens":256,"temperature":0.8,"client_secret":{"expires_after":{"anchor":"created_at","seconds":600}}}`
	got, err := legacyRealtimeSessionToClientSecretBody([]byte(legacy))
	require.Nil(t, err)
	require.JSONEq(t, `{
		"expires_after":{"anchor":"created_at","seconds":600},
		"session":{"type":"realtime","model":"gpt-realtime","instructions":"be brief","output_modalities":["audio"],
			"tools":[{"type":"function","name":"f"}],"tool_choice":"auto","max_output_tokens":256,
			"audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"transcription":{"model":"whisper-1"},
				"turn_detection":{"type":"server_vad"},"noise_reduction":{"type":"near_field"}},
				"output":{"format":{"type":"audio/pcmu"},"voice":"alloy","speed":1.1}}}}`, string(got))

	// Text-only stays text-only.
	got, err = legacyRealtimeSessionToClientSecretBody([]byte(`{"model":"gpt-realtime","modalities":["text"]}`))
	require.Nil(t, err)
	require.JSONEq(t, `{"session":{"type":"realtime","model":"gpt-realtime","output_modalities":["text"]}}`, string(got))

	// Fields nested under "session" are flattened first, top-level fields winning.
	got, err = legacyRealtimeSessionToClientSecretBody([]byte(`{"session":{"model":"openai/gpt-realtime","instructions":"Keep answers brief"}}`))
	require.Nil(t, err)
	require.JSONEq(t, `{"session":{"type":"realtime","model":"openai/gpt-realtime","instructions":"Keep answers brief"}}`, string(got))
	// The model follows base's selection (a nonempty session.model first); other
	// fields keep top-level precedence.
	got, err = legacyRealtimeSessionToClientSecretBody([]byte(`{"model":"openai/gpt-realtime","voice":"ash","session":{"model":"openai/gpt-realtime-mini","voice":"alloy","instructions":"nested"}}`))
	require.Nil(t, err)
	require.JSONEq(t, `{"session":{"type":"realtime","model":"openai/gpt-realtime-mini","instructions":"nested","audio":{"output":{"voice":"ash"}}}}`, string(got))
	got, err = legacyRealtimeSessionToClientSecretBody([]byte(`{"model":"","session":{"model":"openai/gpt-realtime-mini"}}`))
	require.Nil(t, err)
	require.JSONEq(t, `{"session":{"type":"realtime","model":"openai/gpt-realtime-mini"}}`, string(got), "an empty top-level model must not hide a valid nested one")

	// A non-default temperature cannot be honoured through GA and is refused,
	// top-level or nested; the beta default is accepted (and is what GA does).
	for _, body := range []string{
		`{"model":"gpt-realtime","temperature":0.6}`,
		`{"session":{"model":"gpt-realtime","temperature":1.2}}`,
		`{"model":"gpt-realtime","temperature":"hot"}`,
	} {
		_, err = legacyRealtimeSessionToClientSecretBody([]byte(body))
		require.NotNil(t, err, body)
		require.Contains(t, err.Error.Message, "temperature", body)
	}
	_, err = legacyRealtimeSessionToClientSecretBody([]byte(`{"model":"gpt-realtime","temperature":null}`))
	require.Nil(t, err)
	_, err = legacyRealtimeSessionToClientSecretBody([]byte(`{"session":"gpt-realtime"}`))
	require.NotNil(t, err)

	_, err = legacyRealtimeSessionToClientSecretBody([]byte(`{"model":"gpt-realtime","input_audio_format":"mp3"}`))
	require.NotNil(t, err, "an unknown beta audio format must be refused, not forwarded")
	_, err = legacyRealtimeSessionToClientSecretBody([]byte(`[1]`))
	require.NotNil(t, err)
}

func TestGAClientSecretResponseTranslatesToLegacyRealtimeSession(t *testing.T) {
	ga := `{"value":"ek_123","expires_at":1760000000,"session":{"type":"realtime","object":"realtime.session","id":"sess_1",
	"model":"gpt-realtime","output_modalities":["audio"],"instructions":"be brief","max_output_tokens":"inf",
	"audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"transcription":{"model":"whisper-1"},"turn_detection":{"type":"server_vad"}},
	"output":{"format":{"type":"audio/pcma"},"voice":"alloy"}}}}`
	require.JSONEq(t, `{"id":"sess_1","object":"realtime.session","model":"gpt-realtime","modalities":["audio","text"],"instructions":"be brief",
		"max_response_output_tokens":"inf","input_audio_format":"pcm16","output_audio_format":"g711_alaw",
		"input_audio_transcription":{"model":"whisper-1"},"turn_detection":{"type":"server_vad"},"voice":"alloy",
		"client_secret":{"value":"ek_123","expires_at":1760000000}}`, string(clientSecretToLegacyRealtimeSession([]byte(ga))))

	upstreamErr := `{"error":{"message":"bad","type":"invalid_request_error"}}`
	require.Equal(t, upstreamErr, string(clientSecretToLegacyRealtimeSession([]byte(upstreamErr))), "a non-GA body passes through unchanged")
}

// legacySessionAccount points OpenAI at a stub upstream.
type legacySessionAccount struct{ baseURL string }

func (a legacySessionAccount) GetConfiguredProviders() ([]schemas.ModelProvider, error) {
	return []schemas.ModelProvider{schemas.OpenAI}, nil
}

func (a legacySessionAccount) GetKeysForProvider(context.Context, schemas.ModelProvider) ([]schemas.Key, error) {
	return []schemas.Key{{ID: "k1", Name: "k1", Value: *schemas.NewSecretVar("sk-test"), Models: schemas.WhiteList{"*"}, Weight: 1}}, nil
}

func (a legacySessionAccount) GetConfigForProvider(schemas.ModelProvider) (*schemas.ProviderConfig, error) {
	cfg := &schemas.ProviderConfig{
		NetworkConfig:            schemas.DefaultNetworkConfig,
		ConcurrencyAndBufferSize: schemas.DefaultConcurrencyAndBufferSize,
	}
	cfg.NetworkConfig.BaseURL = a.baseURL
	return cfg, nil
}

// TestLegacyRealtimeSessionRoutesMintThroughClientSecrets is the contract for both
// retired beta routes and the GA route, through the real handler and OpenAI
// provider: a beta request reaches the upstream as a GA client-secret request and
// the client receives the beta realtime.session object, while the GA route is
// passed through unchanged.
func TestLegacyRealtimeSessionRoutesMintThroughClientSecrets(t *testing.T) {
	SetLogger(&mockLogger{})
	var mu sync.Mutex
	var gotPath, gotBody, gotBeta string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		gotPath, gotBody, gotBeta = r.URL.Path, string(body), r.Header.Get("OpenAI-Beta")
		mu.Unlock()
		// Like GA: audio output already carries its transcript, and audio and text
		// together is an invalid output_modalities combination.
		var req struct {
			Session struct {
				OutputModalities []string `json:"output_modalities"`
			} `json:"session"`
		}
		_ = json.Unmarshal(body, &req)
		if len(req.Session.OutputModalities) > 1 {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"invalid output_modalities","type":"invalid_request_error"}}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"value":"ek_abc","expires_at":1760000000,"session":{"type":"realtime","object":"realtime.session","id":"sess_9","model":"gpt-realtime","output_modalities":["audio"],"audio":{"output":{"voice":"alloy"}}}}`))
	}))
	defer upstream.Close()

	client, err := bifrost.Init(context.Background(), schemas.BifrostConfig{
		Account: legacySessionAccount{baseURL: upstream.URL},
		Logger:  bifrost.NewDefaultLogger(schemas.LogLevelError),
	})
	require.NoError(t, err)
	defer client.Shutdown()

	h := NewRealtimeClientSecretsHandler(client, &lib.Config{ClientConfig: &configstore.ClientConfig{}})
	r := router.New()
	h.RegisterRoutes(r)
	ln, err := (&net.ListenConfig{}).Listen(t.Context(), "tcp", "127.0.0.1:0")
	require.NoError(t, err)
	srv := &fasthttp.Server{Handler: r.Handler}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Shutdown() //nolint:errcheck
	base := "http://" + ln.Addr().String()

	post := func(path, body string) (int, map[string]any) {
		t.Helper()
		resp, err := http.Post(base+path, "application/json", strings.NewReader(body))
		require.NoError(t, err)
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		var out map[string]any
		require.NoError(t, json.Unmarshal(raw, &out), string(raw))
		return resp.StatusCode, out
	}

	for _, path := range []string{"/v1/realtime/sessions", "/openai/v1/realtime/sessions"} {
		model := "gpt-realtime"
		if path == "/v1/realtime/sessions" {
			model = "openai/gpt-realtime"
		}
		status, out := post(path, `{"model":"`+model+`","voice":"alloy","modalities":["audio","text"]}`)
		require.Equal(t, 200, status, "%s: %v", path, out)
		mu.Lock()
		require.Equal(t, "/v1/realtime/client_secrets", gotPath, "%s must mint through GA client_secrets", path)
		require.Empty(t, gotBeta, "%s must not send the retired OpenAI-Beta header", path)
		require.JSONEq(t, `{"session":{"type":"realtime","model":"gpt-realtime","output_modalities":["audio"],"audio":{"output":{"voice":"alloy"}}}}`, gotBody, path)
		mu.Unlock()
		require.Equal(t, "realtime.session", out["object"], path)
		require.Equal(t, "sess_9", out["id"], path)
		require.Equal(t, []any{"audio", "text"}, out["modalities"], path)
		require.Equal(t, "alloy", out["voice"], path)
		require.Equal(t, map[string]any{"value": "ek_abc", "expires_at": float64(1760000000)}, out["client_secret"], path)
	}

	status, nested := post("/v1/realtime/sessions", `{"session":{"model":"openai/gpt-realtime","instructions":"Keep answers brief"}}`)
	require.Equal(t, 200, status, "nested legacy session: %v", nested)
	require.Equal(t, "realtime.session", nested["object"])

	status, _ = post("/v1/realtime/sessions", `{"model":"openai/gpt-realtime","session":{"model":"openai/gpt-realtime-mini"}}`)
	require.Equal(t, 200, status)
	mu.Lock()
	require.Contains(t, gotBody, `"model":"gpt-realtime-mini"`, "the nested model is the one minted, as at base")
	mu.Unlock()

	status, refused := post("/openai/v1/realtime/sessions", `{"model":"gpt-realtime","temperature":0.6}`)
	require.Equal(t, 400, status, "%v", refused)

	status, out := post("/v1/realtime/client_secrets", `{"session":{"type":"realtime","model":"openai/gpt-realtime"}}`)
	require.Equal(t, 200, status, "%v", out)
	require.Equal(t, "ek_abc", out["value"], "the GA route returns the GA shape unchanged")
	require.NotContains(t, out, "client_secret")
}
