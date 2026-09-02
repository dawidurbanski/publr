# CLI: `content_type`

Content types are data: a handle, names, whether the type is public, and a
list of fields. Definitions are JSON (`publr types create --help` spells out
every key and field kind). Signed-in users may read types; changing them needs
an admin. Anonymous callers never see type definitions, only the live records
of public types. Back to the
[CLI reference](../cli.md); how content is modelled is in
[Architecture](../architecture.md#content).

| Command | What |
|---|---|
| `content_type create --definition <json>` | Create a type; admins only |
| `content_type update --type <handle\|id> --definition <json> [--drop_content true]` | Change a type; existing records follow (see below) |
| `content_type get --type <handle\|id>` | Read the full definition |
| `content_type list` | List types |
| `content_type delete --type <handle\|id> [--force true]` | Delete; refuses while records exist unless forced |
| `content_type validate --definition <json>` | Report every problem without saving |

Field kinds: `string`, `text`, `richtext`, `slug`, `email`, `url`, `boolean`,
`integer`, `number`, `datetime`, `select`, `image`, `reference`, `group`,
`repeater`. A field can be `required`, `searchable` (full-text), `many`
(reference/repeater), sit in the `main` or `side` position, and carry
`options` (`min`, `max`, `min_len`, `max_len`, `choices`, `source` for slugs,
`to` for references, `rows`). Every field can be filtered on; a repeater
cannot contain another repeated field.

Changing a type: added fields need nothing. A removed field is refused while
records hold values for it, unless `--drop_content true` deletes them. A kind
change converts values row by row when it is allowed and every value fits
(string to text/richtext/slug/email/url/select/integer/number, text to
richtext and back, slug/email/url/select to string or text, integer to number
or string, number to string or integer if whole, boolean to string, datetime to
integer, single reference to many, many to single when no record has more than
one); otherwise the update is refused. References, images, groups and
repeaters never convert to another kind: remove and re-add.

```
$ publr --as ada@example.com content_type create --definition '{"handle":"post","name":"Post",
  "name_plural":"Posts","public":true,"fields":[
  {"name":"title","label":"Title","kind":"string","required":true},
  {"name":"slug","label":"Slug","kind":"slug","options":{"source":"title"}},
  {"name":"body","label":"Body","kind":"richtext","searchable":true}]}'
{ "id": "7c2d…", "handle": "post" }
```
