package logstore

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// TestMCPToolLogFiltersMatchMultiValueAttribution: the enterprise user/access-profile
// path records every team, customer and business unit in the JSON-array columns and
// may leave the scalar column NULL. MCP log search must find such a row by any of its
// ids on Postgres, as log search does, while still matching scalar-only rows.
func TestMCPToolLogFiltersMatchMultiValueAttribution(t *testing.T) {
	db := trySetupPostgresDB(t)
	if db == nil {
		t.Skip("Postgres not available")
	}
	ctx := context.Background()
	require.NoError(t, db.Exec("DROP TABLE IF EXISTS mcp_tool_logs CASCADE").Error)
	require.NoError(t, db.Exec("CREATE TABLE IF NOT EXISTS migrations (id VARCHAR(255) PRIMARY KEY)").Error)
	require.NoError(t, db.Exec("DELETE FROM migrations").Error)
	require.NoError(t, triggerMigrations(ctx, db, testLogger{}))
	store := &RDBLogStore{db: db, logger: testLogger{}}

	now := time.Now().UTC().Truncate(time.Millisecond)
	scalarTeam := "t-scalar"
	require.NoError(t, store.BatchCreateMCPToolLogsIfNotExists(ctx, []*MCPToolLog{
		{
			ID: "mcp-multi", Timestamp: now, CreatedAt: now, ToolName: "search", ServerLabel: "srv", Status: "success",
			TeamIDsParsed: []string{"t1", "t2"}, CustomerIDsParsed: []string{"c1"}, BusinessUnitIDsParsed: []string{"bu1"},
		},
		{
			ID: "mcp-scalar", Timestamp: now, CreatedAt: now, ToolName: "search", ServerLabel: "srv", Status: "success",
			TeamID: &scalarTeam,
		},
	}))

	ids := func(filters MCPToolLogSearchFilters) []string {
		t.Helper()
		res, err := store.SearchMCPToolLogs(ctx, filters, PaginationOptions{Limit: 10, SortBy: "timestamp", Order: "desc"})
		require.NoError(t, err)
		out := make([]string, 0, len(res.Logs))
		for _, l := range res.Logs {
			out = append(out, l.ID)
		}
		return out
	}
	require.Equal(t, []string{"mcp-multi"}, ids(MCPToolLogSearchFilters{TeamIDs: []string{"t2"}}), "team in team_ids")
	require.Equal(t, []string{"mcp-multi"}, ids(MCPToolLogSearchFilters{CustomerIDs: []string{"c1"}}), "customer in customer_ids")
	require.Equal(t, []string{"mcp-multi"}, ids(MCPToolLogSearchFilters{BusinessUnitIDs: []string{"bu1"}}), "business unit in business_unit_ids")
	require.Equal(t, []string{"mcp-scalar"}, ids(MCPToolLogSearchFilters{TeamIDs: []string{"t-scalar"}}), "scalar team_id still matches")
	require.Empty(t, ids(MCPToolLogSearchFilters{TeamIDs: []string{"t9"}}))
}

// TestMultiValueAttributionFiltersSQLite: the same array-only attribution must
// match on SQLite, for MCP log search and log search alike. A malformed array
// column must not fail the query.
func TestMultiValueAttributionFiltersSQLite(t *testing.T) {
	store := newTestSQLiteStore(t)
	ctx := context.Background()

	now := time.Now().UTC().Truncate(time.Millisecond)
	scalarTeam := "t-scalar"
	require.NoError(t, store.BatchCreateMCPToolLogsIfNotExists(ctx, []*MCPToolLog{
		{
			ID: "mcp-multi", Timestamp: now, CreatedAt: now, ToolName: "search", ServerLabel: "srv", Status: "success",
			TeamIDsParsed: []string{"t1", "t2"}, CustomerIDsParsed: []string{"c1"}, BusinessUnitIDsParsed: []string{"bu1"},
		},
		{
			ID: "mcp-scalar", Timestamp: now, CreatedAt: now, ToolName: "search", ServerLabel: "srv", Status: "success",
			TeamID: &scalarTeam,
		},
	}))
	require.NoError(t, store.db.Exec("UPDATE mcp_tool_logs SET team_ids = 'not json' WHERE id = 'mcp-scalar'").Error)

	mcpIDs := func(filters MCPToolLogSearchFilters) []string {
		t.Helper()
		res, err := store.SearchMCPToolLogs(ctx, filters, PaginationOptions{Limit: 10, SortBy: "timestamp", Order: "desc"})
		require.NoError(t, err)
		out := make([]string, 0, len(res.Logs))
		for _, l := range res.Logs {
			out = append(out, l.ID)
		}
		return out
	}
	require.Equal(t, []string{"mcp-multi"}, mcpIDs(MCPToolLogSearchFilters{TeamIDs: []string{"t2"}}), "team in team_ids")
	require.Equal(t, []string{"mcp-multi"}, mcpIDs(MCPToolLogSearchFilters{CustomerIDs: []string{"c1"}}), "customer in customer_ids")
	require.Equal(t, []string{"mcp-multi"}, mcpIDs(MCPToolLogSearchFilters{BusinessUnitIDs: []string{"bu1"}}), "business unit in business_unit_ids")
	require.Equal(t, []string{"mcp-scalar"}, mcpIDs(MCPToolLogSearchFilters{TeamIDs: []string{"t-scalar"}}), "scalar team_id still matches")
	require.Empty(t, mcpIDs(MCPToolLogSearchFilters{TeamIDs: []string{"t9"}}))

	require.NoError(t, store.BatchCreateIfNotExists(ctx, []*Log{
		{
			ID: "log-multi", Timestamp: now, CreatedAt: now, Object: "chat.completion", Provider: "openai", Model: "gpt-4o", Status: "success",
			TeamIDsParsed: []string{"t1", "t2"}, CustomerIDsParsed: []string{"c1"}, BusinessUnitIDsParsed: []string{"bu1"},
		},
		{
			ID: "log-scalar", Timestamp: now, CreatedAt: now, Object: "chat.completion", Provider: "openai", Model: "gpt-4o", Status: "success",
			TeamID: &scalarTeam,
		},
	}))
	logIDs := func(filters SearchFilters) []string {
		t.Helper()
		res, err := store.SearchLogs(ctx, filters, PaginationOptions{Limit: 10, SortBy: "timestamp", Order: "desc"})
		require.NoError(t, err)
		out := make([]string, 0, len(res.Logs))
		for _, l := range res.Logs {
			out = append(out, l.ID)
		}
		return out
	}
	require.Equal(t, []string{"log-multi"}, logIDs(SearchFilters{TeamIDs: []string{"t2"}}), "log team in team_ids")
	require.Equal(t, []string{"log-multi"}, logIDs(SearchFilters{CustomerIDs: []string{"c1"}}), "log customer in customer_ids")
	require.Equal(t, []string{"log-multi"}, logIDs(SearchFilters{BusinessUnitIDs: []string{"bu1"}}), "log business unit in business_unit_ids")
	require.Equal(t, []string{"log-scalar"}, logIDs(SearchFilters{TeamIDs: []string{"t-scalar"}}), "log scalar team_id still matches")
	require.Empty(t, logIDs(SearchFilters{TeamIDs: []string{"t9"}}))
}
