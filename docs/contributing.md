# Contributing

## Coding Conventions

### Zig Style
- Follow Zig standard style (enforced by `zig fmt`)
- Prefer explicit allocators over hidden allocations
- Use `errdefer` for cleanup
- Return errors, don't panic (except for programmer errors)

### Naming
- Files: `snake_case.zig`
- Functions: `camelCase`
- Types: `PascalCase`
- Constants: `SCREAMING_SNAKE_CASE` or `snake_case` depending on context

### Error Handling
- Define domain-specific errors in each module
- Propagate errors up, handle at HTTP boundary
- Return proper HTTP status codes (400, 404, 500)

### HTML Generation
- Escape user content before inserting into HTML
- Use multiline strings (`\\`) for HTML templates
- Keep templates readable — break into helper functions

## Common Tasks

### Adding a new route
1. Add route in `http.zig` router
2. Create handler function
3. If admin route, wrap with auth middleware

### Adding a new field type
1. Add type to field type enum in `cms.zig`
2. Add rendering case in `templates/entries.zig` `renderField`
3. Add any JS handling in `static/admin.js`

### Modifying the schema
1. Update schema in `db.zig`
2. Add migration logic (check schema version, apply changes)
3. Test with fresh DB and existing DB

## Testing

- Unit tests in each module using `test` blocks
- Integration tests that spin up server and make HTTP requests
- Test with: `zig build test`

## What NOT to Do

- Don't add npm or any JS build step
- Don't add dependencies that fail the [decision flow](dependencies.md)
- Don't add runtime plugin loading — plugins are comptime only
- Don't add multiple database backends — SQLite only
- Don't add config format options — JSON only
- Don't add features not in the plan without explicit approval
- Don't use Zig packages from the ecosystem — write it yourself or vendor C
