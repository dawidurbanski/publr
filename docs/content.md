# Content

How Publr models what it stores. The operations are documented in the CLI
reference ([content_type](adapters/cli/content_type.md), [record](adapters/cli/record.md),
[status](adapters/cli/status.md)); the tables in [Database schema](schema.md).

A content type is data: a name and a list of fields, stored in the database,
editable at runtime.

A record is one record of one type in one status. Its document is a JSON
object shaped by the type's fields. It is validated on every write and stored
as rows, one row per field value (`records` + `record_values`). So every
field can be filtered and sorted, references and images are pointers to the
records they name, and Publr always knows where something is referenced. Reads
put the document back together from its rows.

Everything that has fields is a record of some type, in the same two tables:
records, authors, later media items. A type may be private
(`public: false`): only signed-in callers see it. A plugin declares the types
it needs in code (`pub const content_types`) and they are created when the
database opens; it may also keep state in fields on its own types. Plugins
extend storage by adding types and fields, never tables.

Publr records who created a record and who last changed it. Who gets credited
is content: a reference field to an `author` record, chosen by editors; only
users who have an author record can be picked.

Media will be a record type too. An image field points at a media record;
caption, alt and credit are its fields.

Two axes describe where a record is. **Status** is publication: a registry,
`draft`, `published`, `archived`, `deleted` in the core, moved by transitions
(a plugin can add `scheduled` or `in_review`); every move is reversible,
`record purge` removes for good. **Changed** is editing: saving a live record
parks the document as a pending copy (`slot = pending` in the same value
rows) and marks the record `changed`; the live document stays until
`record publish` applies the copy or `record discard_changes` drops it.
Unpublish, archive and delete keep pending edits as they are, so nothing is
ever lost by moving status. Readers get both fields; "published with changes"
is `status = published, changed = true`, and a rule of thumb for plugins: if
it is about whether or when the record is live, it is a status; if it is a
grouping or an editing state, it is derived from records (release membership
via references, pending edits via `changed`).

Whenever a live document is replaced, the old one is kept as a **snapshot**
of kind `revision`: a frozen, read-only copy in its own table, never queried
by field, never edited, restored by a normal save. Plugins take snapshots of
their own kinds (`snapshot take`), prune them, and build releases, schedules
and environments on the same pieces: slots for parked copies, snapshots for
history, system types for their own records. They never add columns to the
core.
