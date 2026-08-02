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

- **Canvas Editor** — Drag-and-drop dashboard builder with live-updating graph elements
- **Scrape Targets** — Configure Prometheus-compatible scrape endpoints
- **Poller** — ICMP ping monitoring with cron-based scheduling, bounded-concurrency dispatch, and CRUD management for hosts, requests, and schedules

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

The poller system collects ICMP ping metrics from configured network hosts on cron schedules. It is disabled by default and can be enabled in config:

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
- **Requests** (`/poller/requests`) — Polling templates (ICMP ping, with SNMP/Prometheus planned)
- **Schedules** (`/poller/schedules`) — Cron expressions matching host and request groups
- **Dashboard** (`/poller`) — Live scheduler and dispatcher stats

The scheduler ticks every minute, evaluates cron expressions, resolves host x request combinations, and enqueues jobs to a bounded-concurrency dispatcher. Metrics are written to TimelessMetrics via `apply/3`.

## Configuration

| Key | Default | Description |
|-----|---------|-------------|
| `:enabled` | `false` | Start the poller supervisor |
| `:max_concurrency` | `50` | Max concurrent polling jobs |
| `:icmp_timeout_ms` | `1000` | ICMP ping timeout in milliseconds |
| `:icmp_count` | `1` | Number of pings per host |
| `:metrics_store` | `:timeless_metrics` | TimelessMetrics store name |

## Experimental Rust metrics data plane

The metrics API POC can run as a separately supervised Rust OS process. This
mode is opt-in: Phoenix owns sessions, Canvas, dashboards, poller policy, and
product data, while the child process exclusively owns the telemetry database.
Only Canvas's historical graph query is routed through this boundary today.

```elixir
config :timeless_ui, :metrics_data_plane,
  enabled: true,
  binary: "/opt/timeless/bin/timeless-metrics-api",
  extension: "/opt/timeless/lib/libtimeless_ext.so",
  database: "/var/lib/timeless/metrics.db",
  listen: "127.0.0.1:19439"

config :timeless_canvas, :data_source,
  module: TimelessUI.MetricsDataPlane.CanvasSource,
  config: %{
    source: :data_plane,
    fallback: MyExistingCanvasDataSource,
    fallback_config: %{}
  },
  poll_interval: 2_000
```

The listener must be an IPv4 loopback address. The client owns no SQLite or
libSQL connection and rejects incomplete or invalid responses as one failed
operation. On normal OTP shutdown the owner sends `SIGTERM`; the Rust server
drains and flushes before exiting, and the supervisor leaves no orphan process.
`bench/metrics_data_plane_boundary.exs` measures the incremental supervision
lookup and SIGKILL-to-ready recovery against release artifacts in the sibling
`timeless-libsql` checkout.

## Deployment

See the [Phoenix deployment guides](https://hexdocs.pm/phoenix/deployment.html).
