# CLI: `site`

The installation itself. `publr init` (short for `publr site init`) sets a
fresh site up: it creates the first admin and marks the site as initialised,
exactly once. Back to the [CLI reference](../cli.md).

## `init`

Set up a fresh installation: creates the first admin account. Works exactly
once: while no user exists and the site has never been initialised (the fact
is recorded, so deleting users later does not reopen it). Anyone may call it,
and afterwards nobody can, not even `--as-admin`. `publr site init` is the
same command under its namespace.

| Field | Type | Default |
|---|---|---|
| `--email` | text | required |
| `--display_name` | text | required |
| `--password` | text | generated when omitted (or `PUBLR_PASSWORD`) |

Output: `{ "user_id", "role", "password" }` (`password` only when generated).

```
$ publr init --email ada@example.com --display_name Ada
{
  "user_id": "3f9c...",
  "role": "admin"
}
```
