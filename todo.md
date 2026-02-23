# TimelessUI TODO

## P0 — Blocks Adoption (Must-Have for V1)

- [ ] **Metrics explorer page** — Browse/search all metric series, select time range, render charts. Currently only available via canvas graph elements which require manual placement. This is the "Explore" equivalent — the first thing any admin reaches for.
- [ ] **Log search page** — Full-page searchable/filterable log viewer (level, message, metadata, time range, pagination). The canvas log_stream element is a tiny preview; need a dedicated page for log investigation across all hosts.
- [ ] **Trace search page** — Dedicated trace search with waterfall/flame chart for span parent-child hierarchy and timing. Filter by service, operation, duration, status. Canvas trace_stream only lists recent spans.
- [ ] **Alert management UI** — View, create, edit, delete, enable/disable alert rules. Alert history with ack/resolve. Currently alerts exist in timeless_metrics but the standalone UI has no way to manage them.
- [ ] **Bulk scrape target management** — File-based discovery (read YAML/JSON of targets, like Prometheus `file_sd_configs`), DNS-based discovery (SRV records), bulk import endpoint (POST array). Can't onboard 10K+ devices one at a time.

## P1 — Blocks Serious Use at Scale

- [ ] **Dashboard templates / auto-generated overviews** — Pre-built views: "Top 10 CPU", "Memory by host group", "Error rate heatmap", "BEAM VM health", "Phoenix overview". Auto-generate an overview dashboard from discovered metrics. New users shouldn't face a blank canvas.
- [ ] **Template variables (Grafana-style)** — Host variable dropdowns so a single canvas template works for any host. Create a template by host type (e.g. "web server", "database") and switch the active host live. Enables one canvas design → N hosts.
- [ ] **Top-N / group-by views** — Aggregate across hosts: worst 10 by CPU, most errors, highest latency. Fleet management requires seeing the forest, not individual trees.
- [ ] **Canvas hierarchy / drill-down groups** — Datacenter → rack → host drill-down. Collapsed groups with aggregate status indicators. SVG with 10K elements won't render — need hierarchical views that only show the current level of detail.
- [ ] **Cross-signal correlation** — Click a metric spike → see logs/traces from that time window. Click a slow trace → see related logs. Ties the three pillars together in the standalone UI. (Already done in LiveDashboard plugin.)
- [ ] **Virtual viewport rendering** — Only render canvas elements visible in the current viewport. Required for canvases with hundreds+ elements.

## P2 — Team & Network Use

- [ ] **Syslog receiver** — UDP/TCP 514 → TimelessLogs. Network gear (switches, routers, firewalls, APs) speaks syslog, not OTel. This is 80% of a network admin's fleet. Alternative: document recommended external collector (telegraf, vector, fluentbit).
- [ ] **SNMP poller / trap receiver** — SNMP → TimelessMetrics. Same rationale — network devices don't expose Prometheus endpoints. Even basic SNMP GET polling on an interval would cover most use cases.
- [ ] **Notification routing** — Escalation policies (if not ack'd in 15m, page on-call), routing rules (disk alerts → infra team, app errors → dev team), silence/maintenance windows ("ignore rack-3 alerts during maintenance").
- [ ] **User/team RBAC** — Role-based access beyond canvas sharing (viewer/editor/admin roles). Shared alert configurations. Audit log of who changed what.
- [ ] **Retention/storage management page** — Configure retention policies per signal, see data lifecycle, storage usage breakdown. Currently config-only with no UI visibility.
- [ ] **Documentation** — README for timeless_stack (currently placeholder), deployment guide, Docker Compose examples.

## P3 — Polish & Differentiation

- [ ] **PromQL in standalone UI** — Admins coming from Grafana/Prometheus expect to type `rate(http_requests_total[5m])` and get a chart. The backend already has basic PromQL support.
- [ ] **Export/sharing** — Export canvas or chart as PNG/PDF for incident reports. Read-only share links with token auth for stakeholders.
- [ ] **Error grouping** — Group exceptions by type, show occurrence counts, stack traces. Logs capture errors but there's no structured error tracking view.
- [ ] **Slow query view** — Surface Ecto queries by duration, identify N+1 patterns. Metrics are collected but not surfaced in an actionable way.
- [ ] **SLA/SLO tracking** — Define targets (e.g. 99.9% < 500ms), track error budgets and burn rate.
- [ ] **Log-based metrics** — Extract metrics from log patterns (count errors/min, parse structured fields into time series).
- [ ] **Notification integrations** — Slack, email, PagerDuty for alerts (currently webhook-only).
- [ ] **Grafana datasource compatibility** — Full PromQL support so users can optionally point Grafana at timeless_metrics.
- [ ] **Heatmaps** — Fleet-wide distribution visualization (e.g. CPU usage across all hosts as a color grid).
