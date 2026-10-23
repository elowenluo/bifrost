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
