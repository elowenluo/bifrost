package openai

import (
	"testing"

	"github.com/capsohq/bifrost/core/schemas"
	"github.com/stretchr/testify/require"
)

// The reserved-namespace filter matches whole namespace names only. A namespace
// that merely starts with a reserved name, or a function tool that happens to be
// called "web", is the caller's own tool and must reach Bedrock unchanged. xAI
// and OpenAI keep their native Responses tool lists in this fork, so the filter
// never touches them.
func TestToOpenAIResponsesRequest_ReservedNamespaceExactMatchOnly(t *testing.T) {
	namespace := func(name string) schemas.ResponsesTool {
		return schemas.ResponsesTool{
			Type: schemas.ResponsesToolTypeNamespace,
			Name: schemas.Ptr(name),
			ResponsesToolNamespace: &schemas.ResponsesToolNamespace{Tools: []schemas.ResponsesTool{{
				Type:                  schemas.ResponsesToolTypeFunction,
				Name:                  schemas.Ptr("run"),
				ResponsesToolFunction: &schemas.ResponsesToolFunction{},
			}}},
		}
	}
	webFunction := schemas.ResponsesTool{
		Type:                  schemas.ResponsesToolTypeFunction,
		Name:                  schemas.Ptr("web"),
		ResponsesToolFunction: &schemas.ResponsesToolFunction{},
	}
	tools := []schemas.ResponsesTool{namespace("web_tools"), namespace("webby"), namespace("python3"), webFunction, namespace("web")}

	tests := []struct {
		name      string
		provider  schemas.ModelProvider
		wantNames []string
	}{
		{"bedrock drops only the exact reserved name", schemas.Bedrock, []string{"web_tools", "webby", "python3", "web"}},
		{"mantle drops only the exact reserved name", schemas.BedrockMantle, []string{"web_tools", "webby", "python3", "web", ""}},
		{"xai keeps every tool", schemas.XAI, []string{"web_tools", "webby", "python3", "web", "web"}},
		{"openai keeps every tool", schemas.OpenAI, []string{"web_tools", "webby", "python3", "web", "web"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			result := ToOpenAIResponsesRequest(nil, &schemas.BifrostResponsesRequest{
				Provider: tc.provider,
				Model:    "gpt-5",
				Input: []schemas.ResponsesMessage{{
					Role:    schemas.Ptr(schemas.ResponsesInputMessageRoleUser),
					Content: &schemas.ResponsesMessageContent{ContentStr: schemas.Ptr("hi")},
				}},
				Params: &schemas.ResponsesParameters{Tools: tools},
			})
			require.NotNil(t, result)
			gotNames := make([]string, 0, len(result.Tools))
			for _, tool := range result.Tools {
				name := ""
				if tool.Name != nil {
					name = *tool.Name
				}
				gotNames = append(gotNames, name)
			}
			require.Equal(t, tc.wantNames, gotNames)
			// The surviving "web" entry on Bedrock is the function tool, not the namespace.
			for _, tool := range result.Tools {
				if tool.Name != nil && *tool.Name == "web" && (tc.provider == schemas.Bedrock || tc.provider == schemas.BedrockMantle) {
					require.Equal(t, schemas.ResponsesToolTypeFunction, tool.Type)
				}
			}
		})
	}
}
