/// Design token definitions.
/// Token vocabulary mirrors Tailwind 4's defaults so DS components can use familiar class names.
/// Spacing/sizing scales are NOT in a table — they're computed at resolve time (Tailwind 4 numeric: N → N * 0.25rem).
///
/// Color values are CSS custom property references (`var(--foo)`); the actual oklch values
/// live in design-system/src/styles/input.css `:root { ... }` and `.dark { ... }` blocks,
/// which JIT emits verbatim alongside the resolved utilities.

pub const TokenEntry = struct {
    property: []const u8,
    value: []const u8,
};

/// Color scale — semantic tokens referencing CSS custom properties.
/// Mirrors design-system/src/styles/input.css `@theme inline` block.
/// Sidebar tokens deliberately omitted (skipped per Q2 — admin doesn't currently use them).
pub const colors = .{
    // Surface
    .{ "background", "var(--background)" },
    .{ "foreground", "var(--foreground)" },
    .{ "card", "var(--card)" },
    .{ "card-foreground", "var(--card-foreground)" },
    .{ "popover", "var(--popover)" },
    .{ "popover-foreground", "var(--popover-foreground)" },

    // Action
    .{ "primary", "var(--primary)" },
    .{ "primary-foreground", "var(--primary-foreground)" },
    .{ "secondary", "var(--secondary)" },
    .{ "secondary-foreground", "var(--secondary-foreground)" },
    .{ "muted", "var(--muted)" },
    .{ "muted-foreground", "var(--muted-foreground)" },
    .{ "accent", "var(--accent)" },
    .{ "accent-foreground", "var(--accent-foreground)" },

    // Semantic status
    .{ "destructive", "var(--destructive)" },
    .{ "error", "var(--error)" },
    .{ "error-foreground", "var(--error-foreground)" },
    .{ "success", "var(--success)" },
    .{ "success-foreground", "var(--success-foreground)" },
    .{ "warning", "var(--warning)" },
    .{ "warning-foreground", "var(--warning-foreground)" },

    // Borders & rings
    .{ "border", "var(--border)" },
    .{ "input", "var(--input)" },
    .{ "ring", "var(--ring)" },

    // Sidebar surface (revisited Q2 — DS sidebar component uses these).
    .{ "sidebar", "var(--sidebar)" },
    .{ "sidebar-foreground", "var(--sidebar-foreground)" },
    .{ "sidebar-primary", "var(--sidebar-primary)" },
    .{ "sidebar-primary-foreground", "var(--sidebar-primary-foreground)" },
    .{ "sidebar-accent", "var(--sidebar-accent)" },
    .{ "sidebar-accent-foreground", "var(--sidebar-accent-foreground)" },
    .{ "sidebar-border", "var(--sidebar-border)" },
    .{ "sidebar-ring", "var(--sidebar-ring)" },

    // Gray scale (raw Tailwind 4 values — used by gallery shell markup).
    .{ "gray-50", "oklch(0.985 0 0)" },
    .{ "gray-100", "oklch(0.97 0 0)" },
    .{ "gray-200", "oklch(0.922 0 0)" },
    .{ "gray-300", "oklch(0.87 0 0)" },
    .{ "gray-400", "oklch(0.708 0 0)" },
    .{ "gray-500", "oklch(0.556 0 0)" },
    .{ "gray-600", "oklch(0.445 0 0)" },
    .{ "gray-700", "oklch(0.373 0 0)" },
    .{ "gray-800", "oklch(0.269 0 0)" },
    .{ "gray-900", "oklch(0.205 0 0)" },
    .{ "gray-950", "oklch(0.145 0 0)" },

    // Constants
    .{ "transparent", "transparent" },
    .{ "white", "#fff" },
    .{ "black", "#000" },
    .{ "current", "currentColor" },
};

/// Border radius — mirrors `--radius-*` in input.css.
pub const radius = .{
    .{ "none", "0" },
    .{ "sm", "calc(var(--radius) * 0.6)" },
    .{ "md", "calc(var(--radius) * 0.8)" },
    .{ "lg", "var(--radius)" },
    .{ "xl", "calc(var(--radius) * 1.4)" },
    .{ "2xl", "calc(var(--radius) * 1.8)" },
    .{ "3xl", "calc(var(--radius) * 2.2)" },
    .{ "full", "9999px" },
};

/// Font size — mirrors `--text-*` in input.css.
pub const font_size = .{
    .{ "xs", "0.75rem" },
    .{ "sm", "0.875rem" },
    .{ "md", "1rem" },
    .{ "lg", "1.125rem" },
    .{ "xl", "1.25rem" },
    .{ "2xl", "1.5rem" },
};

pub const line_height_for_size = .{
    .{ "xs", "1.125rem" },
    .{ "sm", "1.25rem" },
    .{ "md", "1.5rem" },
    .{ "lg", "1.75rem" },
    .{ "xl", "1.875rem" },
    .{ "2xl", "2rem" },
};

/// Font weight.
pub const font_weight = .{
    .{ "normal", "400" },
    .{ "medium", "500" },
    .{ "semibold", "600" },
    .{ "bold", "700" },
};

/// max-w-* / max-h-* named scale — matches Tailwind 4 defaults.
pub const max_size = .{
    .{ "3xs", "16rem" },
    .{ "2xs", "18rem" },
    .{ "xs", "20rem" },
    .{ "sm", "24rem" },
    .{ "md", "28rem" },
    .{ "lg", "32rem" },
    .{ "xl", "36rem" },
    .{ "2xl", "42rem" },
    .{ "3xl", "48rem" },
    .{ "4xl", "56rem" },
    .{ "5xl", "64rem" },
    .{ "6xl", "72rem" },
    .{ "7xl", "80rem" },
    .{ "full", "100%" },
    .{ "none", "none" },
};

/// Shadow scale — mirrors `--shadow-*` in input.css.
pub const shadow = .{
    .{ "xs", "0 1px 2px 0 oklch(0 0 0 / 0.05)" },
    .{ "sm", "0 1px 3px 0 oklch(0 0 0 / 0.06)" },
    .{ "md", "0 2px 8px oklch(0 0 0 / 0.08)" },
    .{ "lg", "0 8px 24px oklch(0 0 0 / 0.12)" },
    .{ "xl", "0 20px 40px oklch(0 0 0 / 0.16)" },
    .{ "none", "0 0 #0000" },
};

/// Opacity scale (used by color modifiers like `bg-muted/40` and the future `opacity-N` utility).
/// 5%-step coverage matches Tailwind 4.
pub const opacity = .{
    .{ "0", "0" },
    .{ "5", "0.05" },
    .{ "10", "0.1" },
    .{ "15", "0.15" },
    .{ "20", "0.2" },
    .{ "25", "0.25" },
    .{ "30", "0.3" },
    .{ "35", "0.35" },
    .{ "40", "0.4" },
    .{ "45", "0.45" },
    .{ "50", "0.5" },
    .{ "55", "0.55" },
    .{ "60", "0.6" },
    .{ "65", "0.65" },
    .{ "70", "0.7" },
    .{ "75", "0.75" },
    .{ "80", "0.8" },
    .{ "85", "0.85" },
    .{ "90", "0.9" },
    .{ "95", "0.95" },
    .{ "100", "1" },
};
