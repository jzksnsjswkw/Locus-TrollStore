import SwiftUI

struct RoutePlannerSheet: View {
    var onPlay: () -> Void
    var onImportGPX: () -> Void
    var onExportGPX: () -> Void
    var onSaveRoute: () -> Void
    var onShowSavedRoutes: () -> Void
    var onBuildRouteToTarget: () -> Void
    var drawMode: Bool
    var onToggleDrawing: () -> Void

    @EnvironmentObject private var session: SpoofSession
    @Environment(\.presentationMode) private var presentationMode

    /// Read when the sheet is built so the count stays current after saving.
    private var savedRoutesLabel: String {
        let count = SavedRoute.load().count
        return count == 0 ? L("已保存的轨迹") : L("已保存的轨迹（%@）", "\(count)")
    }

    var body: some View {
        LocusNavStack {
            List {
                Section(header: Text(L("速度与循环"))) {
                    TravelModeSelector()
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    HStack {
                        Label(L("速度"), systemImage: SFSymbolCompat.resolved("speedometer"))
                        Spacer()
                        Text(String(format: "%.2fx · %.1f km/h", session.speedMultiplier, session.travelMode.baseSpeed * session.speedMultiplier * 3.6))
                            .font(.caption.locusMonospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $session.speedMultiplier, in: 0.25...4.0, step: 0.25)
                    Toggle(isOn: $session.routeLoopEnabled) {
                        Label(L("循环运行轨迹"), systemImage: "repeat")
                    }
                    Stepper(value: $session.routeLoopCount, in: max(2, session.routeLap)...99) {
                        Label(L("共运行 %@ 圈", "\(session.routeLoopCount)"), systemImage: "number")
                    }
                    .disabled(!session.routeLoopEnabled)
                }
                .locusSheetRows()

                Section(header: Text(L("地图手绘"))) {
                    Button {
                        onToggleDrawing()
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Label(
                            drawMode ? L("返回地图继续手绘") : L("开始地图手绘"),
                            systemImage: "pencil.tip.crop.circle"
                        )
                    }
                    Text(L("开始后可直接在地图底部撤回、保存或取消，无需返回此页面。"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .locusSheetRows()

                Section {
                    Button(action: onSaveRoute) {
                        Label(L("保存当前轨迹"), systemImage: "star")
                    }
                    Button(action: onShowSavedRoutes) {
                        Label(savedRoutesLabel, systemImage: "list.bullet")
                    }
                } header: {
                    Text(L("收藏轨迹"))
                } footer: {
                    Text(L("保存后可在「已保存的轨迹」中重新载入，不需要导出文件。"))
                }
                .locusSheetRows()

                Section(header: Text(L("运行与 GPX"))) {
                    Button(action: onPlay) {
                        Label(L("开始运行轨迹"), systemImage: "play.fill")
                    }
                    Button(action: onImportGPX) {
                        Label(L("导入 GPX"), systemImage: "square.and.arrow.down")
                    }
                    Button(action: onExportGPX) {
                        Label(L("导出 GPX"), systemImage: "square.and.arrow.up")
                    }
                }
                .locusSheetRows()

                Section(header: Text(L("生成轨迹"))) {
                    if session.targetSelectionMode == .crosshair {
                        Button(action: onBuildRouteToTarget) {
                            Label(L("从当前位置生成至准星的轨迹"), systemImage: "scope")
                        }
                    } else {
                        Label(L("长按地图上的红色图钉，然后选择“生成轨迹”"), systemImage: "hand.tap.fill")
                    }
                    Text(session.targetSelectionMode == .crosshair
                         ? L("当前模拟位置或真实位置作为起点，屏幕中央准星作为终点。")
                         : L("当前模拟位置或真实位置作为起点，红图钉作为终点。"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .locusSheetRows()
            }
            .locusScrollContentBackgroundHidden()
            .background(Color.clear)
            .navigationTitle(L("轨迹"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成")) { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }

}
