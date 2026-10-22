package schemas

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// An image_generation_call item echoed back as input carries a bare-string
// action ("generate") and the generation settings. DeepCopyResponsesMessage
// rebuilds ResponsesToolMessage field by field, so a field it does not copy is
// silently dropped: an Action left with no variant set fails MarshalJSON
// ("responses tool message action struct is empty") and the settings vanish.
// Prompt-cache breakpoint injection deep-copies input messages before it
// rewrites them, so the copy must re-encode to the same bytes as the original.
func TestDeepCopyResponsesMessagePreservesImageGenerationCall(t *testing.T) {
	raw := `{"type":"image_generation_call","id":"ig_1","status":"completed","action":"generate","result":"aGVsbG8=","background":"opaque","output_format":"png","quality":"high","revised_prompt":"a cat","size":"1024x1024"}`
	var original ResponsesMessage
	require.NoError(t, Unmarshal([]byte(raw), &original))
	require.NotNil(t, original.ResponsesToolMessage)
	require.NotNil(t, original.ResponsesToolMessage.Action)
	require.NotNil(t, original.ResponsesToolMessage.Action.ResponsesToolCallActionStr)

	want, err := Marshal(original)
	require.NoError(t, err)

	copied := DeepCopyResponsesMessage(original)
	got, err := Marshal(copied)
	require.NoError(t, err, "deep copy must keep the bare-string action")
	assert.JSONEq(t, string(want), string(got))

	// The copy owns its pointers: mutating it leaves the original intact.
	*copied.ResponsesToolMessage.Action.ResponsesToolCallActionStr = "edit"
	*copied.ResponsesToolMessage.ResponsesImageGenerationCall.Size = "512x512"
	assert.Equal(t, "generate", *original.ResponsesToolMessage.Action.ResponsesToolCallActionStr)
	assert.Equal(t, "1024x1024", *original.ResponsesToolMessage.ResponsesImageGenerationCall.Size)
}

// A JSON null action must stay absent rather than become a bare empty string:
// the string branch of UnmarshalJSON must not claim null.
func TestResponsesToolMessageNullActionStaysAbsent(t *testing.T) {
	var msg ResponsesMessage
	require.NoError(t, Unmarshal([]byte(`{"type":"image_generation_call","id":"ig_1","status":"completed","action":null,"result":"x"}`), &msg))
	require.NotNil(t, msg.ResponsesToolMessage)
	assert.Nil(t, msg.ResponsesToolMessage.Action)

	out, err := Marshal(msg)
	require.NoError(t, err)
	assert.NotContains(t, string(out), `"action"`)
}
