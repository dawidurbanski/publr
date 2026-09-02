# CLI: `record`

A record is one **document** of one type in one status. The document is the
record's data: one JSON object whose keys are the type's field names and whose
values follow each field's kind (`{"title":"Hello","body":"…","views":3}`),
validated on every write; title, slug, status, `changed` and `version` sit
beside it. Every write bumps `version`, and `--expected_version` refuses to
overwrite a change you have not seen.

Two axes. **Status** is publication: `draft`, `published`, `archived`,
`deleted`, moved by `record transition` (and `publish`/`delete` as shortcuts);
every move is reversible, `record purge` is the only thing that removes. **Changed**
is editing: `record save` on a live record (or one that already has pending edits)
parks the document as a *pending copy* and sets `changed`; the live document is
untouched until `record publish` applies the copy or `record discard_changes` drops
it. Unpublish, archive and delete keep pending edits as they are. Whenever a live
document is replaced, the old one is kept as a revision (`snapshot list`).
Anonymous callers see live records of public types; signed-in users see and
change what their role allows. Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `record create --type <t> --document <json> [--status <s>]` | Create; title from the type's `title_field`; when the type has a `slug` field it is taken from the document or generated from the field's `source` (or the title), unique per type |
| `record get --id <id> [--purpose delivery\|edit] [--slot <s>]` | Read one record: the live document (`delivery`), the pending copy when changed (`edit`), or a named slot for previews |
| `record save --id <id> --document <json> [--expected_version <n>]` | Write the document: straight in for drafts, parked as pending edits on live records; `conflict` if `version` moved |
| `record publish --id <id> [--expected_version <n>]` | Make the latest document live: draft → published, or apply pending edits; one `record.published` either way |
| `record discard_changes --id <id>` | Drop pending edits, keep the document |
| `record transition --id <id> --to <status> [--expected_version <n>]` | Move between statuses (see `status list`); into a live status applies pending edits, out of one keeps them |
| `record list --type <t> [--status] [--changed true\|false] [--search] [--filter_field --filter_value] [--order] [--limit] [--offset]` | List; filter on any field by path (`views`, `seo.title`, `tags` by target id), full text over `searchable` ones; live values only |
| `record delete --id <id>` | Move to `deleted` (reversible: `record transition --to draft`) |
| `record purge --id <id>` | Remove for good, snapshots included (admins) |
| `record referrers --id <id>` | Who points at this record (or media item), and through which field |
| `record validate --type <t> --document <json>` | Report every problem without saving |

```
$ publr --as ada@example.com record create --type post \
    --document '{"title":"Hello, world","body":"First post"}'
{ "id": "a1b2…", "status": "draft", "slug": "hello-world", "version": 1 }
$ publr --as ada@example.com record publish --id a1b2…
{ "status": "published", "changed": false, "version": 2 }
$ publr --as ada@example.com record save --id a1b2… --document '{"title":"Hello again","body":"…"}'
{ "version": 3, "slug": "hello-world", "changed": true }     # parked; live still says "Hello, world"
$ publr --as ada@example.com record publish --id a1b2…
{ "status": "published", "changed": false, "version": 4 }    # now it says "Hello again"
$ publr record list --type post            # anonymous: live records of public types
```
