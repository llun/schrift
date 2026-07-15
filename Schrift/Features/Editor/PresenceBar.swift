import SwiftUI

/// The live-collaboration presence indicator: a small cluster of avatars for the
/// peers currently in the document, shown in the editor header. It renders
/// **nothing when alone** (no peers), so it costs no space in the common
/// single-editor case and never draws a stray element.
///
/// The avatars are decorative (`Avatar` is `accessibilityHidden`), so the bar
/// carries one combined, count-aware accessibility label ("N people here"). The
/// peer count already excludes the local user (the session filters our own id),
/// so it reads as *others* present.
struct PresenceBar: View {
    let peers: [CollaborationPeer]
    var size: CGFloat = 24
    var max: Int = 3

    @Environment(LocalizationStore.self) private var loc

    var body: some View {
        if !peers.isEmpty {
            AvatarGroup(names: peers.map(\.name), size: size, max: max)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    loc.plural(
                        peers.count, one: .editor_presence_count_one, other: .editor_presence_count_other,
                        two: .editor_presence_count_two, few: .editor_presence_count_few))
        }
    }
}

/// Builds preview/catalog peers through the real parse path (the value type has
/// no memberwise initializer — a peer only ever comes from awareness JSON).
private func previewPeers(_ names: [String]) -> [CollaborationPeer] {
    names.enumerated().compactMap { index, name in
        let object = ["name": name, "color": "#30bced"]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return CollaborationPeer(clientID: UInt(index + 1), stateJSON: json)
    }
}

#Preview("Light") {
    VStack(spacing: DocsSpacing.spaceBase) {
        PresenceBar(peers: previewPeers(["Camille Moreau"]))
        PresenceBar(peers: previewPeers(["Camille Moreau", "Alfredo Levin"]))
        PresenceBar(peers: previewPeers(["Camille Moreau", "Alfredo Levin", "Desirae Dokidis", "Charlie Saris"]))
    }
    .padding()
    .environment(LocalizationStore())
}

#Preview("Dark") {
    VStack(spacing: DocsSpacing.spaceBase) {
        PresenceBar(peers: previewPeers(["Camille Moreau", "Alfredo Levin"]))
        PresenceBar(peers: previewPeers(["Camille Moreau", "Alfredo Levin", "Desirae Dokidis", "Charlie Saris"]))
    }
    .padding()
    .environment(LocalizationStore())
    .preferredColorScheme(.dark)
}
