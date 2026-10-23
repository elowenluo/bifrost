package handlers

import (
	"encoding/json"
	"strings"

	"github.com/capsohq/bifrost/core/schemas"
	"github.com/valyala/fasthttp"
)

// The beta realtime session endpoints, POST /v1/realtime/sessions and
// /openai/v1/realtime/sessions, were retired upstream (#7089) in favour of GA
// POST /v1/realtime/client_secrets. Clients built against the beta shape still
// post here, so these routes stay as an adapter: the beta request is translated
// into a GA client-secret request, minted through the same handler (governance,
// key selection, alias resolution, ephemeral-key mapping), and the GA response is
// translated back into the beta realtime.session object. Nothing calls OpenAI's
// beta endpoint, so the routes keep working whether or not OpenAI still serves it.
//
// Beta request:  {"model": ..., "voice": ..., "modalities": [...], "instructions": ...,
//                 "input_audio_format": "pcm16", "turn_detection": {...}, ...,
//                 "client_secret": {"expires_after": {...}}}
// GA request:    {"expires_after": {...}, "session": {"type": "realtime", "model": ...,
//                 "output_modalities": [...], "audio": {"input": {...}, "output": {...}}, ...}}
// GA response:   {"value": ..., "expires_at": ..., "session": {...}}
// Beta response: {"id": ..., "object": "realtime.session", "model": ..., ...,
//                 "client_secret": {"value": ..., "expires_at": ...}}

// isLegacyRealtimeSessionPath reports whether path is one of the retired beta routes.
func isLegacyRealtimeSessionPath(path string) bool {
	return strings.HasSuffix(path, "/realtime/sessions")
}

// legacyRealtimeAudioFormats maps beta audio format names to GA format objects.
var legacyRealtimeAudioFormats = map[string]string{
	"pcm16":     `{"type":"audio/pcm","rate":24000}`,
	"g711_ulaw": `{"type":"audio/pcmu"}`,
	"g711_alaw": `{"type":"audio/pcma"}`,
}

// legacyRealtimeSessionToClientSecretBody translates a beta session request into
// the GA client-secret request the handler mints with.
func legacyRealtimeSessionToClientSecretBody(body []byte) ([]byte, *schemas.BifrostError) {
	var legacy map[string]json.RawMessage
	if err := json.Unmarshal(body, &legacy); err != nil || legacy == nil {
		return nil, newRealtimeClientSecretHandlerError(fasthttp.StatusBadRequest, "invalid_request_error", "request body must be a JSON object", err)
	}
	// Base accepted the beta fields nested under "session" too, and flattened them
	// with top-level fields taking precedence; do the same before translating.
	if nested, ok := legacy["session"]; ok {
		delete(legacy, "session")
		if !isJSONNull(nested) {
			var session map[string]json.RawMessage
			if err := json.Unmarshal(nested, &session); err != nil {
				return nil, newRealtimeClientSecretHandlerError(fasthttp.StatusBadRequest, "invalid_request_error", "session must be an object", err)
			}
			for field, value := range session {
				if _, set := legacy[field]; !set {
					legacy[field] = value
				}
			}
		}
	}
	session := map[string]json.RawMessage{"type": json.RawMessage(`"realtime"`)}
	input := map[string]json.RawMessage{}
	output := map[string]json.RawMessage{}
	out := map[string]json.RawMessage{}

	for field, value := range legacy {
		switch field {
		case "client_secret":
			// Beta nests the secret's lifetime here; GA takes it at the top level.
			var secret struct {
				ExpiresAfter json.RawMessage `json:"expires_after"`
			}
			if err := json.Unmarshal(value, &secret); err != nil {
				return nil, newRealtimeClientSecretHandlerError(fasthttp.StatusBadRequest, "invalid_request_error", "client_secret must be an object", err)
			}
			if len(secret.ExpiresAfter) > 0 {
				out["expires_after"] = secret.ExpiresAfter
			}
		case "modalities":
			modalities, err := legacyRealtimeModalitiesToGA(value)
			if err != nil {
				return nil, newRealtimeClientSecretHandlerError(fasthttp.StatusBadRequest, "invalid_request_error", "modalities must be an array of strings", err)
			}
			session["output_modalities"] = modalities
		case "temperature":
			// The GA realtime session has no temperature; forwarding it would make
			// the upstream reject the whole request.
		case "max_response_output_tokens":
			session["max_output_tokens"] = value
		case "voice", "speed":
			output[field] = value
		case "input_audio_format", "output_audio_format":
			format, err := legacyRealtimeAudioFormat(value)
			if err != nil {
				return nil, newRealtimeClientSecretHandlerError(fasthttp.StatusBadRequest, "invalid_request_error", field+": "+err.Error(), nil)
			}
			if field == "input_audio_format" {
				input["format"] = format
			} else {
				output["format"] = format
			}
		case "input_audio_transcription":
			input["transcription"] = value
		case "turn_detection":
			input["turn_detection"] = value
		case "input_audio_noise_reduction":
			input["noise_reduction"] = value
		default:
			// model, instructions, tools, tool_choice, tracing, include and the rest
			// carry the same name and meaning in the GA session.
			session[field] = value
		}
	}

	audio := map[string]json.RawMessage{}
	if len(input) > 0 {
		audio["input"], _ = json.Marshal(input)
	}
	if len(output) > 0 {
		audio["output"], _ = json.Marshal(output)
	}
	if len(audio) > 0 {
		session["audio"], _ = json.Marshal(audio)
	}
	out["session"], _ = json.Marshal(session)
	converted, err := json.Marshal(out)
	if err != nil {
		return nil, newRealtimeClientSecretHandlerError(fasthttp.StatusInternalServerError, "server_error", "failed to build the client secret request", err)
	}
	return converted, nil
}

// legacyRealtimeModalitiesToGA maps beta modalities to GA output_modalities. Beta
// audio sessions always listed text too (the transcript came with the audio), but
// GA's audio mode already includes the transcript and rejects audio and text
// together, so any beta list naming audio becomes ["audio"]; text-only stays.
func legacyRealtimeModalitiesToGA(value json.RawMessage) (json.RawMessage, error) {
	var modalities []string
	if err := json.Unmarshal(value, &modalities); err != nil {
		return nil, err
	}
	for _, modality := range modalities {
		if modality == "audio" {
			return json.RawMessage(`["audio"]`), nil
		}
	}
	return value, nil
}

// gaRealtimeModalitiesToLegacy maps GA output_modalities back to the beta form, in
// which an audio session reports ["audio","text"].
func gaRealtimeModalitiesToLegacy(value json.RawMessage) json.RawMessage {
	var modalities []string
	if json.Unmarshal(value, &modalities) != nil {
		return value
	}
	for _, modality := range modalities {
		if modality == "audio" {
			return json.RawMessage(`["audio","text"]`)
		}
	}
	return value
}

func legacyRealtimeAudioFormat(value json.RawMessage) (json.RawMessage, error) {
	var name string
	if err := json.Unmarshal(value, &name); err != nil {
		// Already a GA format object: pass it through.
		return value, nil
	}
	format, ok := legacyRealtimeAudioFormats[name]
	if !ok {
		return nil, &legacyRealtimeFormatError{name: name}
	}
	return json.RawMessage(format), nil
}

type legacyRealtimeFormatError struct{ name string }

func (e *legacyRealtimeFormatError) Error() string {
	return "unsupported audio format " + e.name + "; use pcm16, g711_ulaw or g711_alaw"
}

// clientSecretToLegacyRealtimeSession translates a GA client-secret response into
// the beta realtime.session object. A body that is not the GA shape is returned
// unchanged, so an upstream error passes through as sent.
func clientSecretToLegacyRealtimeSession(body []byte) []byte {
	var ga struct {
		Value     json.RawMessage            `json:"value"`
		ExpiresAt json.RawMessage            `json:"expires_at"`
		Session   map[string]json.RawMessage `json:"session"`
	}
	if err := json.Unmarshal(body, &ga); err != nil || len(ga.Value) == 0 {
		return body
	}
	legacy := map[string]json.RawMessage{"object": json.RawMessage(`"realtime.session"`)}
	var audio struct {
		Input  map[string]json.RawMessage `json:"input"`
		Output map[string]json.RawMessage `json:"output"`
	}
	for field, value := range ga.Session {
		switch field {
		case "type", "object":
			// The beta object has no type, and its object is always realtime.session.
		case "output_modalities":
			legacy["modalities"] = gaRealtimeModalitiesToLegacy(value)
		case "max_output_tokens":
			legacy["max_response_output_tokens"] = value
		case "audio":
			_ = json.Unmarshal(value, &audio)
		default:
			legacy[field] = value
		}
	}
	for field, value := range audio.Input {
		switch field {
		case "format":
			legacy["input_audio_format"] = legacyRealtimeAudioFormatName(value)
		case "transcription":
			legacy["input_audio_transcription"] = value
		case "turn_detection":
			legacy["turn_detection"] = value
		case "noise_reduction":
			legacy["input_audio_noise_reduction"] = value
		}
	}
	for field, value := range audio.Output {
		switch field {
		case "format":
			legacy["output_audio_format"] = legacyRealtimeAudioFormatName(value)
		case "voice", "speed":
			legacy[field] = value
		}
	}
	secret := map[string]json.RawMessage{"value": ga.Value}
	if len(ga.ExpiresAt) > 0 {
		secret["expires_at"] = ga.ExpiresAt
	}
	legacy["client_secret"], _ = json.Marshal(secret)
	converted, err := json.Marshal(legacy)
	if err != nil {
		return body
	}
	return converted
}

// legacyRealtimeAudioFormatName maps a GA format object back to its beta name,
// leaving a format the beta API had no name for as the GA object.
func legacyRealtimeAudioFormatName(value json.RawMessage) json.RawMessage {
	var format struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(value, &format) != nil {
		return value
	}
	switch format.Type {
	case "audio/pcm":
		return json.RawMessage(`"pcm16"`)
	case "audio/pcmu":
		return json.RawMessage(`"g711_ulaw"`)
	case "audio/pcma":
		return json.RawMessage(`"g711_alaw"`)
	}
	return value
}
