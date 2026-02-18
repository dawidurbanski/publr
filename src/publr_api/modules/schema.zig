//! Schema System Plugin API
//!
//! Re-exports field builders, schema registry, and content type metadata.
//! All functions are comptime — no bound API needed.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! // Inspect registered content types
//! inline for (publr.schema.content_types, 0..) |CT, i| {
//!     // CT.type_id, CT.display_name, CT.schema, etc.
//! }
//!
//! // Query registry at runtime
//! const info = publr.schema.getTypeInfo("post");
//! ```

const field = @import("field");
const schema_registry = @import("schema_registry");
const schemas = @import("schemas");

// =========================================================================
// Field Builders (comptime — for defining content type schemas)
// =========================================================================

pub const String = field.String;
pub const Text = field.Text;
pub const Slug = field.Slug;
pub const Ref = field.Ref;
pub const Select = field.Select;
pub const Boolean = field.Boolean;
pub const DateTime = field.DateTime;
pub const Image = field.Image;
pub const Integer = field.Integer;
pub const Number = field.Number;
pub const RichText = field.RichText;
pub const Email = field.Email;
pub const Url = field.Url;
pub const Taxonomy = field.Taxonomy;
pub const humanize = field.humanize;

// =========================================================================
// Field Types
// =========================================================================

pub const FieldDef = field.FieldDef;
pub const RenderContext = field.RenderContext;
pub const StorageHint = field.StorageHint;
pub const MetaValueType = field.MetaValueType;
pub const Position = field.Position;
pub const TranslatableMode = field.TranslatableMode;

// =========================================================================
// Registry Types
// =========================================================================

pub const ContentTypeEntry = schema_registry.ContentTypeEntry;
pub const FieldInfo = schema_registry.FieldInfo;
pub const TypeInfo = schema_registry.TypeInfo;

// =========================================================================
// Registry Functions (NOT: getIds, getCoreIds, getBySource, getAllTaxonomyIds)
// =========================================================================

/// Find a content type by ID at comptime.
pub const findById = schema_registry.findById;

/// Find a content type by ID at runtime.
pub const findByIdRuntime = schema_registry.findByIdRuntime;

/// Get type info (fields, metadata) for a content type ID.
pub const getTypeInfo = schema_registry.getTypeInfo;

/// Check if a content type ID is reserved (core types).
pub const isReserved = schema_registry.isReserved;

// =========================================================================
// Schema Data (comptime tuples from schemas module)
// =========================================================================

/// All registered content type definitions (comptime tuple).
/// Use with `inline for` to iterate at comptime.
pub const content_types = schemas.content_types;

/// All registered type info (runtime-queryable slice).
pub const registered_types = schema_registry.registered_types;
