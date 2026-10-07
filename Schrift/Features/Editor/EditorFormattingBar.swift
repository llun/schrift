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
/// in `filteredSlashItems(query:)`.
/// `isLocalDocument` is the load-bearing half. `isOffline` is derived from Home's last
/// *list* fetch, not from reachability — so a create that 500s while the network is fine
/// mints a local document and leaves this reading false. The upload would then POST
/// `documents/{client-minted-uuid}/attachment-upload/`, take a 404, and offer a retry that
/// can never succeed. Same rule as "Add a subpage" and the Pages drawer's "New page", both
/// of which moved to this gate; this one was missed.
/// Photo insertion no longer gates on connectivity or on whether the server has seen the
/// document. A photo picked with neither is stored on this device and uploaded by the replay,
/// exactly as an offline text edit is queued and pushed.
///
/// The `isOffline`/`isLocalDocument` **parameters are gone**, not merely ignored — the same
/// discipline `editorToolbarActions` follows, so the gate cannot quietly return without a
/// deliberate signature change.
func canOfferPhotoInsertion(hasTarget: Bool, canInsertPhoto: Bool) -> Bool {
    hasTarget && canInsertPhoto
}

/// Floating formatting toolbar shown above the keyboard while editing.
///
/// The actions target the focused block (convert type, wrap the selection in
/// inline markers). Never a blind append: everything is selection-aware.
struct EditorFormattingBar: View {
    @Bindable var viewModel: EditorViewModel

    @Environment(LocalizationStore.self) private var loc

    /// The list button's default kind — a local preference, see `ListFormat`.
    @AppStorage(ListFormat.preferenceKey) private var defaultListFormatRaw = ListFormat.fallback.rawValue

    /// True while the row shows the list button's long-press choices in place of the
    /// actions. An in-row swap rather than a `Menu`/context menu, so the choice is made
    /// with the same plain buttons as every other formatting action and nothing new
    /// competes with the text view for first responder mid-edit.
    @State private var isChoosingListFormat = false

    private var hasTarget: Bool { viewModel.focusedBlockID != nil }

    private var defaultListFormat: ListFormat { ListFormat.stored(defaultListFormatRaw) }

    var body: some View {
        // Keep every action circular and 44pt square. A horizontal scroll view
        // contains the row on narrow screens without widening the editor.
        ScrollView(.horizontal) {
            if isChoosingListFormat {
                listFormatChoices
            } else {
                actions
            }
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DocsSpacing.space2xs)
        .padding(.vertical, DocsSpacing.space3xs)
        // Real Liquid Glass rather than the `.ultraThinMaterial` approximation
        // this used to fake it with: the system supplies the refraction, the
        // shadow and the edge, so the hand-drawn border and shadow go with it.
        // The bar floats over the canvas, which is exactly the functional layer
        // glass is meant for.
        .glassEffect(.regular, in: Capsule())
        // The choices act on the focused block; moving the caret elsewhere ends the choice.
        .onChange(of: viewModel.focusedBlockID) { isChoosingListFormat = false }
    }

    /// Close, then one button per list kind. Picking one applies it to the focused block
    /// and makes it the default; the current default is drawn in the brand colour.
    private var listFormatChoices: some View {
        HStack(spacing: DocsSpacing.space4xs) {
            barButton(icon: .close, label: loc[.common_close], disabled: false) {
                isChoosingListFormat = false
            }
            ForEach(ListFormat.allCases, id: \.self) { format in
                barButton(icon: format.icon, label: loc[format.labelKey], brand: format == defaultListFormat) {
                    viewModel.chooseListFormat(format)
                    defaultListFormatRaw = format.rawValue
                    isChoosingListFormat = false
                }
                // The brand colour marks the default for sighted users; VoiceOver gets the trait.
                .accessibilityAddTraits(format == defaultListFormat ? .isSelected : [])
            }
        }
    }

    private var actions: some View {
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
            // One list button: a tap applies the default kind (toggling a block already
            // in that list kind back to a paragraph), a long press offers all three.
            barButton(
                icon: defaultListFormat.icon, label: loc[defaultListFormat.labelKey],
                longPressLabel: loc[.editor_format_change_list_type],
                longPressAction: { isChoosingListFormat = true }
            ) {
                guard !isChoosingListFormat else { return }
                viewModel.tapListFormat(defaultListFormat)
            }
            barButton(icon: .format_quote, label: loc[.editor_format_quote]) {
                viewModel.convertFocusedBlock(to: .quote)
            }
            barButton(icon: .data_object, label: loc[.editor_format_code_block]) {
                viewModel.convertFocusedBlock(to: .codeBlock(language: ""))
            }
            // Stays disabled while an upload is in flight (and before content has
            // loaded): the view model would decline anyway, so don't invite the tap.
            // No longer gated on connectivity — see `canOfferPhotoInsertion`.
            barButton(
                icon: .image, label: loc[.editor_format_insert_photo],
                disabled: !canOfferPhotoInsertion(
                    hasTarget: hasTarget, canInsertPhoto: viewModel.canInsertPhoto)
            ) {
                viewModel.requestPhotoInsertion()
            }
        }
    }

    @ViewBuilder
    private func barButton(
        icon: MaterialIcon, label: String, brand: Bool = false, disabled: Bool? = nil,
        longPressLabel: String? = nil, longPressAction: (() -> Void)? = nil, action: @escaping () -> Void
    ) -> some View {
        IconButton(
            icon: icon,
            label: label,
            variant: .ghost,
            color: brand ? .brand : .neutral,
            size: .small,
            isDisabled: disabled ?? !hasTarget,
            action: action,
            longPressAction: longPressAction,
            longPressLabel: longPressLabel
        )
    }
}
