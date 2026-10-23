package configstore

import (
	"testing"

	"github.com/bytedance/sonic"
	"github.com/capsohq/bifrost/core/schemas"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestGenerateKeyHash_LegacyAliasesPreserveByteShape proves that an
// unenriched alias (only ModelID set) marshals into the hasher as the legacy
// {"k":"v"} string-valued shape, which is what keeps config_hash byte-stable
// across the refactor. If MarshalJSON ever stops emitting the legacy form for
// ModelID-only entries, this test fires.
//
// Strategy: hash the same Key with two equivalent alias representations — the
// rich KeyAliases{"k": {ModelID: "v"}} and (a hand-rolled JSON for) the
// legacy "k": "v" shape — and confirm both feed identical bytes into the
// hasher by checking that the marshaled outputs match. We don't recompute the
// full SHA256 since GenerateKeyHash composes many field bytes; the marshaling
// stability of the alias map alone is the regression-prone surface.
func TestGenerateKeyHash_LegacyAliasesPreserveByteShape(t *testing.T) {
	key := schemas.Key{
		Name:    "openai-key",
		Value:   *schemas.NewSecretVar("sk-test"),
		Weight:  1.0,
		Aliases: schemas.KeyAliases{"best-model": {ModelID: "gpt-4o-deployment"}},
	}

	gotMarshal, err := sonic.Marshal(key.Aliases)
	require.NoError(t, err)
	assert.Equal(t,
		`{"best-model":"gpt-4o-deployment"}`,
		string(gotMarshal),
		"unenriched alias should marshal to the legacy string-valued wire shape; otherwise GenerateKeyHash drifts from pre-refactor rows",
	)

	// And GenerateKeyHash itself runs cleanly with the new types.
	hash, err := GenerateKeyHash(key)
	require.NoError(t, err)
	assert.NotEmpty(t, hash)
}

// TestGenerateKeyHash_RichAliasesProduceDifferentHash sanity-checks the other
// side: enriching an alias with ModelName/Family/etc. *does* change the hash,
// so genuine config changes are still detected.
func TestGenerateKeyHash_RichAliasesProduceDifferentHash(t *testing.T) {
	canonical := "gpt-4o"
	family := schemas.ModelFamilyOpenAI

	legacy := schemas.Key{
		Name:    "k",
		Value:   *schemas.NewSecretVar("sk"),
		Weight:  1.0,
		Aliases: schemas.KeyAliases{"x": {ModelID: "y"}},
	}
	rich := schemas.Key{
		Name:   "k",
		Value:  *schemas.NewSecretVar("sk"),
		Weight: 1.0,
		Aliases: schemas.KeyAliases{"x": {
			ModelID:     "y",
			ModelName:   &canonical,
			ModelFamily: &family,
		}},
	}

	legacyHash, err := GenerateKeyHash(legacy)
	require.NoError(t, err)
	richHash, err := GenerateKeyHash(rich)
	require.NoError(t, err)

	assert.NotEqual(t, legacyHash, richHash, "enriching an alias must change the key hash so config diffs are detected")
}

// TestGenerateKeyHash_UseOpenAIEndpoints: toggling only use_openai_endpoints
// changes the hash in both directions, so a config.json edit to it is applied
// instead of keeping the stored key and its old Bedrock routing, while nil and
// false hash alike so keys stored before the field existed are not rewritten.
func TestGenerateKeyHash_UseOpenAIEndpoints(t *testing.T) {
	base := schemas.Key{Name: "bedrock-key", Value: *schemas.NewSecretVar("sk"), Weight: 1.0}
	withValue := func(v *bool) schemas.Key {
		key := base
		key.UseOpenAIEndpoints = v
		return key
	}
	hashOf := func(key schemas.Key) string {
		h, err := GenerateKeyHash(key)
		require.NoError(t, err)
		return h
	}

	unset := hashOf(withValue(nil))
	off := hashOf(withValue(schemas.Ptr(false)))
	on := hashOf(withValue(schemas.Ptr(true)))
	assert.Equal(t, unset, off, "nil and false must hash alike")
	assert.NotEqual(t, off, on, "enabling use_openai_endpoints must change the hash")
	assert.NotEqual(t, on, unset, "disabling use_openai_endpoints must change the hash")
}
