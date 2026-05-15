//! Schema System Plugin API
//!
//! Re-exports field builders + the runtime content-type registry.
//!
//! Example:
//! ```zig
//! const publr = @import("publr_api");
//!
//! // Iterate every registered content type at runtime.
//! for (publr.schema.all()) |def| {
//!     // def.type_id, def.display_name, def.fields, …
//! }
//!
//! // Look up a content type by id.
//! const def = publr.schema.findById("post") orelse return;
//! ```

const field = @import("field");
const schema_registry = @import("schema_registry");
const content_type = @import("content_type");

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

/// Pure-data content type descriptor for the runtime registry.
pub const ContentTypeDef = content_type.ContentTypeDef;

/// Build a ContentTypeDef from a struct literal.
pub const contentType = content_type.contentType;

/// Compile-in content type slice — populated by build-time auto-discovery.
pub const compiled_in_types = schema_registry.compiled_in_types;

// =========================================================================
// Registry Functions
// =========================================================================

/// Runtime registry lookup — returns the pure-data `ContentTypeDef`.
pub const findById = schema_registry.findById;
pub const findByHandle = schema_registry.findByHandle;

/// Check if a content type ID is reserved (core types).
pub const isReserved = schema_registry.isReserved;

// =========================================================================
// Schema Data
// =========================================================================

/// Iterate every registered content type at runtime. Yields compile-in,
/// WASM-loaded, and DB-defined descriptors uniformly.
pub const all = schema_registry.all;
