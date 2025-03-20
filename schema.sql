-- Create the router table
CREATE TABLE router (
  requested_at TIMESTAMPTZ NOT NULL,
  bytes INT CONSTRAINT positive_bytes CHECK (bytes > 0),
  duration REAL,
  ip INET,
  host VARCHAR(100),
  method VARCHAR(7),
  endpoint VARCHAR,
  status INT CONSTRAINT positive_status CHECK (status > 0),
  user_agent VARCHAR
);

-- Create indexes
CREATE INDEX ON router (host, user_agent, method, endpoint, requested_at DESC);

-- Make the router table an hypertable indexed by `requested_at`
SELECT create_hypertable('router', by_range('requested_at'));

-- Create the data retention procedure
CREATE OR REPLACE PROCEDURE generic_retention (config jsonb)
LANGUAGE PLPGSQL
AS $$
DECLARE
  drop_after interval;
    schema varchar;
    name varchar;
BEGIN
  SELECT jsonb_object_field_text (config, 'drop_after')::interval INTO STRICT drop_after;

  IF drop_after IS NULL THEN
    RAISE EXCEPTION 'Config must have drop_after';
  END IF;

  -- You can modify the following query to add a more precise retention policy.
  FOR schema, name IN SELECT hypertable_schema, hypertable_name FROM timescaledb_information.hypertables
  LOOP
    RAISE NOTICE '%', format('%I.%I', schema, name);
    PERFORM drop_chunks(format('%I.%I', schema, name), older_than => drop_after);
    COMMIT;
  END LOOP;
END
$$;

-- Example call to clean up old chunks
-- call generic_retention(config => '{"drop_after":"15 days"}');
