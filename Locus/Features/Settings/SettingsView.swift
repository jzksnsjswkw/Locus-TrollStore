import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject private var languageStore: LocusLanguageStore

    @State private var showNameEasterEgg = false
    @AppStorage(UserDefaults.elevationDataSourceKey) private var elevationSource: ElevationDataSource = .openMeteo
    @AppStorage("locus.backupIncludesRoutes") private var backupIncludesRoutes = true

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    private var altitudeDisplayText: String {
        guard let altitude = session.simulatedAltitude else { return L("等待定位…") }
        return String(format: L("%.0f 米"), altitude)
    }

    var body: some View {
        LocusNavStack {
            List {
                mapInteractionSection
                    .locusSheetRows()

                Section {
                    Toggle(L("保存搜索历史"), isOn: $session.searchHistoryEnabled)
                    if !session.searchHistory.isEmpty {
                        Button(L("清空搜索历史")) {
                            LocusDocumentExchange.confirm(
                                title: L("清空搜索历史"),
                                message: L("此操作无法撤销。"),
                                confirmTitle: L("清空"),
                                onConfirm: { session.clearSearchHistory() }
                            )
                        }
                    }
                    Toggle(L("备份包含已保存轨迹"), isOn: $backupIncludesRoutes)
                    Button {
                        exportBackup()
                    } label: {
                        Label(L("导出 Locus 备份"), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        importBackup()
                    } label: {
                        Label(L("导入 Locus 备份"), systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text(L("搜索与数据"))
                } footer: {
                    Text(backupIncludesRoutes
                         ? L("备份包含收藏、搜索历史、已保存轨迹、海拔数据源与 API Key，以及界面设置；不包含正在运行的轨迹或设备连接状态。")
                         : L("备份不包含已保存轨迹，其余内容（收藏、搜索历史、海拔数据源与 API Key、界面设置）仍会导出。"))
                }
                .locusSheetRows()

                languageSection
                    .locusSheetRows()

                privacySection
                    .locusSheetRows()

                Section(header: Text(L("关于"))) {
                    LocusLabeledRow(L("版本"), value: appVersion)
                    LocusLabeledRow(L("定位引擎"), value: "CLSimulationManager（TrollStore）")
                    Link(destination: URL(string: "https://github.com/jzksnsjswkw/Locus-TrollStore")!) {
                        LocusLabeledRow(L("项目主页"), value: "jzksnsjswkw/Locus-TrollStore")
                    }
                    Link(destination: URL(string: "https://github.com/ChrisMack32/Locus")!) {
                        LocusLabeledRow(L("原始项目"), value: "ChrisMack32/Locus")
                    }
                    Text(L("Locus 是采用 MIT 许可证的免费开源软件。定位注入使用 Apple 私有 CoreLocation 模拟 API（com.apple.locationd.simulation 权限）。"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .locusSheetRows()

                Section {
                    Button {
                        showNameEasterEgg = true
                    } label: {
                        Text(L("locus，名词——地点。源自拉丁语，意为你所在之处。"))
                            .font(.footnote.italic())
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .locusListRowSeparatorHidden()
                }
            }
            .locusScrollContentBackgroundHidden()
            .background(Color.clear)
            .navigationTitle(L("设置"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .fullScreenCover(isPresented: $showNameEasterEgg) {
                LocusEasterEggView()
            }

        }
    }

    private func exportBackup() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(session.makeBackup(includingRoutes: backupIncludesRoutes))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Locus-Backup.json")
            try data.write(to: url, options: .atomic)
            // The share sheet is presented on the topmost controller, so the
            // settings sheet can stay open underneath it.
            LocusDocumentExchange.share(
                fileAt: url,
                onFailure: { LocusDocumentExchange.notify(title: L("导出失败"), message: $0.localizedDescription) }
            )
        } catch {
            LocusDocumentExchange.notify(title: L("导出失败"), message: error.localizedDescription)
        }
    }

    private func importBackup() {
        // Presented on the settings sheet itself so the page stays put.
        LocusDocumentExchange.pickDocument(contentTypes: [.json]) { url in
            importBackup(from: url)
        }
    }

    private func importBackup(from url: URL) {
        do {
            try applyBackup(LocusFileReader.data(from: url))
        } catch {
            LocusDocumentExchange.notify(title: L("导入失败"), message: error.localizedDescription)
        }
    }

    private func applyBackup(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(LocusBackup.self, from: data).validated()
        let routeCount = backup.savedRoutes?.count ?? 0

        var message = L("将导入 %@ 个收藏和 %@ 条搜索历史；本机同坐标收藏优先保留。", "\(backup.favorites.count)", "\(backup.searchHistory.count)")
        if routeCount > 0 {
            message += L("\n\n备份中还包含 %@ 条已保存轨迹。", "\(routeCount)")
        }
        message += L("\n\n备份中的海拔数据源与 API Key 会一并恢复。")

        // Offered as an explicit choice, because routes are the bulkiest part of
        // a backup and a restore may deliberately want only placements.
        if routeCount > 0 {
            LocusDocumentExchange.confirmWithOption(
                title: L("导入 Locus 备份"),
                message: message,
                confirmTitle: L("全部导入"),
                optionTitle: L("仅导入收藏与设置"),
                onConfirm: {
                    do {
                        try session.applyBackup(backup, includingRoutes: true)
                        LocusDocumentExchange.notify(title: L("Locus 备份"), message: L("备份导入完成。"))
                    } catch {
                        LocusDocumentExchange.notify(title: L("导入失败"), message: error.localizedDescription)
                    }
                },
                onOption: {
                    do {
                        try session.applyBackup(backup, includingRoutes: false)
                        LocusDocumentExchange.notify(title: L("Locus 备份"), message: L("已导入收藏与设置，轨迹未导入。"))
                    } catch {
                        LocusDocumentExchange.notify(title: L("导入失败"), message: error.localizedDescription)
                    }
                }
            )
        } else {
            LocusDocumentExchange.confirm(
                title: L("导入 Locus 备份"),
                message: message,
                confirmTitle: L("应用备份"),
                onConfirm: {
                    do {
                        try session.applyBackup(backup)
                        LocusDocumentExchange.notify(title: L("Locus 备份"), message: L("备份导入完成。"))
                    } catch {
                        LocusDocumentExchange.notify(title: L("导入失败"), message: error.localizedDescription)
                    }
                }
            )
        }
    }

    private var languageSection: some View {
        Section {
            Picker(L("语言"), selection: Binding(
                get: { languageStore.language },
                set: { languageStore.set($0) }
            )) {
                ForEach(LocusLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .locusPickerStyleMenu()
        } header: {
            Text(L("语言"))
        } footer: {
            Text(L("切换后界面会立即以所选语言重新显示；「跟随系统」使用设备的首选语言。"))
        }
    }

    private var mapInteractionSection: some View {
        Section {
            Picker(L("定位点选择方式"), selection: $session.targetSelectionMode) {
                ForEach(TargetSelectionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .locusPickerStyleMenu()

            Picker(L("地图样式"), selection: $session.mapStyleIndex) {
                Text(L("标准")).tag(0)
                Text(L("卫星混合")).tag(1)
            }
            .locusPickerStyleMenu()

            Picker(L("外观"), selection: $session.appearanceMode) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .locusPickerStyleMenu()

            Toggle(L("地图缩放滑条"), isOn: $session.zoomSliderEnabled)
            Toggle(L("轨迹运行时自动跟随"), isOn: $session.autoFollowRoute)
            Toggle(L("启动时恢复上次地图视角"), isOn: $session.restoreLastMapView)

            Toggle(L("模拟位置随机抖动"), isOn: $session.locationJitterEnabled)
            if session.locationJitterEnabled {
                Stepper(value: $session.locationJitterRadius, in: 0.1...20, step: 0.1) {
                    LocusLabeledRow(L("抖动半径")) {
                        Text(String(format: L("%.1f 米"), session.locationJitterRadius))
                            .locusMonospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }
            }

            Stepper(value: $session.locationUpdateInterval, in: 0.1...10, step: 0.1) {
                LocusLabeledRow(L("定位更新间隔")) {
                    Text(String(format: L("%.1f 秒"), session.locationUpdateInterval))
                        .locusMonospacedDigit()
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: session.locationUpdateInterval) { newValue in
                if session.locationUpdateJitter > newValue {
                    session.locationUpdateJitter = newValue
                }
            }
            Stepper(value: $session.locationUpdateJitter, in: 0...max(0.1, session.locationUpdateInterval), step: 0.1) {
                LocusLabeledRow(L("更新间隔随机抖动")) {
                    Text(String(format: L("±%.1f 秒"), session.locationUpdateJitter))
                        .locusMonospacedDigit()
                        .foregroundColor(.secondary)
                }
            }

            Toggle(L("模拟真实海拔"), isOn: $session.altitudeEnabled)
            if session.altitudeEnabled {
                LocusLabeledRow(L("当前海拔")) {
                    if session.altitudeLoading {
                        VStack(alignment: .trailing, spacing: 2) {
                            ProgressView(value: Double(session.altitudeProgress), total: Double(max(1, session.altitudeTotal)))
                                .progressViewStyle(.linear)
                                .frame(width: 100)
                            Text("\(session.altitudeProgress)/\(session.altitudeTotal)")
                                .font(.caption2.locusMonospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(altitudeDisplayText)
                            .locusMonospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }

                Picker(L("海拔数据源"), selection: $elevationSource) {
                    ForEach(ElevationDataSource.allCases) { source in
                        Text(source.pickerLabel).tag(source)
                    }
                }
                .locusPickerStyleMenu()

                Text(elevationSource.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if elevationSource.requiresAPIKey {
                    SecureField(
                        "API Key",
                        text: Binding(
                            get: { UserDefaults.standard.elevationAPIKey(for: elevationSource) ?? "" },
                            set: { UserDefaults.standard.setElevationAPIKey($0.isEmpty ? nil : $0, for: elevationSource) }
                        )
                    )
                    .locusAutocapitalizationNever()
                    .locusAutocorrectionDisabled()
                    if let url = elevationSource.registerURL {
                        Link(L("注册获取 API Key"), destination: url)
                            .font(.caption)
                    }
                }
            }
        } header: {
            Text(L("地图与交互"))
        } footer: {
            Text(L("位置抖动让轨迹更接近真实 GPS 行为；半径越大抖动越明显。更新间隔决定移动时推送模拟坐标的频率，不影响行进速度；抖动幅度会在每次更新时随机微调该间隔，且不会超过更新间隔。模拟海拔数据从所选源获取并本地缓存，海拔会随定位变化而更新。"))
        }
    }

    private var privacySection: some View {
        Section(header: Text(L("隐私"))) {
            Text(L("所有数据均在设备端处理。收藏与搜索历史保存在 UserDefaults 中；无分析统计、无需账户，也不会上传任何内容。"))
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

}

struct PlacesView: View {
    private struct FavoriteGroup: Identifiable {
        let id: String
        let places: [SavedPlace]
    }

    @EnvironmentObject private var session: SpoofSession
    @Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject private var languageStore: LocusLanguageStore

    @State private var placeToRename: SavedPlace?
    @State private var renameText = ""

    var body: some View {
        LocusNavStack {
            List {
                if session.favorites.isEmpty {
                    Section(header: Text(L("收藏地点"))) {
                        Text(L("在地图上选择图钉并点击星标即可收藏。"))
                            .foregroundColor(.secondary)
                    }
                    .locusSheetRows()
                } else {
                    ForEach(groupedFavorites) { group in
                        Section(header: Text(group.id)) {
                            ForEach(group.places) { place in
                                favoriteButton(place)
                                    .locusFavoriteRowActions(
                                        onDelete: { session.removeFavorite(place) },
                                        onRename: {
                                            placeToRename = place
                                            renameText = session.favoriteDisplayName(place)
                                        }
                                    )
                            }
                        }
                        .locusSheetRows()
                    }
                }

            }
            .locusScrollContentBackgroundHidden()
            .background(Color.clear)
            .navigationTitle(L("收藏夹"))
            .onAppear {
                Task { await session.backfillFavoriteCountries() }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成")) { presentationMode.wrappedValue.dismiss() }
                }
            }
            .locusRenameAlert(
                isPresented: Binding(
                    get: { placeToRename != nil },
                    set: { if !$0 { placeToRename = nil } }
                ),
                title: L("重命名收藏"),
                message: L("设置一个方便以后识别的名称。"),
                text: $renameText
            ) {
                if let place = placeToRename {
                    session.renameFavorite(place, to: renameText)
                }
                placeToRename = nil
            }
        }
    }

    private var groupedFavorites: [FavoriteGroup] {
        let grouped = Dictionary(grouping: session.favorites) { place in
            let country = place.countryName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let city = place.cityName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = [country, city]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .reduce(into: [String]()) { result, value in
                    if result.last != value { result.append(value) }
                }
            return parts.isEmpty ? L("未知地区") : parts.joined(separator: " ")
        }
        return grouped.keys
            .sorted { lhs, rhs in
                if lhs == L("未知地区") { return false }
                if rhs == L("未知地区") { return true }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            .map { FavoriteGroup(id: $0, places: grouped[$0] ?? []) }
    }

    private func favoriteButton(_ place: SavedPlace) -> some View {
        Button {
            session.teleport(to: place.coordinate)
            presentationMode.wrappedValue.dismiss()
        } label: {
            Text(session.favoriteDisplayName(place))
                .foregroundColor(.primary)
        }
    }

}
