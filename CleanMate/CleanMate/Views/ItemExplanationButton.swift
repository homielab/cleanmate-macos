import SwiftUI

/// ⓘ on a cleaner row: opens "Why is this safe?" (`ItemExplanation`) in a popover. A plain button, so it is reached
/// with Tab / VoiceOver and opened with Space or a click.
struct ItemExplanationButton: View {
    let item: CleanerItem
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Why is this safe?")
        .accessibilityLabel(Text("Why is this safe?") + Text(verbatim: " ") + Text(item.title))
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            ItemExplanationView(item: item)
        }
    }
}

struct ItemExplanationView: View {
    let item: CleanerItem
    private var explanation: ItemExplanation { ItemExplanation(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.headline)
            if let what = explanation.what {
                section("What it is") { Text(what) }
            }
            section("Where it is") {
                ForEach(explanation.paths, id: \.self) { path in
                    Text(verbatim: path).font(.callout.monospaced()).textSelection(.enabled)
                }
                if explanation.morePaths > 0 {
                    Text("and \(explanation.morePaths) more").foregroundStyle(.secondary)
                }
                if let note = explanation.locationNote { Text(note) }
            }
            section("After cleaning") { lines(explanation.afterClean) }
            section("Skipped when") { lines(explanation.skippedWhen) }
            OpenSettingsButton(tab: SettingsView.exclusionsTab) { Text("Open Exclusions…") }
                .buttonStyle(.link)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .accessibilityElement(children: .contain)
    }

    private func lines(_ lines: [LocalizedStringResource]) -> some View {
        ForEach(lines.indices, id: \.self) { i in
            Label { Text(lines[i]) } icon: { Text(verbatim: "•").accessibilityHidden(true) }
                .labelStyle(.titleAndIcon)
        }
    }
}
