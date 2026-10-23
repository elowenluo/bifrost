package integrations

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/capsohq/bifrost/core/schemas"
)

// The raw systemone body is kept before post-hooks run, so it is relayed only while it
// still carries the processed answers; once a post-hook changes an answer the client gets
// the processed response instead.
func TestTypesafeDecisionConverterRelaysRawOnlyWhileAnswersMatch(t *testing.T) {
	var convert DecisionResponseConverter
	for _, route := range CreateTypesafeRouteConfigs("/typesafe") {
		if route.DecisionResponseConverter != nil {
			convert = route.DecisionResponseConverter
		}
	}
	if convert == nil {
		t.Fatal("no Typesafe decision route")
	}
	raw := json.RawMessage(`{"model":"jev-1.13.0","answers":{"is_spam":{"type":"noul","noul":0.9}}}`)
	response := func(value float64) *schemas.BifrostDecisionResponse {
		return &schemas.BifrostDecisionResponse{
			Model:   "jev-1.13.0",
			Answers: map[string]schemas.DecisionAnswer{"is_spam": {Kind: schemas.DecisionKindNoul, Value: value}},
			ExtraFields: schemas.BifrostResponseExtraFields{
				Provider:    schemas.Typesafe,
				RawResponse: raw,
			},
		}
	}

	got, err := convert(nil, response(0.9))
	if err != nil {
		t.Fatalf("convert: %v", err)
	}
	if _, isRaw := got.(json.RawMessage); !isRaw {
		t.Fatalf("unchanged answers: got %T, want the raw body", got)
	}

	got, err = convert(nil, response(0.1))
	if err != nil {
		t.Fatalf("convert: %v", err)
	}
	if _, isRaw := got.(json.RawMessage); isRaw {
		t.Fatal("a post-hook's changed answer was dropped in favour of the raw body")
	}
	body, _ := json.Marshal(got)
	if want := `"noul":0.1`; !json.Valid(body) || !strings.Contains(string(body), want) {
		t.Fatalf("converted body %s does not carry %s", body, want)
	}
}
