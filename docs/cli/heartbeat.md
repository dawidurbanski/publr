# CLI: `heartbeat`

Liveness and version checks. Operations that never touch data: use them to
check that Publr is up, which version is running, and who you are calling as.
Back to the [CLI reference](../cli.md).

## `heartbeat check`

Health and version check; also reports who the caller is.

| Field | Type | Default |
|---|---|---|
| `--echo` | text | `""` |

Output: `{ "version", "echo", "caller" }`.

```
$ publr --as-admin heartbeat check --echo hi
{
  "version": "0.2.0",
  "echo": "hi",
  "caller": "system"
}
```
