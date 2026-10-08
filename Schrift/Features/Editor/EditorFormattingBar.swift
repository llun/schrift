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

/// Whether the bar's File choice may be offered — the bar's half of the slash menu's
/// `requiresImmediateUpload` filter, on the same terms.
///
/// Unlike a photo, a file has no offline queue: it uploads the moment it is picked, so it
/// is withheld offline and on a document the server has not seen yet (whose id would 404).
/// Any type is accepted — `.fileImporter` asks for `.item`, and the server sniffs the
/// content and stores a zip, docx, … under an `-unsafe` key rather than refusing it.
func canOfferAttachmentInsertion(
    hasTarget: Bool, canInsertAttachment: Bool, isOffline: Bool, isLocalDocument: Bool
) -> Bool {
    hasTarget && canInsertAttachment && !isOffline && !isLocalDocument
}

/// Floating formatting toolbar shown above the keyboard while editing.
///
/// The actions target the focused block (convert type, wrap the selection in
/// inline markers). Never a blind append: everything is selection-aware.
struct EditorFormattingBar: View {
    @Bindable var viewModel: EditorViewModel
    /// Read/control availability, which withholds the File choice (it uploads at once).
    var isOffline: Bool = false

    @Environment(LocalizationStore.self) private var loc

    /// Each family button's default kind — local preferences, see `FormattingBarFormat`.
    @AppStorage(ListFormat.preferenceKey) private var defaultListFormatRaw = ListFormat.fallback.rawValue
    @AppStorage(QuoteFormat.preferenceKey) private var defaultQuoteFormatRaw = QuoteFormat.fallback.rawValue

    /// The buttons that swap the row for a set of choices: the list and quote families on
    /// a long press, and Attach (Photo or File) on a tap.
    private enum Family {
        case list
        case quote
        case attach
    }

    /// The family whose long-press choices the row shows in place of the actions, if any.
    /// An in-row swap rather than a `Menu`/context menu, so the choice is made with the
    /// same plain buttons as every other formatting action and nothing new competes with
    /// the text view for first responder mid-edit.
    @State private var choosingFamily: Family?

    private var hasTarget: Bool { viewModel.focusedBlockID != nil }

    private var defaultListFormat: ListFormat { ListFormat.stored(defaultListFormatRaw) }
    private var defaultQuoteFormat: QuoteFormat { QuoteFormat.stored(defaultQuoteFormatRaw) }

    var body: some View {
        // Keep every action circular and 44pt square. A horizontal scroll view
        // contains the row on narrow screens without widening the editor.
        ScrollView(.horizontal) {
            switch choosingFamily {
            case .list:
                formatChoices(current: defaultListFormat) { defaultListFormatRaw = $0.rawValue }
            case .quote:
                formatChoices(current: defaultQuoteFormat) { defaultQuoteFormatRaw = $0.rawValue }
            case .attach:
                attachChoices
            case nil:
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
        .onChange(of: viewModel.focusedBlockID) { choosingFamily = nil }
    }

    /// Close, then one button per member of the family. Picking one applies it to the
    /// focused block and makes it the default (`remember`); the current default is drawn
    /// in the brand colour.
    private func formatChoices<Format: FormattingBarFormat>(
        current: Format, remember: @escaping (Format) -> Void
    ) -> some View {
        HStack(spacing: DocsSpacing.space4xs) {
            barButton(icon: .close, label: loc[.common_close], disabled: false) {
                choosingFamily = nil
            }
            ForEach(Format.allCases, id: \.self) { format in
                barButton(icon: format.icon, label: loc[format.labelKey], brand: format == current) {
                    viewModel.chooseFormat(format)
                    remember(format)
                    choosingFamily = nil
                }
                // The brand colour marks the default for sighted users; VoiceOver gets the trait.
                .accessibilityAddTraits(format == current ? .isSelected : [])
            }
        }
    }

    private var canOfferPhoto: Bool {
        canOfferPhotoInsertion(hasTarget: hasTarget, canInsertPhoto: viewModel.canInsertPhoto)
    }

    private var canOfferFile: Bool {
        canOfferAttachmentInsertion(
            hasTarget: hasTarget, canInsertAttachment: viewModel.canInsertAttachment,
            isOffline: isOffline, isLocalDocument: viewModel.isLocalDocument)
    }

    /// Close, Photo, File. Each choice closes the row before presenting its picker.
    private var attachChoices: some View {
        HStack(spacing: DocsSpacing.space4xs) {
            barButton(icon: .close, label: loc[.common_close], disabled: false) {
                choosingFamily = nil
            }
            barButton(icon: .image, label: loc[.editor_format_insert_photo], disabled: !canOfferPhoto) {
                choosingFamily = nil
                viewModel.requestPhotoInsertion()
            }
            barButton(icon: .description, label: loc[.editor_format_insert_file], disabled: !canOfferFile) {
                choosingFamily = nil
                viewModel.requestAttachmentInsertion()
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
                longPressAction: { choosingFamily = .list }
            ) {
                guard choosingFamily == nil else { return }
                viewModel.tapFormat(defaultListFormat)
            }
            // Outdent and Indent, for the keyboards that have no Tab key. Shown only
            // on a list item — the only blocks that nest — and each disabled where
            // the item can't move that way (already at the top, or with no item
            // above it to nest under).
            if viewModel.focusedBlockIsListItem, let focusedBlockID = viewModel.focusedBlockID {
                barButton(
                    icon: .format_indent_decrease, label: loc[.editor_format_outdent],
                    disabled: !viewModel.canOutdentFocusedBlock
                ) {
                    viewModel.outdentListItem(blockID: focusedBlockID)
                }
                barButton(
                    icon: .format_indent_increase, label: loc[.editor_format_indent],
                    disabled: !viewModel.canIndentFocusedBlock
                ) {
                    viewModel.indentListItem(blockID: focusedBlockID)
                }
            }
            // Quote and code share one button on the same terms.
            barButton(
                icon: defaultQuoteFormat.icon, label: loc[defaultQuoteFormat.labelKey],
                longPressLabel: loc[.editor_format_change_quote_type],
                longPressAction: { choosingFamily = .quote }
            ) {
                guard choosingFamily == nil else { return }
                viewModel.tapFormat(defaultQuoteFormat)
            }
            // One Attach button for both uploads: a tap swaps the row for Photo and
            // File. Disabled only when neither can be offered (no target, content not
            // loaded, or an upload already in flight); offline it still opens, with File
            // disabled — see `canOfferAttachmentInsertion`.
            barButton(
                icon: .attach_file, label: loc[.editor_format_attach],
                disabled: !(canOfferPhoto || canOfferFile)
            ) {
                choosingFamily = .attach
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
