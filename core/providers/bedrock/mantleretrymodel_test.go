package bedrock

import (
	"context"
	"testing"

	"github.com/capsohq/bifrost/core/schemas"
	"github.com/stretchr/testify/require"
)

// TestBedrockOpenAISurfacesKeepTheCallersRegionPrefixedModel: the Mantle and
// runtime OpenAI-surface handlers strip a region/ prefix from the model before
// sending, but the request object is the caller's, and executeRequestWithRetries
// passes the same one to the next attempt. Each handler must strip on a copy so a
// retry still sees region/model. A cancelled context ends each call right after the
// strip, with no upstream needed.
func TestBedrockOpenAISurfacesKeepTheCallersRegionPrefixedModel(t *testing.T) {
	provider, err := NewBedrockProvider(&schemas.ProviderConfig{
		ConcurrencyAndBufferSize: schemas.ConcurrencyAndBufferSize{Concurrency: 1, BufferSize: 1},
	}, noopLogger{})
	require.NoError(t, err)
	ctx, cancel := schemas.NewBifrostContextWithCancel(context.Background())
	cancel()
	key := schemas.Key{Value: *schemas.NewSecretVar("bedrock-api-key"), BedrockKeyConfig: &schemas.BedrockKeyConfig{}}
	const model = "us-west-2/openai.gpt-oss-120b-1:0"
	noHook := func(*schemas.BifrostContext, *schemas.BifrostResponse, *schemas.BifrostError) (*schemas.BifrostResponse, *schemas.BifrostError) {
		return nil, nil
	}
	finalizer := func(context.Context) {}

	chat := func() *schemas.BifrostChatRequest {
		return &schemas.BifrostChatRequest{Provider: schemas.Bedrock, Model: model, Input: []schemas.ChatMessage{{
			Role: schemas.ChatMessageRoleUser, Content: &schemas.ChatMessageContent{ContentStr: schemas.Ptr("hi")},
		}}}
	}
	responses := func() *schemas.BifrostResponsesRequest {
		return &schemas.BifrostResponsesRequest{Provider: schemas.Bedrock, Model: model, Input: []schemas.ResponsesMessage{{
			Type: schemas.Ptr(schemas.ResponsesMessageTypeMessage), Role: schemas.Ptr(schemas.ResponsesInputMessageRoleUser),
			Content: &schemas.ResponsesMessageContent{ContentStr: schemas.Ptr("hi")},
		}}, Params: &schemas.ResponsesParameters{}}
	}
	cases := map[string]func() string{
		"mantle chat": func() string { r := chat(); _, _ = provider.mantleChatCompletions(ctx, key, r); return r.Model },
		"mantle chat stream": func() string {
			r := chat()
			_, _ = provider.mantleChatCompletionsStream(ctx, noHook, finalizer, key, r)
			return r.Model
		},
		"mantle responses": func() string { r := responses(); _, _ = provider.mantleResponses(ctx, key, r); return r.Model },
		"mantle responses stream": func() string {
			r := responses()
			_, _ = provider.mantleResponsesStream(ctx, noHook, finalizer, key, r)
			return r.Model
		},
		"runtime chat": func() string { r := chat(); _, _ = provider.runtimeChatCompletions(ctx, key, r); return r.Model },
		"runtime chat stream": func() string {
			r := chat()
			_, _ = provider.runtimeChatCompletionsStream(ctx, noHook, finalizer, key, r)
			return r.Model
		},
		"runtime responses": func() string { r := responses(); _, _ = provider.runtimeResponses(ctx, key, r); return r.Model },
		"runtime responses stream": func() string {
			r := responses()
			_, _ = provider.runtimeResponsesStream(ctx, noHook, finalizer, key, r)
			return r.Model
		},
	}
	for name, call := range cases {
		require.Equal(t, model, call(), "%s rewrote the caller's model", name)
	}
}
