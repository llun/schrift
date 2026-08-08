import SwiftUI

/// Reference metrics for the swipe. A caseless enum of `static let`, like `ShareSheetLayout`.
///
/// Every number here is a *feel* constant: the tests below pin the shape of each mapping,
/// not that these values are the right ones. Tune them on a device, not in the suite.
enum SwipeRevealMetrics {
    /// How far a finger travels before the row commits to an axis. Too small and a scroll
    /// flickers the strip; too large and the swipe feels dead.
    static let slop: CGFloat = 10
    /// How much more horizontal than vertical a drag must be to count as a swipe.
    static let dominanceRatio: CGFloat = 1.5
    /// Per-action width at the Large content size, before `@ScaledMetric` and the cap.
    static let actionButtonBaseWidth: CGFloat = 72
    /// How much of a drag past the strip's end still moves the row.
    static let rubberBandFactor: CGFloat = 0.25
    /// Share of the strip that must be revealed for a release to settle open.
    static let openThresholdRatio: CGFloat = 0.5
    /// The strip may never cover more than this share of the row, or at accessibility text
    /// sizes the title it is attached to disappears entirely.
    static let maxStripFraction: CGFloat = 0.6
}

/// What a drag session turned out to be, decided **once** past the slop and then frozen for
/// the session. A mid-gesture re-decision is what makes a hand-rolled swipe feel like it is
/// fighting the list.
enum SwipeDragAxis: Equatable {
    case undecided
    case horizontal
    case vertical
}

enum SwipeRevealSettle: Equatable {
    case open
    case closed
}

enum SwipeActionRole: Equatable {
    case neutral
    case brand
    case destructive
}

struct SwipeActionStyleHex: Equatable {
    let backgroundLightHex: UInt32
    let backgroundDarkHex: UInt32
    let foregroundLightHex: UInt32
    let foregroundDarkHex: UInt32
}

enum SwipeActionStyleResolver {
    static func style(role: SwipeActionRole) -> SwipeActionStyleHex {
        switch role {
        case .neutral:
            return SwipeActionStyleHex(
                backgroundLightHex: DocsColorHex.surfaceMuted, backgroundDarkHex: DocsColorHexDark.surfaceMuted,
                foregroundLightHex: DocsColorHex.textSecondary, foregroundDarkHex: DocsColorHexDark.textSecondary)
        case .brand:
            return SwipeActionStyleHex(
                backgroundLightHex: DocsColorHex.brandFill, backgroundDarkHex: DocsColorHexDark.brandFill,
                foregroundLightHex: DocsColorHex.textOnBrand, foregroundDarkHex: DocsColorHexDark.textOnBrand)
        case .destructive:
            // The dark half deliberately does **not** pair `danger` with white.
            // `DocsColorHexDark.danger` is a light salmon — the fill has to lift off a
            // near-black page — so white on it reads at ~2.3:1. Dark inverts the pairing
            // instead: the same salmon with the page's own near-black as ink, ~8:1.
            // See `SwipeActionStyleResolverTests` for the full reasoning.
            return SwipeActionStyleHex(
                backgroundLightHex: DocsColorHex.danger, backgroundDarkHex: DocsColorHexDark.danger,
                foregroundLightHex: DocsColorHex.textOnBrand, foregroundDarkHex: DocsColorHexDark.surfacePage)
        }
    }
}

// MARK: - Pure geometry

/// Which axis a drag belongs to.
///
/// An ambiguous diagonal resolves **vertical**: the tie goes to the enclosing scroll view,
/// because a drag only marginally more sideways than not is someone scrolling with a
/// crooked thumb, and claiming it makes the list feel like it fights back.
func swipeDragAxis(
    translation: CGSize,
    slop: CGFloat = SwipeRevealMetrics.slop,
    dominanceRatio: CGFloat = SwipeRevealMetrics.dominanceRatio
) -> SwipeDragAxis {
    let dx = abs(translation.width)
    let dy = abs(translation.height)
    guard max(dx, dy) >= slop else { return .undecided }
    return dx > dy * dominanceRatio ? .horizontal : .vertical
}

/// The content's x-offset during a live drag, in the reveal direction (already sign-corrected
/// by the caller, so negative always means "revealing").
///
/// Travel past the strip's end is rubber-banded rather than clamped flat — a hard stop reads
/// as a bug — while travel in the leading direction is refused outright, there being no
/// leading actions.
func swipeRevealOffset(
    translation: CGFloat,
    startingOffset: CGFloat,
    stripWidth: CGFloat,
    rubberBandFactor: CGFloat = SwipeRevealMetrics.rubberBandFactor
) -> CGFloat {
    guard stripWidth > 0 else { return 0 }
    let raw = startingOffset + translation
    if raw >= 0 { return 0 }
    guard raw < -stripWidth else { return raw }
    return -stripWidth - (-stripWidth - raw) * rubberBandFactor
}

/// Where the row lands when the finger lifts.
///
/// Judged on the **flick-projected** offset, not the live one. With no velocity
/// `DragGesture`'s `predictedEndTranslation` equals the live translation, so a slow drag is
/// decided by where the finger actually stopped; with velocity it runs ahead, which is what
/// turns a short fast flick into an open and a long drag thrown back into a close. Feeding
/// the projection through `swipeRevealOffset` first is what keeps the threshold comparison
/// in the same (rubber-banded, clamped) space as the live offset.
func swipeRevealSettle(
    predictedEndOffset: CGFloat,
    stripWidth: CGFloat,
    openThresholdRatio: CGFloat = SwipeRevealMetrics.openThresholdRatio
) -> SwipeRevealSettle {
    guard stripWidth > 0 else { return .closed }
    return abs(predictedEndOffset) >= stripWidth * openThresholdRatio ? .open : .closed
}

/// Per-action button width: the Dynamic-Type-scaled base, capped so the whole strip never
/// swallows the row, and floored at the 44pt tap target.
///
/// **The floor beats the cap.** A narrow row with several actions computes sub-44pt buttons,
/// and a tap target under 44pt is not a trade this app makes — a slightly over-wide strip is.
///
/// `rowWidth == 0` means the geometry callback has not landed yet; falling through to a
/// zero-width strip there would leave the actions invisible on the very first swipe.
func swipeActionButtonWidth(
    actionCount: Int,
    scaledBase: CGFloat,
    rowWidth: CGFloat,
    maxStripFraction: CGFloat = SwipeRevealMetrics.maxStripFraction,
    minimum: CGFloat = DocsSpacing.rowMinHeight
) -> CGFloat {
    guard actionCount > 0 else { return 0 }
    guard rowWidth > 0 else { return scaledBase }
    let cap = rowWidth * maxStripFraction / CGFloat(actionCount)
    return max(minimum, min(scaledBase, cap))
}

func swipeActionStripWidth(actionCount: Int, buttonWidth: CGFloat) -> CGFloat {
    CGFloat(actionCount) * buttonWidth
}

/// `.offset(x:)` is **not** mirrored by SwiftUI, so without this the strip opens off the
/// wrong edge under an RTL locale.
func swipeRevealDirectionSign(_ layoutDirection: LayoutDirection) -> CGFloat {
    layoutDirection == .rightToLeft ? -1 : 1
}

/// Whether an action button shows its caption under the glyph.
///
/// The sibling of `rowUsesStackedLayout(_:)`: at accessibility sizes a caption inside a
/// scaled box wraps to truncated lines, so the glyph stands alone. Safe precisely because
/// the accessibility action name carries the wording unconditionally.
func swipeActionShowsCaption(_ dynamicTypeSize: DynamicTypeSize) -> Bool {
    !dynamicTypeSize.isAccessibilitySize
}

// MARK: - Cross-row state

/// Which row is open, and which (if any) is being dragged right now.
///
/// Both facts are list-wide, so the *container* holds one of these in `@State` and hands a
/// `Binding` to each row: opening row B must close row A, and the close-on-scroll rule must
/// not fire during a swipe that happens to nudge the scroll view.
struct SwipeRevealState<ID: Hashable>: Equatable {
    var openRowID: ID?
    var draggingRowID: ID?

    init(openRowID: ID? = nil, draggingRowID: ID? = nil) {
        self.openRowID = openRowID
        self.draggingRowID = draggingRowID
    }

    var isDragging: Bool { draggingRowID != nil }
}

/// Claiming the row is what closes every sibling — one assignment, no broadcast.
func swipeRevealBeginningDrag<ID: Hashable>(_ state: SwipeRevealState<ID>, rowID: ID) -> SwipeRevealState<ID> {
    SwipeRevealState(openRowID: rowID, draggingRowID: rowID)
}

func swipeRevealSettling<ID: Hashable>(
    _ state: SwipeRevealState<ID>, rowID: ID, settle: SwipeRevealSettle
) -> SwipeRevealState<ID> {
    var next = state
    next.draggingRowID = nil
    switch settle {
    case .open:
        next.openRowID = rowID
    case .closed:
        // Only if this row is the one that is open — settling a stale row must not close
        // whatever currently is.
        if state.openRowID == rowID { next.openRowID = nil }
    }
    return next
}

/// A scroll interaction closes any open row — **unless a drag is in flight**.
///
/// That guard is the whole reason `draggingRowID` exists: the swipe and the scroll view's
/// pan run simultaneously (there is no supported way to make the scroll view yield), so a
/// swipe routinely reports a scroll interaction while the finger is still down. Without it
/// the strip would close the instant you swiped.
func swipeRevealAfterScrollInteraction<ID: Hashable>(_ state: SwipeRevealState<ID>) -> SwipeRevealState<ID> {
    guard !state.isDragging else { return state }
    var next = state
    next.openRowID = nil
    return next
}

// MARK: - Action model

/// One revealed action.
///
/// `label` is the **already-localized** phrase, resolved by the caller from
/// `LocalizationStore` — the same contract `docRowAccessibilityLabel` uses. This component
/// owns branching and layout, never a translation lookup.
struct SwipeRevealAction: Identifiable {
    let id: String
    let icon: MaterialIcon
    let label: String
    var role: SwipeActionRole = .neutral
    let handler: () -> Void

    init(
        id: String, icon: MaterialIcon, label: String, role: SwipeActionRole = .neutral,
        handler: @escaping () -> Void
    ) {
        self.id = id
        self.icon = icon
        self.label = label
        self.role = role
        self.handler = handler
    }
}

// MARK: - The row

/// Wraps a row and reveals a trailing action strip on a leftward drag.
///
/// Deliberately **not** named `SwipeActionsRow`: it cannot match `.swipeActions`' semantics
/// (no full-swipe commit, no automatic VoiceOver exposure, no edit-mode integration), and
/// borrowing the system name would invite a future reader to assume parity. It exists at all
/// because the app has no SwiftUI `List` — every document list is a `ScrollView` + `VStack`,
/// which is what gives the app its flat, boxless rows, and `.swipeActions` silently no-ops
/// outside a `List`.
///
/// **Trailing edge only.** A leading (rightward) swipe would fight the system's interactive
/// pop gesture on every `NavigationStack` screen.
///
/// **Wrap tap-gesture rows, not `Button` rows.** `DocRow`'s
/// `.contentShape(Rectangle()).onTapGesture` composes cleanly with a simultaneous drag (a
/// 10pt drag never satisfies a tap). A `Button`'s own gesture begins tracking on touch-down
/// and can still fire on touch-up *after* a swipe, and there is no declarative way to cancel
/// it from here — so convert such a row to the tap-gesture model before wrapping it.
struct SwipeRevealRow<ID: Hashable, Content: View>: View {
    let id: ID
    @Binding var state: SwipeRevealState<ID>
    let actions: [SwipeRevealAction]
    /// The composed label VoiceOver reads for the whole row. **Required, not derived**: this
    /// wrapper collapses with `children: .ignore`, which discards whatever the content
    /// composed, so the caller hands the same string to both.
    let accessibilityLabel: String
    /// The row's default VoiceOver action — the same thing a sighted tap does. Required for
    /// the same reason: `.ignore` discarded the content's own activation.
    let onActivate: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ScaledMetric(relativeTo: .body) private var scaledButtonBase: CGFloat =
        SwipeRevealMetrics.actionButtonBaseWidth

    @State private var rowWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var dragAxis: SwipeDragAxis = .undecided
    /// Where the content sat when this drag began, so a drag starting on an already-open row
    /// continues from the strip edge instead of snapping to zero.
    @State private var dragStartOffset: CGFloat = 0

    private var isOpen: Bool { state.openRowID == id }
    private var directionSign: CGFloat { swipeRevealDirectionSign(layoutDirection) }
    private var buttonWidth: CGFloat {
        swipeActionButtonWidth(actionCount: actions.count, scaledBase: scaledButtonBase, rowWidth: rowWidth)
    }
    private var stripWidth: CGFloat {
        swipeActionStripWidth(actionCount: actions.count, buttonWidth: buttonWidth)
    }

    var body: some View {
        // **The content alone sizes the row; the strip is a `background` of it.**
        //
        // Not a `ZStack` sibling. The strip's buttons are `maxHeight: .infinity` so they fill
        // the row's height, and a flexible frame answers the proposal it is given — inside a
        // `ZStack` that made the strip a *greedy sibling*, so the stack took the whole
        // proposed height and a document row measured 874pt instead of 58pt. A background is
        // proposed the size of the view it decorates, so the same `.infinity` clamps to the
        // row and contributes nothing back. Same lesson as `SaveStatusIndicator`'s, from the
        // other direction. Pinned by `SwipeRevealRowGeometryTests`.
        content()
            .background(DocsColor.surfacePage)
            .overlay {
                // Present only while open or mid-swipe, so a *closed* row behaves exactly as
                // it did before this wrapper existed — which is what makes adopting it safe
                // on an untouched path.
                if isOpen || dragAxis == .horizontal {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .accessibilityHidden(true)
                }
            }
            .offset(x: offset * directionSign)
            // A background attached *after* `.offset` is laid out in the row's own
            // (unshifted) bounds and does not follow it — verified by rendering, not
            // assumed — so the strip stays pinned to the trailing edge while the content
            // slides off it. Compensating for the offset here would double the displacement.
            .background(alignment: .trailing) {
                if !actions.isEmpty {
                    actionStrip
                }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                rowWidth = $0
            }
            // Simultaneous, never `.gesture` (which competes with the scroll pan and claims
            // vertical drags, killing scrolling) and never `.highPriorityGesture` (designed to
            // win). Both recognizers run; non-horizontal drags are discarded here instead.
            .simultaneousGesture(dragGesture)
            .onChange(of: isOpen) { _, open in
                guard !open, offset != 0 else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { offset = 0 }
            }
            // **Release the list-wide drag claim if this row goes away mid-swipe.**
            // `draggingRowID` is normally cleared by `onEnded`, but a row can be torn down
            // before the finger lifts — its document deleted by a background sync, a
            // co-author, or the swipe's own Delete. The per-row `@State` dies with the view;
            // the *shared* state does not, and `swipeRevealAfterScrollInteraction` early-returns
            // while anything claims to be dragging, so a stale claim would silently disable
            // close-on-scroll for the whole list until some other row completed a full drag.
            .onDisappear {
                if state.draggingRowID == id { state.draggingRowID = nil }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onActivate() }
            .accessibilityActions {
                ForEach(actions) { action in
                    Button(action.label) { action.handler() }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: SwipeRevealMetrics.slop, coordinateSpace: .local)
            .onChanged { value in
                guard !actions.isEmpty else { return }
                if dragAxis == .undecided {
                    dragAxis = swipeDragAxis(translation: value.translation)
                    guard dragAxis == .horizontal else { return }
                    dragStartOffset = offset
                    state = swipeRevealBeginningDrag(state, rowID: id)
                }
                guard dragAxis == .horizontal else { return }
                offset = swipeRevealOffset(
                    translation: value.translation.width * directionSign,
                    startingOffset: dragStartOffset,
                    stripWidth: stripWidth)
            }
            .onEnded { value in
                defer { dragAxis = .undecided }
                guard dragAxis == .horizontal else { return }
                let predicted = swipeRevealOffset(
                    translation: value.predictedEndTranslation.width * directionSign,
                    startingOffset: dragStartOffset,
                    stripWidth: stripWidth)
                let settle = swipeRevealSettle(predictedEndOffset: predicted, stripWidth: stripWidth)
                state = swipeRevealSettling(state, rowID: id, settle: settle)
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                    offset = settle == .open ? -stripWidth : 0
                }
            }
    }

    private var actionStrip: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                actionButton(action)
            }
        }
        .frame(width: stripWidth)
        // Offscreen chrome, not content. Left visible to VoiceOver it puts one phantom stop
        // per action after every row — the failure that makes hand-rolled swipe rows
        // unusable with the screen reader on. The actions themselves are exposed through
        // `.accessibilityActions` above.
        .accessibilityHidden(true)
    }

    private func actionButton(_ action: SwipeRevealAction) -> some View {
        let style = SwipeActionStyleResolver.style(role: action.role)
        return Button {
            close()
            action.handler()
        } label: {
            VStack(spacing: DocsSpacing.space3xs) {
                MaterialSymbol(action.icon, size: 22)
                if swipeActionShowsCaption(dynamicTypeSize) {
                    Text(action.label)
                        .font(DocsFont.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .foregroundStyle(
                Color(lightHex: style.foregroundLightHex, darkHex: style.foregroundDarkHex)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color(lightHex: style.backgroundLightHex, darkHex: style.backgroundDarkHex)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func close() {
        state = swipeRevealSettling(state, rowID: id, settle: .closed)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { offset = 0 }
    }
}

// MARK: - Preview

private struct SwipeRevealRowPreview: View {
    @State private var state = SwipeRevealState<String>()

    private let rows = ["Q3 Planning", "Roadmap", "Meeting notes"]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.self) { title in
                SwipeRevealRow(
                    id: title,
                    state: $state,
                    actions: [
                        SwipeRevealAction(id: "pin", icon: .push_pin, label: "Pin", role: .brand) {},
                        SwipeRevealAction(id: "delete", icon: .delete, label: "Delete", role: .destructive) {},
                    ],
                    accessibilityLabel: title,
                    onActivate: {}
                ) {
                    DocRow(title: title, date: "3 days ago")
                }
            }
        }
    }
}

#Preview("Swipe Reveal Row — light") {
    SwipeRevealRowPreview()
        .environment(LocalizationStore())
        .preferredColorScheme(.light)
}

#Preview("Swipe Reveal Row — dark") {
    SwipeRevealRowPreview()
        .environment(LocalizationStore())
        .preferredColorScheme(.dark)
}

#Preview("Swipe Reveal Row — one action, accessibility size") {
    SwipeRevealRowPreview()
        .environment(LocalizationStore())
        .environment(\.dynamicTypeSize, .accessibility3)
}
