CREATE KEYSPACE IF NOT EXISTS deliveries
  WITH replication = {'class': 'NetworkTopologyStrategy', 'replication_factor': 3};

CREATE TABLE deliveries.positions (
  courier_id   bigint,
  day          date,
  recorded_at  timestamp,
  lat          double,
  lon          double,
  PRIMARY KEY ((courier_id, day), recorded_at)
) WITH CLUSTERING ORDER BY (recorded_at DESC)
  AND default_time_to_live = 172800;
