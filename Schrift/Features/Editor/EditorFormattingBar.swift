import SwiftUI

/// Whether the Attach row's Photo choice may be offered: a focused block to insert into and
/// no upload already in flight (`canInsertPhoto` also covers "content loaded").
///
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

/// Whether the bar's Attach button is enabled: it opens the Photo/File choices, so it is
/// disabled only when neither choice could be taken. Offline it stays enabled for Photo
/// (which queues) while File inside it is disabled.
func canOfferAttach(photo: Bool, file: Bool) -> Bool {
    photo || file
}

/// Floating formatting toolbar shown above the keyboard while editing.
///
/// The actions target the focused block (convert type, wrap the selection in
/// inline markers). Never a blind append: everything is selection-aware.
struct EditorFormattingBar: View {
    @Bindable var viewModel: EditorViewModel
    /// Read/control availability, which withholds the File choice (it uploads at once).
    /// Required, not defaulted: a call site that forgot it would offer File offline.
    let isOffline: Bool

    @Environment(LocalizationStore.self) private var loc

    /// Each family button's default kind — local preferences, see `FormattingBarFormat`.
    @AppStorage(TextStyleFormat.preferenceKey) private var defaultTextStyleRaw = TextStyleFormat.fallback.rawValue
    @AppStorage(ListFormat.preferenceKey) private var defaultListFormatRaw = ListFormat.fallback.rawValue
    @AppStorage(QuoteFormat.preferenceKey) private var defaultQuoteFormatRaw = QuoteFormat.fallback.rawValue

    /// The buttons that swap the row for a set of choices: the text-style, list and quote
    /// families on a long press, and Attach (Photo or File) on a tap.
    private enum Family {
        case textStyle
        case list
        case quote
        case attach
    }

    /// The family whose long-press choices the row shows in place of the actions, if any.
    /// An in-row swap rather than a `Menu`/context menu, so the choice is made with the
    /// same plain buttons as every other formatting action and nothing new competes with
    /// the text view for first responder mid-edit.
    @State private var choosingFamily: Family?

    /// Which edges have hidden content, from the row's scroll geometry — drives the fade.
    @State private var fadeEdges = ScrollFadeEdges()
    private let fadeWidth: CGFloat = 24

    private var hasTarget: Bool { viewModel.focusedBlockID != nil }

    private var defaultTextStyle: TextStyleFormat { TextStyleFormat.stored(defaultTextStyleRaw) }
    private var defaultListFormat: ListFormat { ListFormat.stored(defaultListFormatRaw) }
    private var defaultQuoteFormat: QuoteFormat { QuoteFormat.stored(defaultQuoteFormatRaw) }

    var body: some View {
        // Keep every action circular and 44pt square. A horizontal scroll view
        // contains the row on narrow screens without widening the editor.
        ScrollView(.horizontal) {
            switch choosingFamily {
            case .textStyle:
                choices(
                    current: defaultTextStyle,
                    isDisabled: { _ in !viewModel.canEditLink }
                ) {
                    viewModel.applyTextStyle($0)
                    defaultTextStyleRaw = $0.rawValue
                }
            case .list:
                choices(current: defaultListFormat) {
                    viewModel.chooseFormat($0)
                    defaultListFormatRaw = $0.rawValue
                }
            case .quote:
                choices(current: defaultQuoteFormat) {
                    viewModel.chooseFormat($0)
                    defaultQuoteFormatRaw = $0.rawValue
                }
            case .attach:
                attachChoices
            case nil:
                actions
            }
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: ScrollFadeEdges.self) { geometry in
            scrollFadeEdges(
                contentOffsetX: geometry.contentOffset.x, contentWidth: geometry.contentSize.width,
                containerWidth: geometry.containerSize.width)
        } action: { _, edges in
            fadeEdges = edges
        }
        .mask(fadeMask)
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

    /// Short gradient at each edge that has hidden content, so the row reads as scrollable.
    /// The gradients are flipped for right-to-left, where leading is the right edge.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [fadeEdges.leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing
            )
            .frame(width: fadeWidth)
            .flipsForRightToLeftLayoutDirection(true)
            Rectangle()
            LinearGradient(
                colors: [.black, fadeEdges.trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing
            )
            .frame(width: fadeWidth)
            .flipsForRightToLeftLayoutDirection(true)
        }
    }

    /// Close, then one button per member of the family. `pick` applies the member and
    /// remembers it as the default; the current default is drawn in the brand colour.
    private func choices<Choice: FormattingBarChoice>(
        current: Choice, isDisabled: ((Choice) -> Bool)? = nil, pick: @escaping (Choice) -> Void
    ) -> some View {
        HStack(spacing: DocsSpacing.space4xs) {
            barButton(icon: .close, label: loc[.common_close], disabled: false) {
                choosingFamily = nil
            }
            ForEach(Choice.allCases, id: \.self) { choice in
                barButton(
                    icon: choice.icon, label: loc[choice.labelKey], brand: choice == current,
                    disabled: isDisabled?(choice)
                ) {
                    pick(choice)
                    choosingFamily = nil
                }
                // The brand colour marks the default for sighted users; VoiceOver gets the trait.
                .accessibilityAddTraits(choice == current ? .isSelected : [])
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
            // One text-style button: a tap applies the default style (bold, italic or
            // link), a long press offers all three. Every style acts only on blocks that
            // render inline markdown, so the whole family is disabled on `!canEditLink`.
            barButton(
                icon: defaultTextStyle.icon, label: loc[defaultTextStyle.labelKey],
                disabled: !viewModel.canEditLink,
                longPressLabel: loc[.editor_format_change_text_style],
                longPressAction: { choosingFamily = .textStyle }
            ) {
                guard choosingFamily == nil else { return }
                viewModel.applyTextStyle(defaultTextStyle)
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
                disabled: !canOfferAttach(photo: canOfferPhoto, file: canOfferFile)
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
