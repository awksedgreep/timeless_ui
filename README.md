<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/logo-light.svg">
    <img src="docs/logo-light.svg" width="300" alt="Timeless">
  </picture>
</p>

<h3 align="center">Real-Time Metrics Visualization & Network Monitoring</h3>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/awksedgreep/timeless_ui.svg" alt="License"></a>
</p>

---

> "I found it ironic that the first thing you do to time series data is squash the timestamp. That's how the name Timeless was born." --Mark Cotner

A Phoenix LiveView application for real-time metrics visualization and network monitoring. Part of the [Timeless](https://github.com/awksedgreep/timeless_metrics) stack.

## Features

- **Canvas Editor** — Drag-and-drop dashboard builder with live-updating graph elements (`/canvas`)
- **Scrape Targets** — Configure Prometheus-compatible scrape endpoints, with per-target reported health
- **Poller** — Network monitoring over ICMP ping, SNMP (get/walk/bulkwalk with table support), Prometheus scrape, and MikroTik REST, with cron-based scheduling, bounded-concurrency dispatch, and CRUD management for hosts, requests, and schedules
- **Observability** — Admin-only LiveDashboard at `/admin/observability` carrying the Timeless logs and traces pages, including streaming live tails, read through the Rust data-plane clients
- **Accounts & administration** — Authenticated sessions with login rate limiting and lockout, forced password change, admin user management, and an admin API for data-plane status/retry, Ed25519 key rotation/revocation, auth policies, and token issuance/revocation

## Getting Started

```bash
mix setup          # Install deps, create DB, build assets
mix phx.server     # Start at http://localhost:4000
```

Or inside IEx:

```bash
iex -S mix phx.server
```

## Poller

The poller system collects network metrics from configured hosts on cron schedules. It is disabled by default and can be enabled in config:

```elixir
# config/dev.exs
config :timeless_ui, :poller, enabled: true
```

### ICMP Permissions

ICMP ping requires raw socket access, which needs root privileges (or `CAP_NET_RAW` on Linux). Run the server with one of:

```bash
# Option 1: setcap on the BEAM executable (recommended, one-time setup)
sudo setcap cap_net_raw=ep $(elixir -e 'IO.puts :os.find_executable("beam.smp")')

# Option 2: run with sudo (development only)
sudo mix phx.server
```

Without raw socket permissions, ICMP pings will fail and log warnings, but the rest of the application will function normally.

### Poller Architecture

- **Hosts** (`/poller/hosts`) — Network devices to poll, organized by groups
- **Requests** (`/poller/requests`) — Polling templates: ICMP ping, SNMP get/walk/bulkwalk, Prometheus scrape, and MikroTik REST
- **Schedules** (`/poller/schedules`) — Cron expressions matching host and request groups
- **Dashboard** (`/poller`) — Live scheduler and dispatcher stats

The scheduler ticks every minute, evaluates cron expressions, resolves host x request combinations, and enqueues jobs to a bounded-concurrency dispatcher. Samples go through the configured metrics writer — embedded TimelessMetrics by default; the Stack routes them to the Rust metrics data plane.

## Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `:enabled` | `false` | Start the poller supervisor |
| `:max_concurrency` | `50` | Max concurrent polling jobs |
| `:icmp_timeout_ms` | `1000` | ICMP ping timeout in milliseconds |
| `:icmp_count` | `1` | Number of pings per host |
| `:metrics_store` | `:timeless_metrics` | TimelessMetrics store name |

## Rust/libSQL telemetry data plane

The production Stack starts three signal-specific Rust OS processes for
metrics, logs, and traces. Each process exclusively owns its `timeless-libsql`
database; Phoenix owns sessions, token issuance, authorization policy,
tenancy, Canvas, dashboards, poller policy, cluster administration, and UI
state. Startup detects or converts legacy storage before a child becomes
ready. There is no per-request fallback to Rocket or an embedded storage
owner.

The listeners default to IPv4 loopback. UI clients own no SQLite/libSQL
connection and reject incomplete or invalid responses as one failed
operation. On normal OTP shutdown the logs producer drains first, then each
owner receives `SIGTERM`, flushes accepted work, checkpoints, and exits. The
supervisor bounds escalation/restart and reaps every child.

`timeless_stack` supplies the production configuration and defaults to
`TIMELESS_DATA_PLANE=rust`. See its
`docs/telemetry_data_plane_compatibility.md` for supported query/ingest
surfaces and `docs/telemetry_data_plane_operations.md` for migration, backup,
restore, rollback, and cleanup. Direct component development may still enable
one owner explicitly in application config; that is a test/development seam,
not a second production ownership model.

## Deployment

See the [Phoenix deployment guides](https://hexdocs.pm/phoenix/deployment.html).
