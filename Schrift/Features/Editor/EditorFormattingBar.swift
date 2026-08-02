import SwiftUI

/// Whether the photo button may be offered: there must be a focused block to insert
/// into, no upload already in flight (`canInsertPhoto` also covers "content loaded"),
/// and the device must not be offline.
///
/// Offline is the odd one out and the reason this is a named function rather than an
/// inline expression: every *other* action in the bar is a local block transformation
/// the draft pipeline queues, so editing offline is supported. A photo POSTs a
/// multipart attachment and there is no queue for one — offered offline it would open
/// the picker and re-encode the chosen image only to fail. The slash menu's half lives
/// in `filteredSlashItems(query:isOffline:isLocalDocument:)`.
/// `isLocalDocument` is the load-bearing half. `isOffline` is derived from Home's last
/// *list* fetch, not from reachability — so a create that 500s while the network is fine
/// mints a local document and leaves this reading false. The upload would then POST
/// `documents/{client-minted-uuid}/attachment-upload/`, take a 404, and offer a retry that
/// can never succeed. Same rule as "Add a subpage" and the Pages drawer's "New page", both
/// of which moved to this gate; this one was missed.
func canOfferPhotoInsertion(
    hasTarget: Bool, canInsertPhoto: Bool, isOffline: Bool, isLocalDocument: Bool = false
) -> Bool {
    hasTarget && canInsertPhoto && !isOffline && !isLocalDocument
}

/// Floating formatting toolbar shown above the keyboard while editing.
///
/// The actions target the focused block (convert type, wrap the selection in
/// inline markers). Never a blind append: everything is selection-aware.
struct EditorFormattingBar: View {
    @Bindable var viewModel: EditorViewModel
    /// Disables Photo — it POSTs an attachment, which has no offline queue.
    var isOffline: Bool = false

    @Environment(LocalizationStore.self) private var loc

    private var hasTarget: Bool { viewModel.focusedBlockID != nil }

    var body: some View {
        // A fixed pill of evenly-spaced actions (matching the reference accessory
        // bar): add + the core block/inline formatters. Numbered list, inline
        // code and divider remain reachable via their Markdown shortcuts.
        HStack(spacing: DocsSpacing.space4xs) {
            barButton(icon: .add, label: loc[.editor_format_add_block], brand: true, disabled: false) {
                viewModel.insertBlock(after: viewModel.focusedBlockID, kind: .paragraph)
            }
            barButton(icon: .format_bold, label: loc[.editor_format_bold]) {
                viewModel.applyInlineMarker("**")
            }
            // `_`, and `*` would be wrong. `InlineMarkdown` honors CommonMark's
            // flanking rule for underscores, so `_x_` is emphasis that survives a
            // save while `snake_case` stays literal — and it is what BlockNote
            // itself writes. Wrapping a selected **bold** word in `*` would produce
            // `***word***`, which this scanner reads as bold(`*word`) + literal.
            barButton(icon: .format_italic, label: loc[.editor_format_italic]) {
                viewModel.applyInlineMarker("_")
            }
            barButton(
                icon: .link, label: loc[.editor_format_link],
                disabled: !viewModel.canEditLink
            ) {
                viewModel.beginLinkEditing()
            }
            barButton(icon: .format_list_bulleted, label: loc[.editor_format_bulleted_list]) {
                viewModel.convertFocusedBlock(to: .bulletItem)
            }
            barButton(icon: .checklist, label: loc[.editor_format_checklist]) {
                viewModel.convertFocusedBlock(to: .checklistItem(checked: false))
            }
            barButton(icon: .format_quote, label: loc[.editor_format_quote]) {
                viewModel.convertFocusedBlock(to: .quote)
            }
            barButton(icon: .data_object, label: loc[.editor_format_code_block]) {
                viewModel.convertFocusedBlock(to: .codeBlock(language: ""))
            }
            // Stays disabled while an upload is in flight (and before content has
            // loaded): the view model would decline anyway, so don't invite the tap.
            // Offline too — see `canOfferPhotoInsertion`.
            barButton(
                icon: .image, label: loc[.editor_format_insert_photo],
                disabled: !canOfferPhotoInsertion(
                    hasTarget: hasTarget, canInsertPhoto: viewModel.canInsertPhoto, isOffline: isOffline,
                    isLocalDocument: viewModel.isLocalDocument)
            ) {
                viewModel.requestPhotoInsertion()
            }
        }
        .padding(.horizontal, DocsSpacing.space2xs)
        .padding(.vertical, DocsSpacing.space3xs)
        // Real Liquid Glass rather than the `.ultraThinMaterial` approximation
        // this used to fake it with: the system supplies the refraction, the
        // shadow and the edge, so the hand-drawn border and shadow go with it.
        // The bar floats over the canvas, which is exactly the functional layer
        // glass is meant for.
        .glassEffect(.regular, in: Capsule())
    }

    @ViewBuilder
    private func barButton(
        icon: MaterialIcon, label: String, brand: Bool = false, disabled: Bool? = nil, action: @escaping () -> Void
    ) -> some View {
        IconButton(
            icon: icon,
            label: label,
            variant: .ghost,
            color: brand ? .brand : .neutral,
            size: .small,
            isDisabled: disabled ?? !hasTarget,
            // The buttons divide the bar's width rather than each claiming 44pt.
            // `IconButton`'s default minimum does not compress, so nine of them
            // demanded 424pt — wider than any iPhone's content column — and the
            // overflow propagated out through `safeAreaInset` to the editor's
            // outer VStack, shifting the nav bar off screen. The 44pt tap height
            // is unchanged, and the buttons stay contiguous.
            minimumTapWidth: 0,
            action: action
        )
        .frame(maxWidth: .infinity)
    }
}
