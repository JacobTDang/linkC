# CLOUD drill-in: stats in place

## Goal

Tapping a CLOUD row expands it in the sidebar instead of bouncing to the browser: public
IP, CPU (1h mean from OCI monitoring), uptime, and state — the "is it mine and healthy?"
glance, in-panel.

## Data

`OracleService` gains `func detail(for id: String) async -> OracleDetail?` — fetched on
expand only (never polled): one `oci compute instance list-vnics` (public IP) and one
`oci monitoring metric-data summarize-metrics-data` (CpuUtilization 1h mean, last 24h,
JMESPath-trimmed). Pure parsers TDD'd like DockerStats; failures render "—" per field,
never collapse the row. Results cached per instance id for the panel session; a re-tap
collapses, tap-again re-uses cache with a manual refresh affordance in the expansion.

## UI

`CloudRow` becomes expandable (chevron rotation, sectionSpring): expanded shows a compact
grid — `ip · cpu · up since` — plus a quiet "console" QuietLink for the rare full-console
need (the browser link demotes from tap-target to opt-in link). Only one row expanded at
a time.

## Testing

Parsers TDD'd; service contract over FakeRunner (detail fetch is on-demand only — no
detail calls during refresh()).
