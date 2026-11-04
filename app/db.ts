import pg from "pg";
const { Pool } = pg;

// The four lines on screen. PG_REPLICAS points to "replicas:5432", an HAProxy
// that spreads the connections between replica1 and replica2 in round-robin.
const primary = new Pool({ connectionString: process.env.PG_PRIMARY });
const replicas = new Pool({ connectionString: process.env.PG_REPLICAS });
export const write = (sql: string, params?: unknown[]) => primary.query(sql, params);
export const read = (sql: string, params?: unknown[]) => replicas.query(sql, params);

// For the transaction (BEGIN ... COMMIT needs a single connection) and for the measurements.
export { primary, replicas };
