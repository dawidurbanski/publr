# CLI: `status`

Publr ships `draft` (initial), `published` (live) and `archived` (not listed);
plugins add more. Core reads only three properties of a status, `live`,
`listed` and `initial`, never its name, so a workflow plugin can add
`in_review` without the core knowing. Transitions are the named moves between
statuses that become buttons. Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `status list` | Every status and transition, core and plugins together |
