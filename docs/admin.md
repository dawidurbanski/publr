# Admin

A plain HTML admin, served by the same binary at `/admin`: no stylesheet, no
script, browser defaults only. It is a thin adapter over the operations, like
the CLI and the REST API: every form posts to a handler that calls one
operation with the signed-in user's grant, then redirects. It is a stopgap
until the PTSX admin lands; nothing in it is meant to be pretty.

```
publr serve --port 8080      # then open http://127.0.0.1:8080/admin
```

| Path | What |
|---|---|
| `/admin` | Sends you to setup, login or content |
| `/admin/setup` | First run: create the administrator (`site init`) and sign in |
| `/admin/login`, `/admin/logout` | Session cookie in, session cookie out |
| `/admin/types` | The content types; links to the editor and to each type's content |
| `/admin/types/new`, `/admin/types/<handle>` | Content type editor: handle, names, public, title field, and a fields table (name, label, kind, required, remove; three empty rows for new fields); delete with "also delete its records". Plugin-declared (system) types show their owner, their declared fields locked, and accept added fields |
| `/admin/content?type=<handle>` | The records of a type, filterable by status; a link to create one |
| `/admin/content/new?type=<handle>` | Create a record: a form built from the type's fields |
| `/admin/content/<id>/revisions`, `…/revisions/<seq>` | Every version of a record (newest first: kind, title, when, by); one version field by field, with "Restore this version" (a normal save, so parked as pending changes on a live record) |
| `/admin/content/<id>` | Edit a record: one input per field; Save (straight in for drafts, "Save as pending changes" on live records); Publish / Publish changes, Discard changes; Unpublish, Archive, Delete, Restore; Purge for administrators |

Fields render by kind: strings and slugs as inputs, text and richtext as
textareas, numbers as number inputs, booleans as checkboxes, selects as
selects; groups, repeaters and `many` fields are edited as JSON. Saves carry
`expected_version`, so a stale edit answers `Conflict`; an invalid document
lists its problems (`record validate`). The edit form shows the pending copy
when the record has unpublished changes, and the list marks such records
*(changed)*.

Every POST is same-origin only and carries the session's CSRF token as a
hidden field; anonymous requests are sent to the login page. Private types
and their records never appear to anyone who may not read them.
