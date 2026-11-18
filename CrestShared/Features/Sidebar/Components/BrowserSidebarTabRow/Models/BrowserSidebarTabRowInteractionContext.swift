import Observation
import SwiftUI

/// Whether the pointer is over a sidebar row.
///
/// A row keeps it in an object, not in its own `@State`, because handing a
/// state's binding to the row's parts reads the state in the row's body, so
/// every hover change rebuilt the whole row: its gestures, menus, drag and
/// label. Only the parts that read `isHovering` now redraw when it changes.
@Observable
@MainActor
final class BrowserSidebarRowHover {
    private(set) var isHovering = false

    /// Follows the pointer, touching observers only when it changes.
    func set(_ isHovering: Bool) {
        if self.isHovering != isHovering { self.isHovering = isHovering }
    }
}

/// The live half of a sidebar tab row: the state it keeps between events and
/// the actions its parts trigger.
///
/// Kept apart from `BrowserSidebarTabRowConfiguration` so the row's pieces can
/// take the bindings they need without any of them owning the state.
struct BrowserSidebarTabRowInteractionContext {
    let hover: BrowserSidebarRowHover
    let isRenaming: Bool
    let draftTitle: Binding<String>
    let isTitleFocused: FocusState<Bool>.Binding
    let isChoosingIcon: Binding<Bool>
    let activate: () -> Void
    let beginRenaming: () -> Void
    let beginChangingIcon: () -> Void
    let setEmojiIcon: (String) -> Void
    let resetIcon: () -> Void
    let commitTitle: () -> Void
    let cancelTitleEditing: () -> Void
    /// Isolated because the platform seam that delivers an auxiliary click
    /// hands it straight to a main-actor gesture recognizer.
    let dismissFromAuxiliaryClick: @MainActor () -> Void
}
