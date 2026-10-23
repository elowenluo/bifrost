package bedrock

import (
	"context"
	"testing"
	"time"

	"github.com/capsohq/bifrost/core/schemas"
)

// TestBedrockInvokeStreamStateLivesOutsideTheContext: the per-stream block-index map
// grows with the stream, so the context may hold only its id (AGENTS.md hard rule),
// and the manager entry must be released on the terminal event or, for a stream that
// never sends one, when the request context ends.
func TestBedrockInvokeStreamStateLivesOutsideTheContext(t *testing.T) {
	countStates := func() int {
		n := 0
		bedrockInvokeStreamStates.Range(func(any, any) bool { n++; return true })
		return n
	}
	before := countStates()

	ctx, cancel := schemas.NewBifrostContextWithCancel(context.Background())
	defer cancel()
	state := getOrCreateBedrockInvokeStreamState(ctx)
	state.rememberBlockIndex("id:srvtoolu_1", 3)
	if _, ok := ctx.Value(bedrockInvokeStreamStateKey).(string); !ok {
		t.Fatalf("context holds %T, want only the state's id string", ctx.Value(bedrockInvokeStreamStateKey))
	}
	if got := lookupBedrockInvokeStreamState(ctx); got != state {
		t.Fatal("lookup did not return the stored state")
	}
	if idx, ok := lookupBedrockInvokeStreamState(ctx).takeBlockIndex("id:srvtoolu_1"); !ok || idx != 3 {
		t.Fatalf("takeBlockIndex = %d, %v, want 3, true", idx, ok)
	}

	if _, _, err := ToBedrockInvokeMessagesStreamResponse(ctx, &schemas.BifrostResponsesStreamResponse{
		Type:     schemas.ResponsesStreamResponseTypeCompleted,
		Response: &schemas.BifrostResponsesResponse{Model: "anthropic.claude-sonnet-4-6"},
	}); err != nil {
		t.Fatalf("Completed event: %v", err)
	}
	if lookupBedrockInvokeStreamState(ctx) != nil || countStates() != before {
		t.Fatal("the terminal event must release the stream's state")
	}

	abandoned, cancelAbandoned := schemas.NewBifrostContextWithCancel(context.Background())
	getOrCreateBedrockInvokeStreamState(abandoned).rememberBlockIndex("oi:0", 0)
	if countStates() != before+1 {
		t.Fatalf("states = %d, want %d", countStates(), before+1)
	}
	cancelAbandoned()
	deadline := time.Now().Add(2 * time.Second)
	for countStates() != before && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if countStates() != before {
		t.Fatal("a stream whose request context ended without a terminal event leaked its state")
	}
}
