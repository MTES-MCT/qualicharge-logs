# QualiCharge Logs

This project can be used as an example alternative to
[ELK](https://www.elastic.co/elastic-stack/) when a log management and
aggregation tool is required. It is based on:

- [TimescaleDB](https://www.timescale.com) 💕
- [Vector](https://vector.dev) ❤️
- [Metabase](https://www.metabase.com) 🙌

_Maybe we should call it MTV? Or TGV if you prefer Grafana?_ 😅

---

Example screenshot from a Metabase question visualization.

![MTV screenshot](./docs/img/qualicharge-metabase-requests-logs.png)

_Yes, we had an issue at around 3PM._

---

## Why MTV?

1. First things first, we use MTV because we needed a way to analyze access logs
   from our core application to track its usage and performance (observability
   FTW).
2. ELK seemed the classical way to do so, but:
   - from a ressource-usage point-of-view, Logstash + ElasticSearch seemed too
     greedy for us and not easy to scale,
   - from a user point-of-view, we already extensively use Metabase as our data
     visualization / exploration platform, having Kibana aside seemed a burden.

Interested? In the next section, we will show you how you can configure the
[Log Drain](https://doc.scalingo.com/platform/app/log-drain) of your Scalingo
application to analyze its usage.

## How to setup MTV?

> 👉 The [`scalingo` CLI](https://doc.scalingo.com/platform/cli/start) is
> required to run commands from this tutorial.

Create a new Scalingo application that will run Vector and TimescaleDB:

```sh
# Adapt this variable name to your project
MY_APP="qualicharge-logs"

# Create the application
scalingo create "${MY_APP}"
```

### Configure TimescaleDB

Provision the postgresql addon (adapt the plan depending on your needs):

```sh
scalingo --app "${MY_APP}" addons-add postgresql postgresql-starter-512
```

Once the PostgreSQL addon has been provisionned, you should activate the
TimescaleDB extension using the interactive remote console (see the
[reference documentation](https://doc.scalingo.com/databases/postgresql/timescaledb#enabling-timescaledb)).

While you are using the `psql` CLI, create the `router` table we will use to
store access logs:

```sql
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
```

And table indexes:

```sql
CREATE INDEX ON router (method, endpoint);
CREATE INDEX ON router (host);
CREATE INDEX ON router (user_agent);
```

As we are dealing with time-series, it's time to unleash TimescaleDB! To do so,
make the `router` table an hypertable 🎉 indexed using the `requested_at`
column:

```sql
SELECT create_hypertable('router', by_range('requested_at'));
```

> 💡 Depending on your needs, feel free to adapt database schema and indexes.

### Setup and deploy Vector

Add the Vector buildpack to your buildpacks by running the following command
from the root of `MY_APP` repository:

```sh
echo "https://github.com/jmaupetit/vector-scalingo-buildpack" >> .buildpacks
```

Create a configuration file for Vector ([`vector.toml`](./vector.tml)) with the
following content (feel free to adapt it to your needs):

```toml
# Vector configuration
data_dir = "/tmp"

[sources.scalingo]
type = "http_server"
address = "0.0.0.0:${PORT}"
auth.strategy = "basic"
auth.password = "${LOGDRAIN_USER_PASSWORD}"
auth.username = "${LOGDRAIN_USER_NAME}"
decoding.codec = "vrl"
decoding.vrl.source = ". = parse_key_value!(.message)"

[transforms.access]
type = "remap"
inputs = ["scalingo"]
source = """
.duration = parse_duration!(.duration, "s")
.bytes = to_int!(.bytes)
.status = to_int!(.status)
.ip = del(.from)
.endpoint = del(.path)
.requested_at = del(.timestamp)
del(.container)
del(.protocol)
del(.referer)
del(.request_id)
del(.source_type)
"""

[sinks.timescaledb]
type = "postgres"
inputs = ["access"]
endpoint = "${SCALINGO_POSTGRESQL_URL}"
table = "router"
```

Now create a `start.sh` bash script that will be used to run vector:

```sh
#!/usr/bin/env bash

# Run vector
bin/refresh-vector . . . && \
  bin/vector --config vector.toml
```

And finally, add the corresponding `Procfile` to your project to run Vector:

```Procfile
web: bash ./start.sh
```

Now your repository tree should look like:

```
.
├── .buildpacks
├── Procfile
├── start.sh
└── vector.toml

1 directory, 4 files
```

Set environment variables required for applications' Log Drain:

```sh
LOGDRAIN_USER_PASSWORD="super-secret"
LOGDRAIN_USER_NAME="janedoe"

scalingo --app "${MY_APP}" env-set \
    LOGDRAIN_USER_PASSWORD="${LOGDRAIN_USER_PASSWORD}" \
    LOGDRAIN_USER_NAME="${LOGDRAIN_USER_NAME}"
```

Once everything has been committed and pushed to your Git forge, you will be
able to
[deploy your application to Scalingo](https://doc.scalingo.com/platform/deployment/deploy-with-git).

As Vector is really efficient with an extra low memory footprint, we invite you
to scale down your application container to an `S` instance:

```sh
scalingo --app "${MY_APP}" scale web:1:S
```

> 💡 From our tests, with around 800 requests per minute, with our
> configuration, the CPU load is lower than 1% and memory footprint below 20Mb,
> yes, you read it well **20Mb**! Beat that Logstash!

### Configure applications "Log Drain"

Once Vector is up and running, you can configure Log Drain for other
applications that should forward their logs to you Vector instance. By running
the `http_server` as a Vector source, you can pretend your Vector instance is a
Logstash instance and use the `elk` Log Drain type:

```sh
MY_OTHER_APP="qualicharge-api"

scalingo --app "${MY_OTHER_APP}" log-drains-add \
    --type elk \
    --url "https://${LOGDRAIN_USER_NAME}:${LOGDRAIN_USER_PASSWORD}@${MY_APP}.osc-fr1.scalingo.io"
```

Logs from `MY_OTHER_APP` should now be forwarded to Vector and stored in your
TimescaleDB instance 🎉

### Set data retention policy

TimescaleDB data retention policy should be configured if you don't want your
database to explode! You can refer to the official
[Scalingo documentation](https://doc.scalingo.com/databases/postgresql/timescaledb#configuring-data-retention)
to proceed.

Depending on the database plan you choose and the traffic of monitored
applications, feel free to adapt the number of database chunks you want to keep.
We choose to only keep track of the latest 15 days, but it's up to you to choose
a larger window depending on your constraints.

> 💡 Note that TimescaleDB chunks are organized by date range. If your retention
> policy partially covers a chunk date range, the underlying chunk won't be
> deleted. You will have to wait for the whole chunk to be excluded from your
> retention policy interval.
>
> Example: if your retention policy is the "now - 8 days interval" and you have
> two TimescaleDB chunks covering respectively days `[-15; -8]` and `[-7; 0]`,
> you will have to way tomorrow to delete the first chunk (`[-15; -8]`).

### Analyze your logs

We choose Metabase because it's really
[easy to deploy on Scalingo](https://doc.scalingo.com/platform/getting-started/getting-started-with-metabase),
but feel free to
[deploy Grafana](https://doc.scalingo.com/platform/getting-started/getting-started-with-grafana)
instead or any other platform that has your preference.

Once deployed, add `MY_APP` database as a PostgreSQL data source and enjoy.

> 💡 If `MY_APP` and Metabase are both deployed as Scalingo applications,
> Metabase can connect to your TimescaleDB instance without needing any extra
> configuration. That being said, we invite you to create a read-only user for
> Metabase.

## License

This work is licensed under the MIT terms (see [LICENSE](./LICENSE))
