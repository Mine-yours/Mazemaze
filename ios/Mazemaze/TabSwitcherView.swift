import SwiftUI
import MazemazeCore

struct TabSwitcherView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(model.tabs) { tab in
                        TabCard(tab: tab, isActive: tab.id == model.activeID,
                                select: { model.activate(tab.id); dismiss() },
                                close: { model.closeTab(tab.id) })
                    }
                }
                .padding(16)
                Text("タブは最大 \(AppModel.maxTabs) 個（いま \(model.tabs.count) 個）です。同時に開いたままにするのは \(AppModel.maxLiveTabs) 個までで、使っていないタブはメモリのために休止します（選ぶと読み込み直します）。別のタブを開くと、前のタブの翻訳は一時停止し、戻ると続きます。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 16)
            }
            .navigationTitle("タブ（\(model.tabs.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { if model.newTab() != nil { dismiss() } } label: { Label("新しいタブ", systemImage: "plus") }
                        .disabled(model.tabs.count >= AppModel.maxTabs)
                }
                ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } }
            }
        }
    }
}

private func badge(_ text: String) -> some View {
    Text(text).font(.caption2).padding(.horizontal, 5).background(Color(.tertiarySystemFill), in: Capsule())
}

private struct TabCard: View {
    @ObservedObject var tab: TabModel
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: tab.showsHome ? "house" : "globe").foregroundStyle(.secondary)
                        if tab.isSleeping { badge("休止中") }
                        else if tab.inflight > 0 { badge("翻訳中") }
                        else if tab.lastProblem != nil { badge("エラー") }
                        else if tab.suspendedForPage { badge("原文表示") }
                    }
                    Text(tab.displayTitle).font(.subheadline).bold().lineLimit(3).multilineTextAlignment(.leading)
                    Text(tab.displayHost).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                .padding(12).padding(.trailing, 24)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 3))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tab.displayTitle)、\(tab.displayHost)\(isActive ? "、現在のタブ" : "")\(tab.isSleeping ? "、休止中" : "")\(tab.lastProblem != nil ? "、エラーあり" : "")")
            Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary).frame(width: 44, height: 44) }
                .accessibilityLabel("タブ「\(tab.displayTitle)」を閉じる")
        }
    }
}
