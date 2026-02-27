# TimelessUI

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

## Deployment

See the [Phoenix deployment guides](https://hexdocs.pm/phoenix/deployment.html).
