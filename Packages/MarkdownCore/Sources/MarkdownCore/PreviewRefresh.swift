import Foundation

/// Settings ▸ Rendering ▸ "Update preview automatically" (default on) and View ▸ Render Preview (⌘R). Pure so the rule is tested.
public enum PreviewRefresh {
    /// Whether a change of the document's text re-renders the preview by itself. With the setting off only Render Preview does,
    /// except for the first text of a document: a preview that has rendered nothing yet would stay empty (or show the previous tab).
    public static func rendersOnEdit(autoRender: Bool, hasRendered: Bool) -> Bool { autoRender || !hasRendered }
}
