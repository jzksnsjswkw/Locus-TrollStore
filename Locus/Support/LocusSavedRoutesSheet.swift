import SwiftUI

/// Lists saved routes and loads the chosen one back onto the map.
///
/// Saved routes live in `UserDefaults` (see `SavedRoute`), so this list works in
/// a build that has no writable data container.
struct LocusSavedRoutesSheet: View {
    let onSelect: (SavedRoute) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var routes: [SavedRoute] = []
    @State private var pendingDelete: SavedRoute?
    @State private var routeToRename: SavedRoute?
    @State private var renameText = ""

    var body: some View {
        LocusNavStack {
            List {
                if routes.isEmpty {
                    Section {
                        Text(L("还没有保存的轨迹。在轨迹页点击「保存当前轨迹」，导入或手绘的路线就会出现在这里。"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .locusSheetRows()
                } else {
                    // The ForEach must sit in its own Section: directly under
                    // List, SwiftUI's row diffing falls back to index matching
                    // when a row disappears, so the wrong row animated out and
                    // the survivors' contents appeared to jump.
                    Section {
                        ForEach(routes) { route in
                            Button {
                                presentationMode.wrappedValue.dismiss()
                                onSelect(route)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(route.name)
                                            .foregroundColor(.primary)
                                        Text(L("%@ · %@ 点 · %@", "\(route.source.label)", "\(route.pointCount)", "\(route.distanceText)"))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .id(route.id)
                            // Deliberately not `.onDelete` / destructive
                            // swipeActions: those animate the row away before
                            // the confirmation, so it slides back in and plays
                            // twice.
                            .locusConfirmingRowActions(
                                deleteTitle: L("删除"),
                                onDelete: { pendingDelete = route },
                                onRename: {
                                    routeToRename = route
                                    renameText = route.name
                                }
                            )
                        }
                    }
                    .locusSheetRows()
                }
            }
            .locusScrollContentBackgroundHidden()
            .background(Color.clear)
            .navigationTitle(L("已保存轨迹"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成")) { presentationMode.wrappedValue.dismiss() }
                }
            }
            .onChange(of: pendingDelete?.id) { _ in
                // Presented through UIKit: a SwiftUI alert shares the list's
                // transaction, and its dismissal cancels the row animation so
                // the wrong row appears to leave.
                guard let route = pendingDelete else { return }
                LocusDocumentExchange.confirm(
                    title: L("删除轨迹"),
                    message: L("「%@」将被删除，此操作无法撤销。", "\(route.name)"),
                    confirmTitle: L("删除")
                ) {
                    var updated = routes
                    updated.removeAll { $0.id == route.id }
                    SavedRoute.save(updated)
                    withAnimation(.easeInOut(duration: 0.22)) {
                        routes = updated
                    }
                    pendingDelete = nil
                } onCancel: {
                    pendingDelete = nil
                }
            }
            .locusRenameAlert(
                isPresented: Binding(
                    get: { routeToRename != nil },
                    set: { if !$0 { routeToRename = nil } }
                ),
                title: L("重命名轨迹"),
                message: L("设置一个方便以后识别的名称。"),
                placeholder: L("轨迹名称"),
                text: $renameText
            ) {
                guard let route = routeToRename else { return }
                var updated = SavedRoute.load()
                if let index = updated.firstIndex(where: { $0.id == route.id }) {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        updated[index].name = trimmed
                    }
                    SavedRoute.save(updated)
                    routes = updated
                }
                routeToRename = nil
            }
            .onAppear {
                routes = SavedRoute.load()
            }
        }
    }
}
