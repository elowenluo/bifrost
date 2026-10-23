package bedrock

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/capsohq/bifrost/core/schemas"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const toolResultImageDataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

func toolResultImageBlock(label string) BedrockContentBlock {
	return BedrockContentBlock{Image: &BedrockImageSource{Format: label}}
}

func toolResultBlock(id string, content ...BedrockContentBlock) BedrockContentBlock {
	return BedrockContentBlock{ToolResult: &BedrockToolResult{ToolUseID: id, Content: content}}
}

// describeBedrockBlocks renders blocks as short labels so expected layouts read at a glance.
func describeBedrockBlocks(blocks []BedrockContentBlock) []string {
	out := make([]string, 0, len(blocks))
	for _, b := range blocks {
		switch {
		case b.ToolResult != nil:
			out = append(out, fmt.Sprintf("toolResult(%s)[%s]", b.ToolResult.ToolUseID, strings.Join(describeBedrockBlocks(b.ToolResult.Content), ", ")))
		case b.Image != nil:
			out = append(out, "image:"+b.Image.Format)
		case b.Document != nil:
			out = append(out, "document")
		case b.CachePoint != nil:
			out = append(out, "cachePoint")
		case b.Text != nil:
			out = append(out, "text:"+*b.Text)
		default:
			out = append(out, "?")
		}
	}
	return out
}

func TestHoistToolResultImages(t *testing.T) {
	placeholder := "text:" + toolResultImagePlaceholder
	tests := []struct {
		name    string
		content []BedrockContentBlock
		want    []string
	}{
		{
			name:    "image-only result keeps a placeholder",
			content: []BedrockContentBlock{toolResultBlock("a", toolResultImageBlock("red"))},
			want:    []string{"toolResult(a)[" + placeholder + "]", "image:red"},
		},
		{
			name:    "text beside the image is kept without a placeholder",
			content: []BedrockContentBlock{toolResultBlock("a", BedrockContentBlock{Text: new("done")}, toolResultImageBlock("red"))},
			want:    []string{"toolResult(a)[text:done]", "image:red"},
		},
		{
			name: "parallel results come first and images follow in result order",
			content: []BedrockContentBlock{
				toolResultBlock("a", toolResultImageBlock("red")),
				toolResultBlock("b", toolResultImageBlock("blue")),
			},
			want: []string{"toolResult(a)[" + placeholder + "]", "toolResult(b)[" + placeholder + "]", "image:red", "image:blue"},
		},
		{
			name: "text-only sibling result is untouched",
			content: []BedrockContentBlock{
				toolResultBlock("a", toolResultImageBlock("red")),
				toolResultBlock("b", BedrockContentBlock{Text: new("closed")}),
			},
			want: []string{"toolResult(a)[" + placeholder + "]", "toolResult(b)[text:closed]", "image:red"},
		},
		{
			name:    "cachePoint after the last result ends up after the images",
			content: []BedrockContentBlock{toolResultBlock("a", toolResultImageBlock("red")), {CachePoint: cachePoint()}},
			want:    []string{"toolResult(a)[" + placeholder + "]", "image:red", "cachePoint"},
		},
		{
			name:    "trailing text stays after the images",
			content: []BedrockContentBlock{toolResultBlock("a", toolResultImageBlock("red")), {Text: new("next")}},
			want:    []string{"toolResult(a)[" + placeholder + "]", "image:red", "text:next"},
		},
		{
			name:    "documents stay nested",
			content: []BedrockContentBlock{toolResultBlock("a", BedrockContentBlock{Text: new("report")}, BedrockContentBlock{Document: &BedrockDocumentSource{}})},
			want:    []string{"toolResult(a)[text:report, document]"},
		},
		{
			name:    "results without images are left alone, empty ones included",
			content: []BedrockContentBlock{toolResultBlock("a"), toolResultBlock("b", BedrockContentBlock{Text: new("ok")})},
			want:    []string{"toolResult(a)[]", "toolResult(b)[text:ok]"},
		},
		{
			name:    "images outside tool results are left alone",
			content: []BedrockContentBlock{toolResultImageBlock("red"), {Text: new("describe this")}},
			want:    []string{"image:red", "text:describe this"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := &BedrockConverseRequest{Messages: []BedrockMessage{{Role: BedrockMessageRoleUser, Content: tt.content}}}
			hoistToolResultImages(req)
			assert.Equal(t, tt.want, describeBedrockBlocks(req.Messages[0].Content))
		})
	}
}

// TestHoistToolResultImagesThenStripCachePoints runs the two passes in the order both
// converters apply them, for a model that takes neither nested tool-result images nor
// cache points. A cachePoint left beside the hoisted image is not content: counting it
// as such skipped the placeholder, and the strip pass then left toolResult.content
// empty, which Bedrock rejects.
func TestHoistToolResultImagesThenStripCachePoints(t *testing.T) {
	placeholder := "text:" + toolResultImagePlaceholder
	req := &BedrockConverseRequest{Messages: []BedrockMessage{{
		Role:    BedrockMessageRoleUser,
		Content: []BedrockContentBlock{toolResultBlock("a", toolResultImageBlock("red"), BedrockContentBlock{CachePoint: cachePoint()})},
	}}}

	hoistToolResultImages(req)
	assert.Equal(t, []string{"toolResult(a)[" + placeholder + ", cachePoint]", "image:red"},
		describeBedrockBlocks(req.Messages[0].Content), "after hoisting")

	stripCachePointsFromBedrockRequest(req)
	assert.Equal(t, []string{"toolResult(a)[" + placeholder + "]", "image:red"},
		describeBedrockBlocks(req.Messages[0].Content), "after stripping cache points")
}

func toolResultImageChatRequest(model string) *schemas.BifrostChatRequest {
	return &schemas.BifrostChatRequest{
		Provider: schemas.Bedrock,
		Model:    model,
		Input: []schemas.ChatMessage{
			{Role: schemas.ChatMessageRoleUser, Content: &schemas.ChatMessageContent{ContentStr: new("Take a screenshot.")}},
			{Role: schemas.ChatMessageRoleAssistant, ChatAssistantMessage: &schemas.ChatAssistantMessage{
				ToolCalls: []schemas.ChatAssistantMessageToolCall{{
					ID:       new("call_a"),
					Type:     new("function"),
					Function: schemas.ChatAssistantMessageToolCallFunction{Name: new("get_screenshot"), Arguments: "{}"},
				}},
			}},
			{
				Role:            schemas.ChatMessageRoleTool,
				ChatToolMessage: &schemas.ChatToolMessage{ToolCallID: new("call_a")},
				Content: &schemas.ChatMessageContent{ContentBlocks: []schemas.ChatContentBlock{{
					Type:           schemas.ChatContentBlockTypeImage,
					ImageURLStruct: &schemas.ChatInputImage{URL: toolResultImageDataURL},
				}}},
			},
		},
	}
}

func toolResultImageResponsesRequest(model string) *schemas.BifrostResponsesRequest {
	return &schemas.BifrostResponsesRequest{
		Provider: schemas.Bedrock,
		Model:    model,
		Input: []schemas.ResponsesMessage{
			{
				Type:    new(schemas.ResponsesMessageTypeMessage),
				Role:    new(schemas.ResponsesInputMessageRoleUser),
				Content: &schemas.ResponsesMessageContent{ContentStr: new("Take a screenshot.")},
			},
			{
				Type:                 new(schemas.ResponsesMessageTypeFunctionCall),
				ResponsesToolMessage: &schemas.ResponsesToolMessage{CallID: new("call_a"), Name: new("get_screenshot"), Arguments: new("{}")},
			},
			{
				Type: new(schemas.ResponsesMessageTypeFunctionCallOutput),
				ResponsesToolMessage: &schemas.ResponsesToolMessage{
					CallID: new("call_a"),
					Output: &schemas.ResponsesToolMessageOutputStruct{
						ResponsesFunctionToolCallOutputBlocks: []schemas.ResponsesMessageContentBlock{{
							Type:                                   schemas.ResponsesInputMessageContentBlockTypeImage,
							ResponsesInputMessageContentBlockImage: &schemas.ResponsesInputMessageContentBlockImage{ImageURL: new(toolResultImageDataURL)},
						}},
					},
				},
			},
		},
	}
}

// toolResultImageLayout reports where the image landed in the last user message.
func toolResultImageLayout(t *testing.T, req *BedrockConverseRequest) string {
	t.Helper()
	for i := len(req.Messages) - 1; i >= 0; i-- {
		msg := req.Messages[i]
		if msg.Role != BedrockMessageRoleUser {
			continue
		}
		layout := describeBedrockBlocks(msg.Content)
		joined := strings.Join(layout, " | ")
		require.Contains(t, joined, "toolResult(call_a)", "last user message carries no tool result: %v", layout)
		switch {
		case strings.Contains(joined, "toolResult(call_a)[image:"):
			return "nested"
		case len(layout) == 2 && layout[0] == "toolResult(call_a)[text:"+toolResultImagePlaceholder+"]" && strings.HasPrefix(layout[1], "image:"):
			return "hoisted"
		default:
			t.Fatalf("unexpected layout: %v", layout)
		}
	}
	t.Fatal("no user message")
	return ""
}

func TestToolResultImagesGate(t *testing.T) {
	tests := []struct {
		model string
		row   string
		caps  *schemas.ModelCapabilities
		want  string
	}{
		{model: "us.openai.gpt-5.6-luna", want: "hoisted"},
		{model: "global.openai.gpt-6-astra", want: "hoisted"},
		{model: "us.xai.grok-4.6", want: "hoisted"},
		{model: "us.anthropic.claude-sonnet-4-6", want: "nested"},
		{model: "us.amazon.nova-pro-v1:0", want: "nested"},
		// Llama 4 takes nested images and rejects the hoisted layout.
		{model: "us.meta.llama4-maverick-17b-instruct-v1:0", want: "nested"},
		{model: "qwen.qwen3-vl-235b-a22b", row: "converse_false", caps: &schemas.ModelCapabilities{SupportsConverseToolResultImages: new(false)}, want: "hoisted"},
		{model: "us.openai.gpt-5.6-luna", row: "converse_true", caps: &schemas.ModelCapabilities{SupportsConverseToolResultImages: new(true)}, want: "nested"},
		// The generic multimodal tool-output flag describes the model, not Converse.
		{model: "us.openai.gpt-5.6-luna", row: "multimodal_tool_output_true", caps: &schemas.ModelCapabilities{SupportsMultimodalToolOutput: new(true)}, want: "hoisted"},
	}
	for _, tt := range tests {
		name := tt.model
		if tt.row != "" {
			name += "/" + tt.row
		}
		t.Run(name, func(t *testing.T) {
			if tt.caps != nil {
				schemas.SetCapabilityResolver(func(schemas.ModelProvider, string) *schemas.ModelCapabilities { return tt.caps })
				t.Cleanup(func() { schemas.SetCapabilityResolver(nil) })
			}
			ctx := schemas.NewBifrostContext(context.Background(), schemas.NoDeadline)

			chatReq, err := ToBedrockChatCompletionRequest(ctx, toolResultImageChatRequest(tt.model))
			require.NoError(t, err)
			assert.Equal(t, tt.want, toolResultImageLayout(t, chatReq), "chat path")

			responsesReq, err := ToBedrockResponsesRequest(ctx, toolResultImageResponsesRequest(tt.model))
			require.NoError(t, err)
			assert.Equal(t, tt.want, toolResultImageLayout(t, responsesReq), "responses path")
		})
	}
}

// TestConvertMessages_UniqueDocumentNames covers #7003: the Converse API
// rejects duplicate document names, so two untitled documents in one request
// must not both be named "document".
func TestConvertMessages_UniqueDocumentNames(t *testing.T) {
	docBlock := func() schemas.ChatContentBlock {
		return schemas.ChatContentBlock{
			Type: schemas.ChatContentBlockTypeFile,
			File: &schemas.ChatInputFile{},
		}
	}
	msg := schemas.ChatMessage{
		Role: schemas.ChatMessageRoleUser,
		Content: &schemas.ChatMessageContent{
			ContentBlocks: []schemas.ChatContentBlock{docBlock(), docBlock()},
		},
	}

	bedrockMsgs, _, err := convertMessages(t.Context(), "anthropic.claude-sonnet-5", []schemas.ChatMessage{msg})
	if err != nil {
		t.Fatalf("convertMessages: %v", err)
	}
	if len(bedrockMsgs) != 1 {
		t.Fatalf("got %d messages, want 1", len(bedrockMsgs))
	}

	seen := map[string]bool{}
	for _, content := range bedrockMsgs[0].Content {
		if content.Document == nil {
			continue
		}
		name := content.Document.Name
		if seen[name] {
			t.Fatalf("duplicate document name %q; names must be unique per request", name)
		}
		seen[name] = true
	}
	if len(seen) < 2 {
		t.Fatalf("expected at least 2 document blocks, saw %d unique names: %v", len(seen), seen)
	}
}

// TestConvertMessages_TitledDocumentsKeepTheirNames: explicit filenames are
// kept verbatim (normalized) and never receive a numeric suffix unless they
// actually collide.
func TestConvertMessages_TitledDocumentsKeepTheirNames(t *testing.T) {
	nameA := "report_pdf" // normalization maps '.' to '_' (existing behavior)
	nameB := "notes_pdf"
	mkBlock := func(n string) schemas.ChatContentBlock {
		return schemas.ChatContentBlock{
			Type: schemas.ChatContentBlockTypeFile,
			File: &schemas.ChatInputFile{Filename: &n},
		}
	}
	msg := schemas.ChatMessage{
		Role: schemas.ChatMessageRoleUser,
		Content: &schemas.ChatMessageContent{
			ContentBlocks: []schemas.ChatContentBlock{mkBlock(nameA), mkBlock(nameB)},
		},
	}

	bedrockMsgs, _, err := convertMessages(t.Context(), "anthropic.claude-sonnet-5", []schemas.ChatMessage{msg})
	if err != nil {
		t.Fatalf("convertMessages: %v", err)
	}

	var names []string
	for _, content := range bedrockMsgs[0].Content {
		if content.Document != nil {
			names = append(names, content.Document.Name)
		}
	}
	if len(names) != 2 || names[0] != nameA || names[1] != nameB {
		t.Fatalf("titled documents renamed: %v", names)
	}
}

// TestConvertMessages_TitledNameCollidesWithGeneratedSuffix covers the
// emissions-as-final-names rule: untitled, untitled, then an explicit
// "document-2" must not collide — the explicit one gets "document-2-2".
func TestConvertMessages_TitledDocumentCollidesWithGeneratedSuffix(t *testing.T) {
	first := "document"
	block := func(name *string) schemas.ChatContentBlock {
		return schemas.ChatContentBlock{
			Type: schemas.ChatContentBlockTypeFile,
			File: &schemas.ChatInputFile{Filename: name},
		}
	}
	msg := schemas.ChatMessage{
		Role: schemas.ChatMessageRoleUser,
		Content: &schemas.ChatMessageContent{
			ContentBlocks: []schemas.ChatContentBlock{
				block(nil), block(nil), block(&first),
			},
		},
	}

	bedrockMsgs, _, err := convertMessages(t.Context(), "anthropic.claude-sonnet-5", []schemas.ChatMessage{msg})
	if err != nil {
		t.Fatalf("convertMessages: %v", err)
	}

	seen := map[string]bool{}
	for _, content := range bedrockMsgs[0].Content {
		if content.Document == nil {
			continue
		}
		if seen[content.Document.Name] {
			t.Fatalf("duplicate document name %q", content.Document.Name)
		}
		seen[content.Document.Name] = true
	}
	if len(seen) != 3 {
		t.Fatalf("expected 3 unique names, saw %v", seen)
	}
}

// TestConvertMessages_UniqueNamesAcrossSeparateMessages: the review noted
// per-message namer scoping lets documents in separate messages collide.
// The namer is request-scoped, so a document in message 2 must not reuse
// message 1's generated name.
func TestConvertMessages_UniqueNamesAcrossSeparateMessages(t *testing.T) {
	mkMsg := func() schemas.ChatMessage {
		return schemas.ChatMessage{
			Role: schemas.ChatMessageRoleUser,
			Content: &schemas.ChatMessageContent{
				ContentBlocks: []schemas.ChatContentBlock{{
					Type: schemas.ChatContentBlockTypeFile,
					File: &schemas.ChatInputFile{},
				}},
			},
		}
	}

	bedrockMsgs, _, err := convertMessages(t.Context(), "anthropic.claude-sonnet-5", []schemas.ChatMessage{mkMsg(), mkMsg()})
	if err != nil {
		t.Fatalf("convertMessages: %v", err)
	}

	seen := map[string]bool{}
	for _, m := range bedrockMsgs {
		for _, content := range m.Content {
			if content.Document == nil {
				continue
			}
			if seen[content.Document.Name] {
				t.Fatalf("duplicate document name %q across messages", content.Document.Name)
			}
			seen[content.Document.Name] = true
		}
	}
	if len(seen) != 2 {
		t.Fatalf("expected 2 unique names across messages, saw %v", seen)
	}
}
