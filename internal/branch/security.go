// SPDX-License-Identifier: AGPL-3.0-or-later

package branch

import (
	"fmt"
	"os"
	"sort"
	"strings"
)

// Least-privilege access for agents and the MCP server, and the vdb_admin role
// that alone may override the destructive-DDL guardrail.
//
// Agent branches used to hand out the superuser's DSN, and MCP run_sql ran as the
// superuser, so an agent could switch off the guardrail or the ledger's
// append-only triggers. Both now use non-superuser login roles.
// VECTORADB_AGENT_SUPERUSER=1 and VECTORADB_MCP_SUPERUSER=1 restore the previous
// behaviour for setups that depend on it (e.g. an agent running CREATE EXTENSION).

// truthyEnv reports whether an environment variable is set to a true value.
func truthyEnv(key string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(key))) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// AgentSuperuser reports whether agent branches get the legacy superuser DSN.
func AgentSuperuser() bool { return truthyEnv("VECTORADB_AGENT_SUPERUSER") }

// MCPSuperuser reports whether MCP run_sql runs as the legacy superuser.
func MCPSuperuser() bool { return truthyEnv("VECTORADB_MCP_SUPERUSER") }

// ensureLoginRole creates (or updates) a non-superuser login role on a branch with
// its own password. It has the same shape as the gateway's per-user roles
// (EnsureUserRole): a member of vdbclient that acts as vdbclient by default, so
// data access and object ownership match every other client.
func ensureLoginRole(branchName, role, password string) error {
	sql := fmt.Sprintf(`DO $do$
DECLARE r text := %s;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
    EXECUTE format('CREATE ROLE %%I LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOBYPASSRLS INHERIT IN ROLE vdbclient', r);
  END IF;
  EXECUTE format('ALTER ROLE %%I WITH LOGIN NOSUPERUSER PASSWORD %%L', r, %s);
  EXECUTE format('ALTER ROLE %%I SET role = vdbclient', r);
END $do$;`, quoteLiteral(role), quoteLiteral(password))
	return psqlStdin(branchName, sql)
}

// ClientQueryText runs SQL on a branch as the non-superuser vdbclient role and
// returns psql's rendered output; on failure the returned string is psql's error.
// tool becomes the session's application_name. On a non-agent branch the change
// is attributed to tool as an agent; agent branches keep their per-database agent
// attribution (set when the branch was created).
func ClientQueryText(branchName, sql, tool string) (string, error) {
	return ClientQueryTextAs(branchName, sql, tool, tool)
}

// ClientQueryTextAs is ClientQueryText with the Blackbox actor given
// separately from the tool. The MCP server passes the account its API key
// belongs to, so its changes name a person rather than just "mcp"; tool still
// says how they arrived. An empty actor falls back to the tool, as before.
func ClientQueryTextAs(branchName, sql, tool, actor string) (string, error) {
	if branchName == "" {
		branchName = "main"
	}
	if actor == "" {
		actor = tool
	}
	args := []string{"docker", "exec", "-e", "PGAPPNAME=" + tool}
	if !strings.HasPrefix(branchName, "agent-") {
		// An agent branch carries its actor and session as database defaults
		// (sessionDefaultsSQL), so injecting here would override them.
		args = append(args, "-e", fmt.Sprintf("PGOPTIONS=-c vdb.actor=%s -c vdb.actor_kind=agent", actor))
	}
	args = append(args, container(branchName),
		"psql", "-U", "vdbclient", "-d", pgDatabase, "-P", "pager=off", "-c", sql)
	out, err := captureCombined(args[0], args[1:]...)
	if err != nil {
		return out, fmt.Errorf("%s", out)
	}
	return out, nil
}

// GrantAdmin makes email's per-user role a member of vdb_admin on a branch, so
// that user may override the destructive-DDL guardrail there.
func GrantAdmin(branchName, email string) error {
	if err := EnsureUserRole(branchName, email); err != nil {
		return err
	}
	return psqlStdin(branchName, fmt.Sprintf(`DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vdb_admin') THEN
    CREATE ROLE vdb_admin NOLOGIN;
  END IF;
  EXECUTE format('GRANT vdb_admin TO %%I', %s);
END $do$;`, quoteLiteral(email)))
}

// RevokeAdmin removes email's per-user role from vdb_admin on a branch.
func RevokeAdmin(branchName, email string) error {
	return psqlStdin(branchName, fmt.Sprintf(`DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vdb_admin')
     AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = %[1]s) THEN
    EXECUTE format('REVOKE vdb_admin FROM %%I', %[1]s);
  END IF;
END $do$;`, quoteLiteral(email)))
}

// ListAdmins returns the roles that are members of vdb_admin on a branch.
func ListAdmins(branchName string) ([]string, error) {
	out, err := Query(branchName, `SELECT r.rolname FROM pg_auth_members m
  JOIN pg_roles r ON r.oid = m.member
  WHERE m.roleid = (SELECT oid FROM pg_roles WHERE rolname = 'vdb_admin')
  ORDER BY 1`)
	if err != nil {
		return nil, fmt.Errorf("listing admins on %q: %w", branchName, err)
	}
	return strings.Fields(out), nil
}

// RunningBranches lists running branches with main first, excluding the
// disposable restore target and the read-only HA standby (roles and the ledger
// can't be changed there).
func RunningBranches() ([]string, error) {
	out, err := capture("docker", "ps", "--filter", "name=vec-", "--format", "{{.Names}}")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, n := range strings.Fields(out) {
		bn := strings.TrimPrefix(n, "vec-")
		if bn == n || bn == "restore" || bn == "standby" {
			continue
		}
		names = append(names, bn)
	}
	sort.Slice(names, func(i, j int) bool {
		if (names[i] == "main") != (names[j] == "main") {
			return names[i] == "main"
		}
		return names[i] < names[j]
	})
	return names, nil
}
