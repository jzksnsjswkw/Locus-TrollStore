import MapKit
import SwiftUI

struct MapHomeView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var languageStore: LocusLanguageStore
    @Environment(\.scenePhase) private var scenePhase
    @Binding var showPlaces: Bool
    @Binding var favoriteRenameSuggestion: SavedPlace?
    @Binding var searchPresented: Bool
    @Binding var showRouteSheet: Bool
    @Binding var generatedRouteReady: Bool
    @Binding var routeOptions: [PlannedRoute]
    @Binding var selectedRouteOptionID: UUID?
    @Binding var drawingRouteActive: Bool
    @Binding var drawingRoutePointCount: Int
    /// Mirrored to RootView so the route bar can offer "编辑".
    @Binding var routeIsHandDrawnPublished: Bool

    @StateObject private var search = PlaceSearchCompleter()
    @StateObject private var mapDataSourceDetector = MapDataSourceDetector()
    @Namespace private var rightLowerControlNamespace
    @State private var region: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        latitudinalMeters: 2000,
        longitudinalMeters: 2000
    )
    /// Bumped by the locate button so LocusMapView eases the camera over 0.35s.
    @State private var animateRegionToken = 0
    /// One-shot flag: auto-jump to the current location on the first real fix.
    @State private var didAutoLocateOnFirstFix = false
    @State private var mapView: MKMapView?
    @State private var searchText = ""
    @State private var searchFocused = false
    @State private var routeStart: CLLocationCoordinate2D?
    @State private var routeEnd: CLLocationCoordinate2D?
    @State private var routeWaypoints: [CLLocationCoordinate2D] = []
    /// Waypoint whose delete pill is showing.
    @State private var selectedWaypointIndex: Int?
    @State private var routeCoords: [CLLocationCoordinate2D] = []
    @State private var routeIsHandDrawn = false
    /// Original vertices of a saved hand-drawn route, so re-editing does not
    /// fall back to the 10 m resampled line.
    @State private var editingVertices: [CLLocationCoordinate2D]?
    @State private var edgeZoomStartRegion: MKCoordinateRegion?
    @State private var edgeZoomActive = false
    @State private var edgeZoomFeedbackStep = 0
    @State private var lastLocationButtonTap: Date?
    @State private var isRouting = false
    @State private var showSavedRoutes = false
    @State private var drawnPath: [CLLocationCoordinate2D] = []
    @State private var drawMode = false
    @State private var drawnRouteStart: CLLocationCoordinate2D?
    @State private var drawnRouteEnd: CLLocationCoordinate2D?
    @State private var pinSelected = false
    @State private var pinExpandedActions = false
    @State private var selectedFavoriteID: String?
    @State private var isDraggingPin = false
    @State private var suppressNextMapTap = false
    @State private var favoriteToast: String?
    @State private var favoriteToastTask: Task<Void, Never>?
    @State private var searchNamedCoordinate: CLLocationCoordinate2D?
    @State private var confirmClearSearchHistory = false
    /// Set when the pin comes from search / a named place so starring keeps the title.
    @State private var pinPlaceName: String?
    /// Owns the marker views' screen positions; the map delegate repositions them
    /// synchronously each frame so they never trail a pan.
    /// Bumped by `mapViewDidChangeVisibleRegion` so the SwiftUI-positioned
    /// markers re-project while the map moves.
    @State private var regionChangingToken = 0
    /// Coalesces per-frame token bumps to one per runloop turn.
    @State private var regionChangePending = false
    /// True while the user is panning/pinching/zooming the map. Auto-follow must
    /// not move the camera during that: applying a region mid-gesture cancels
    /// the pinch and the zoom is lost.
    @State private var userIsManipulatingMap = false
    /// Pending follow target captured while the gesture was in progress.
    @State private var deferredFollowCoordinate: CLLocationCoordinate2D?
    /// Safe-area insets captured outside the full-bleed map surface; the
    /// full-screen ZStack ignores the safe area, so UI chrome re-applies
    /// these explicitly.
    @State private var safeAreaTop: CGFloat = 0
    @State private var safeAreaBottom: CGFloat = 0
    /// Keyboard-sensitive bottom inset (search UI), separate from the
    /// keyboard-free value above (right rail).
    @State private var safeAreaBottomRuntime: CGFloat = 0
    @State private var keyboardVisible = false

    private var mapType: MKMapType {
        switch session.mapStyleIndex {
        case 1: return .hybrid
        case 2: return .satellite
        default: return .standard
        }
    }

    var body: some View {
        presentedMap
    }

    private var mapSurface: some View {
        ZStack(alignment: .top) {
            mapLayer

            // Markers live in the OUTER surface ZStack, not inside mapLayer:
            // sibling layers directly adjacent to MKMapView lose taps to
            // VectorKit's touch handling on real devices (simulator is
            // unaffected). Same full-bleed coordinate space as mapLayer.
            simulatedMarkerOverlay
            favoriteMarkersOverlay
            pinOverlay
            waypointMarkersOverlay
            routeEndpointMarkersOverlay

            if session.targetSelectionMode == .crosshair, !drawMode, !searchPresented {
                crosshairTarget
                    .zIndex(2)
            }

            topChrome
                .zIndex(3)
                .padding(.top, safeAreaTop)

            if !searchPresented {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        rightLowerDynamicControl
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, bottomControlClearance + safeAreaBottom)
                }
                .allowsHitTesting(true)
                .animation(.spring(response: 0.32, dampingFraction: 0.84), value: session.routeActive)
                .animation(.spring(response: 0.32, dampingFraction: 0.84), value: session.routePaused)
                // zIndex 2 left the zoom rail un-hittable: an upper sibling
                // (status chrome) claimed the region first. Keep this container
                // above every chrome layer so the rail always receives touches.
                .zIndex(99)
            }

            if searchPresented {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if searchText.isEmpty, session.searchHistoryEnabled, !session.searchHistory.isEmpty {
                        searchHistoryResults
                    } else if !searchText.isEmpty && !search.results.isEmpty {
                        searchResults
                    }
                    searchBar
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8 + safeAreaBottomRuntime)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(4)
            }

            if let favoriteToast {
                Text(favoriteToast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .locusGlass(.regular, in: Capsule())
                    .padding(.top, 154 + safeAreaTop)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .ignoresSafeArea()
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        safeAreaTop = proxy.safeAreaInsets.top
                        safeAreaBottom = proxy.safeAreaInsets.bottom
                        safeAreaBottomRuntime = proxy.safeAreaInsets.bottom
                    }
                    .onChange(of: proxy.safeAreaInsets.top) { safeAreaTop = $0 }
                    .onChange(of: proxy.safeAreaInsets.bottom) { value in
                        safeAreaBottomRuntime = value
                        // The keyboard inflates the safe-area bottom inset;
                        // keep the rail's inset fixed to the keyboard-free
                        // value so it doesn't jump when search closes.
                        if !keyboardVisible {
                            safeAreaBottom = value
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                        keyboardVisible = true
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                        keyboardVisible = false
                    }
                    .allowsHitTesting(false)
            }
        )
    }

    /// Map + marker overlays share one coordinate space: the surface is
    /// full-bleed (ignoresSafeArea above), so MKMapView's bounds start at the
    /// window origin and convert() results line up with SwiftUI `.position`.
    /// UI chrome (status card, search, right rail) re-applies the safe-area
    /// insets explicitly via `safeAreaTop`/`safeAreaBottom`.
    private var mapLayer: some View {
        ZStack {
            LocusMapView(
                region: $region,
                mapType: mapType,
                animateRegionToken: animateRegionToken,
                simulated: session.simulated,
                routeCoords: routeCoords,
                routeColor: mainRouteColor,
                routeLineWidth: mainRouteLineWidth,
                routeDashed: mainRouteDashed,
                alternativeRouteCoords: alternativeRouteCoords,
                drawnPath: drawnPath,
                onMapViewCreated: { mapView in
                    // makeUIView runs during SwiftUI's view-update phase;
                    // writing @State here is dropped, so defer to the next runloop.
                    DispatchQueue.main.async {
                        self.mapView = mapView
                    }
                },
                onMapTap: handleMapTap,
                onMapLongPress: handleMapLongPress,
                onRegionSettled: handleRegionSettled,
                onRegionChanging: handleRegionChanging,
                onUserInteractionBegan: { userIsManipulatingMap = true },
                onUserInteractionEnded: {
                    userIsManipulatingMap = false
                    // Re-centre now that the camera is the user's again; the
                    // span comes from the map view, so the new zoom is kept.
                    applyDeferredFollowIfNeeded()
                }
            )
            // Fill the container explicitly: a UIViewRepresentable has no
            // intrinsic size, and in a ZStack it can collapse to zero frame
            // on iOS 16 (sizeThatFits behavior), leaving a black screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MapDataSourceProbe(detector: mapDataSourceDetector)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var mapLifecycle: some View {
        mapSurface
        .onAppear {
            session.startLocationUpdates()
            generatedRouteReady = routeReadyState
            drawingRouteActive = drawMode
            drawingRoutePointCount = drawnPath.count
            // A language switch rebuilds this view and loses the camera; restore
            // the exact position and zoom recorded before the switch, before the
            // "restore last map view" branch can pick a stale persisted value.
            let restoredAfterLanguageSwitch = languageStore.needsCameraRestore
            if restoredAfterLanguageSwitch, let live = languageStore.liveMapRegion {
                languageStore.needsCameraRestore = false
                region = live
                if session.targetSelectionMode == .crosshair {
                    session.crosshairCoordinate = live.center
                }
            }
            if restoredAfterLanguageSwitch {
                // Skip the persisted restore: it is older than the live camera
                // and would overwrite it.
            } else if session.restoreLastMapView, let saved = session.savedMapRegion() {
                region = saved
                if session.targetSelectionMode == .crosshair {
                    session.crosshairCoordinate = saved.center
                }
            } else if session.targetSelectionMode == .crosshair,
                      session.crosshairCoordinate == nil {
                session.crosshairCoordinate = session.pin ?? session.simulated ?? session.realMapCoordinate
            }

        }
        .onChange(of: routeReadyState) { ready in
            generatedRouteReady = ready
        }
        .onChange(of: drawMode) { active in
            drawingRouteActive = active
        }
        .onChange(of: routeIsHandDrawn) { handDrawn in
            routeIsHandDrawnPublished = handDrawn
        }
        .onAppear {
            routeIsHandDrawnPublished = routeIsHandDrawn
        }
        .onChange(of: drawnPath.count) { count in
            drawingRoutePointCount = count
        }
        .onDisappear {
            favoriteToastTask?.cancel()
            favoriteToastTask = nil
            favoriteToast = nil
            generatedRouteReady = false
            routeOptions.removeAll()
            selectedRouteOptionID = nil
            drawingRouteActive = false
            drawingRoutePointCount = 0
        }
    }

    private var mapInteractions: some View {
        mapLifecycle
        .onChange(of: searchPresented) { presented in
            if presented {
                pinSelected = false
                pinExpandedActions = false
                selectedFavoriteID = nil
                DispatchQueue.main.async {
                    searchFocused = true
                }
            } else {
                searchFocused = false
            }
        }
        .onChange(of: session.pin?.latitude) { newValue in
            if newValue == nil {
                pinSelected = false
                pinExpandedActions = false
            }
        }
        .onChange(of: session.status) { status in
            if case .idle = status {
                clearRoutePresentation()
            }
        }
    }

    private var mapRouteInteractions: some View {
        mapInteractions
        .onReceive(NotificationCenter.default.publisher(for: .locusImportGPX)) { note in
            guard let data = note.object as? Data else { return }
            importGPX(data: data)
        }
        .onAppear {
            // A GPX opened while the app was still booting arrives before this
            // view subscribes; drain it here.
            if let pending = LocusIncomingURL.takePendingGPX() {
                importGPX(data: pending)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusDeleteRoute)) { _ in
            deleteGeneratedRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusRunRoute)) { _ in
            runGeneratedRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusBuildRouteToTarget)) { _ in
            buildRouteToCurrentTarget()
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusFirstRealFix)) { _ in
            guard !didAutoLocateOnFirstFix else { return }
            didAutoLocateOnFirstFix = true
            goToCurrentLocation()
        }
                .onChange(of: session.targetSelectionMode) { mode in
            closePinActions()
            if mode == .crosshair {
                session.crosshairCoordinate = region.center
            }
        }
        .onChange(of: region.center.latitude) { _ in
            syncCrosshairFromRegion()
        }
        .onChange(of: region.center.longitude) { _ in
            syncCrosshairFromRegion()
        }
        .onChange(of: selectedRouteOptionID) { selectedID in
            guard let selectedID,
                  let option = routeOptions.first(where: { $0.id == selectedID }) else { return }
            routeCoords = option.coordinates
        }
        .onChange(of: simulatedCoordinateKey) { _ in
            followSimulatedLocationIfNeeded()
        }
        .onChange(of: session.locationSummaryRevision) { _ in
            mapDataSourceDetector.redetect()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                mapDataSourceDetector.scheduleDetection()
            }
        }
    }

    private var presentedMap: some View {
        mapRouteInteractions
        .onReceive(NotificationCenter.default.publisher(for: .locusCancelDrawingRoute)) { _ in
            cancelDrawingRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusUndoDrawingPoint)) { _ in
            undoDrawingPoint()
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusSaveDrawingRoute)) { _ in
            saveDrawingRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusEditDrawingRoute)) { _ in
            editHandDrawnRoute()
        }
        .sheet(isPresented: $showSavedRoutes) {
            LocusSavedRoutesSheet { route in
                showSavedRoutes = false
                loadSavedRoute(route)
            }
            .locusMediumLargeDetents()
        }
        .sheet(isPresented: $showRouteSheet) {
            RoutePlannerSheet(
                onPlay: playRoute,
                onImportGPX: importGPXFromPicker,
                onExportGPX: exportGPXFromSheet,
                onSaveRoute: saveRouteFromSheet,
                onShowSavedRoutes: showSavedRoutesFromSheet,
                onBuildRouteToTarget: {
                    showRouteSheet = false
                    buildRouteToCurrentTarget()
                },
                drawMode: drawMode,
                onToggleDrawing: {
                    if !drawMode {
                        beginDrawingRoute()
                    }
                }
            )
            .environmentObject(session)
            .environmentObject(languageStore)
            .locusMediumLargeDetents()
        }
        .locusConfirmAlert(
            L("清空搜索历史"),
            isPresented: $confirmClearSearchHistory,
            confirmTitle: L("清空"),
            onConfirm: { session.clearSearchHistory() },
            message: L("此操作无法撤销。")
        )
    }

    // MARK: - Marker overlays (positioned via MKMapView coordinate conversion)

    @ViewBuilder
    private var simulatedMarkerOverlay: some View {
        if let mapView, let sim = session.simulated {
            let _ = regionChangingToken
            let point = mapView.convert(sim, toPointTo: mapView)
            ZStack {
                Circle().fill(LocusTheme.accent.opacity(0.25)).frame(width: 44, height: 44)
                Circle().fill(LocusTheme.accent).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
            .position(x: point.x, y: point.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var favoriteMarkersOverlay: some View {
        if let mapView {
            let _ = regionChangingToken
            ForEach(session.favorites) { favorite in
                let point = mapView.convert(favorite.coordinate, toPointTo: mapView)
                FavoriteMapMarker(
                    selected: selectedFavoriteID == favorite.id,
                    onSelect: {
                        dismissStatusDetails()
                        selectedFavoriteID = favorite.id
                        selectedWaypointIndex = nil
                        pinSelected = false
                        pinExpandedActions = false
                        if session.targetSelectionMode != .crosshair {
                            selectFavorite(favorite)
                        } else {
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    },
                    onLongPress: {
                        dismissStatusDetails()
                        pinSelected = false
                        pinExpandedActions = false
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            selectedFavoriteID = favorite.id
                        }
                    },
                    onRemove: {
                        removeFavoriteFromMap(favorite)
                    }
                )
                .accessibilityLabel(session.favoriteDisplayName(favorite))
                .accessibilityHint(session.targetSelectionMode == .crosshair
                                   ? L("轻点显示删除按钮")
                                   : L("半秒内松手可切换模拟位置，按住半秒显示删除按钮"))
                .frame(width: 160, height: 92, alignment: .bottom)
                .position(x: point.x, y: point.y - 24)
            }
        }
    }

    @ViewBuilder
    private var pinOverlay: some View {
        if let mapView,
           session.targetSelectionMode == .pin,
           let pin = session.pin,
           session.favorite(at: pin) == nil {
            let _ = regionChangingToken
            let point = mapView.convert(pin, toPointTo: mapView)
            MapDropPin(
                selected: pinSelected,
                expandedActions: pinExpandedActions,
                isDragging: isDraggingPin,
                onSelect: {
                    dismissStatusDetails()
                    searchFocused = false
                    suppressNextMapTap = true
                    selectedFavoriteID = nil
                    selectedWaypointIndex = nil
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        pinSelected = false
                        pinExpandedActions = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        suppressNextMapTap = false
                    }
                },
                onShowExpandedActions: {
                    dismissStatusDetails()
                    searchFocused = false
                    suppressNextMapTap = true
                    selectedFavoriteID = nil
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        pinSelected = true
                        pinExpandedActions = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        suppressNextMapTap = false
                    }
                },
                onRemove: {
                    dismissStatusDetails()
                    suppressNextMapTap = true
                    withAnimation {
                        session.pin = nil
                        pinSelected = false
                        pinExpandedActions = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        suppressNextMapTap = false
                    }
                },
                onBuildRouteToPin: buildRouteToCurrentTarget,
                onDragBegan: {
                    dismissStatusDetails()
                    searchFocused = false
                    suppressNextMapTap = true
                    pinPlaceName = nil
                    pinSelected = false
                    pinExpandedActions = false
                    isDraggingPin = true
                },
                onDragMoved: { globalPoint in
                    // MapDropPin drags report window coordinates; MKMapView
                    // converts those straight to a map coordinate.
                    session.pin = mapView.convert(globalPoint, toCoordinateFrom: nil)
                },
                onDragEnded: {
                    isDraggingPin = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        suppressNextMapTap = false
                    }
                }
            )
            .frame(width: 200, height: 102, alignment: .bottom)
            .position(x: point.x, y: point.y - 51)
        }
    }

    @ViewBuilder
    private var waypointMarkersOverlay: some View {
        if let mapView {
            let _ = regionChangingToken
            ForEach(routeWaypoints.indices, id: \.self) { index in
                let point = mapView.convert(routeWaypoints[index], toPointTo: mapView)
                RouteWaypointMarker(
                    number: index + 1,
                    selected: selectedWaypointIndex == index,
                    onTap: {
                        dismissStatusDetails()
                        pinSelected = false
                        pinExpandedActions = false
                        selectedFavoriteID = nil
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            selectedWaypointIndex = (selectedWaypointIndex == index) ? nil : index
                        }
                    },
                    onRemove: {
                        removeWaypoint(at: index)
                    }
                )
                .frame(width: 140, height: 92, alignment: .bottom)
                .position(x: point.x, y: point.y - 24)
                .zIndex(selectedWaypointIndex == index ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private var routeEndpointMarkersOverlay: some View {
        if let mapView {
            let _ = regionChangingToken
            if let start = drawMode ? drawnPath.first : drawnRouteStart {
                let point = mapView.convert(start, toPointTo: mapView)
                RouteEndpointMarker(color: .green, systemImage: "play.fill")
                    .position(x: point.x, y: point.y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if !drawMode, let end = drawnRouteEnd {
                let point = mapView.convert(end, toPointTo: mapView)
                RouteEndpointMarker(color: .red, systemImage: "stop.fill")
                    .position(x: point.x, y: point.y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Map interactions

    private func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        dismissStatusDetails()
        searchFocused = false
        searchPresented = false
        guard !suppressNextMapTap, !isDraggingPin else { return }
        pinSelected = false
        pinExpandedActions = false
        selectedFavoriteID = nil
        selectedWaypointIndex = nil
        placePin(at: coordinate)
    }

    private func handleMapLongPress(_ coordinate: CLLocationCoordinate2D) {
        guard !hitsInteractiveMarker(at: coordinate) else { return }
        if canAddRouteWaypoint,
           ChinaCoordinateTransform.usesMainlandChinaOffset(coordinate) {
            suppressNextMapTap = true
            routeWaypoints.append(coordinate)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showFavoriteToast(L("已添加途经点 %@，正在重新规划", "\(routeWaypoints.count)"))
            buildRoadRoute()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                suppressNextMapTap = false
            }
        } else if session.targetSelectionMode == .pin {
            placeExpandedPin(at: coordinate)
        }
    }

    /// Drops a waypoint and re-plans the route through the remaining ones.
    ///
    /// Waypoints are ordered, so indices shift after a removal; the selection is
    /// cleared rather than remapped to avoid deleting the wrong marker next.
    private func removeWaypoint(at index: Int) {
        guard routeWaypoints.indices.contains(index) else { return }
        routeWaypoints.remove(at: index)
        selectedWaypointIndex = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if routeWaypoints.isEmpty {
            showFavoriteToast(L("已删除途经点"))
        } else {
            showFavoriteToast(L("已删除途经点，剩余 %@ 个，正在重新规划", "\(routeWaypoints.count)"))
        }
        rebuildRouteAfterWaypointChange()
    }

    /// Re-plans through the remaining waypoints. When none are left the plain
    /// start→end route is rebuilt instead of leaving the old detour on screen.
    private func rebuildRouteAfterWaypointChange() {
        guard routeStart != nil, routeEnd != nil, !routeIsHandDrawn else { return }
        buildRoadRoute()
    }

    /// MapKit reports visible-region changes continuously during a pan/zoom.
    /// Coalesced to one state write per runloop turn: writing on every callback
    /// queues more body evaluations than the display can consume.
    private func handleRegionChanging(_ visibleRegion: MKCoordinateRegion) {
        // Record the live camera. This fires for programmatic `setRegion` too, so
        // the value is valid from the moment the map first positions itself —
        // not only after the user pans, which is what made a language switch
        // right after launch fall back to the default region.
        languageStore.liveMapRegion = visibleRegion
        guard !regionChangePending else { return }
        regionChangePending = true
        DispatchQueue.main.async {
            regionChangePending = false
            regionChangingToken &+= 1
        }
    }

    /// Re-centres on the last position seen while the user was manipulating the
    /// map. Called once the gesture has ended, so the zoom level survives.
    private func applyDeferredFollowIfNeeded() {
        guard let pending = deferredFollowCoordinate else { return }
        deferredFollowCoordinate = nil
        guard session.autoFollowRoute, session.routeActive else { return }
        let span = mapView?.region.span ?? region.span
        region = MKCoordinateRegion(center: pending, span: span)
    }

    private func handleRegionSettled() {
        if let pending = deferredFollowCoordinate {
            deferredFollowCoordinate = nil
            // Apply the position that arrived during the gesture, keeping the
            // span the user just zoomed to.
            if session.autoFollowRoute, session.routeActive {
                let span = mapView?.region.span ?? region.span
                region = MKCoordinateRegion(center: pending, span: span)
            }
        }
        session.saveMapRegion(region)
        let suppressed = Date() <= session.crosshairSettleSuppressedUntil
        if session.targetSelectionMode == .crosshair,
           !suppressed {
            session.crosshairCoordinate = region.center
            if let named = searchNamedCoordinate,
               CLLocation(latitude: named.latitude, longitude: named.longitude)
                .distance(from: CLLocation(
                    latitude: region.center.latitude,
                    longitude: region.center.longitude
                )) > 15 {
                pinPlaceName = nil
                searchNamedCoordinate = nil
            }
        }
    }

    private func placePin(at coordinate: CLLocationCoordinate2D) {
        if drawMode {
            drawnPath.append(coordinate)
        } else if session.targetSelectionMode == .pin {
            session.pin = coordinate
            pinPlaceName = nil
            pinSelected = false
        }
    }

    private func placeExpandedPin(at coordinate: CLLocationCoordinate2D) {
        guard session.targetSelectionMode == .pin,
              !drawMode,
              !suppressNextMapTap,
              !isDraggingPin else { return }
        if let pin = session.pin, let mapView {
            let anchor = mapView.convert(pin, toPointTo: mapView)
            let pinHitArea = CGRect(
                x: anchor.x - 36,
                y: anchor.y - 72,
                width: 72,
                height: 88
            )
            let point = mapView.convert(coordinate, toPointTo: mapView)
            guard !pinHitArea.contains(point) else { return }
        }
        suppressNextMapTap = true
        searchFocused = false
        searchPresented = false
        selectedFavoriteID = nil
        pinPlaceName = nil
        session.pin = coordinate
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            pinSelected = true
            pinExpandedActions = true
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            suppressNextMapTap = false
        }
    }

    private func hitsInteractiveMarker(at coordinate: CLLocationCoordinate2D) -> Bool {
        guard let mapView else { return false }
        let point = mapView.convert(coordinate, toPointTo: mapView)
        if session.favorites.contains(where: { favorite in
            let markerPoint = mapView.convert(favorite.coordinate, toPointTo: mapView)
            return hypot(markerPoint.x - point.x, markerPoint.y - point.y) <= 36
        }) {
            return true
        }

        if session.targetSelectionMode == .pin,
           let pin = session.pin {
            let markerPoint = mapView.convert(pin, toPointTo: mapView)
            let hitArea = CGRect(
                x: markerPoint.x - 36,
                y: markerPoint.y - 76,
                width: 72,
                height: 92
            )
            if hitArea.contains(point) { return true }
        }

        // Waypoints are tappable now; a long press on one must not append a new
        // waypoint on top of it.
        for waypoint in routeWaypoints {
            let markerPoint = mapView.convert(waypoint, toPointTo: mapView)
            if hypot(markerPoint.x - point.x, markerPoint.y - point.y) <= 30 {
                return true
            }
        }

        return false
    }

    private var topChrome: some View {
        StatusBarView(mapDataSourceDetector: mapDataSourceDetector)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.bottom, 2)
    }

    private var crosshairTarget: some View {
        ZStack {
            Rectangle()
                .frame(width: 30, height: 2)
            Rectangle()
                .frame(width: 2, height: 30)
        }
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
        .frame(width: 34, height: 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundColor(.secondary)
            TextField(L("搜索地点、地址或坐标"), text: $searchText)
                .locusAutocapitalizationWords()
                .locusFocused($searchFocused)
                .locusSubmitLabelSearch()
                .locusOnSubmit {
                    searchFocused = false
                    searchTextDirectly()
                }
                .onChange(of: searchText) { value in
                    search.region = searchRegion
                    search.query = value
                }
            if searchFocused || !searchText.isEmpty {
                Button {
                    searchText = ""
                    search.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("清除搜索内容"))
            }
            if searchPresented {
                Button {
                    searchFocused = false
                    searchPresented = false
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel(L("收起搜索"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .locusGlass(.interactive, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(search.results.prefix(5), id: \.self) { item in
                    Button {
                        select(completion: item)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.body)
                                .foregroundColor(LocusTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.primary)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.3)
                }
            }
        }
        .locusScrollIndicatorsHidden()
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxHeight: 300)
    }

    private var searchHistoryResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(L("搜索历史"), systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        confirmClearSearchHistory = true
                    } label: {
                        Label(L("清空"), systemImage: "trash")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(LocusTheme.danger)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .frame(height: 42)

                Divider().opacity(0.3)

                ForEach(session.searchHistory.prefix(20)) { entry in
                    HStack(spacing: 8) {
                        Button {
                            select(history: entry)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.fill")
                                    .foregroundColor(LocusTheme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.primary)
                                    if !entry.subtitle.isEmpty {
                                        Text(entry.subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            session.removeSearchHistory(entry)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .frame(width: 36, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("删除搜索历史：%@", "\(entry.title)"))
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .frame(minHeight: 54)
                    Divider().opacity(0.3)
                }
            }
        }
        .locusScrollIndicatorsHidden()
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxHeight: 300)
    }

    private var rightLowerDynamicControl: some View {
        ZStack(alignment: .bottomTrailing) {
            if session.joystickActive {
                JoystickPad { vector in
                    session.updateJoystick(vector: vector)
                }
                .frame(width: 148, height: 148)
                .matchedGeometryEffect(id: "rightLowerControl", in: rightLowerControlNamespace)
                .transition(.scale(scale: 0.55, anchor: .bottomTrailing).combined(with: .opacity))
            } else {
                ZStack(alignment: .bottomTrailing) {
                    rightLowerControls
                    if session.zoomSliderEnabled {
                        railZoomHandle
                            .offset(
                                x: -(MapChromeLayout.rightColumnWidth - 32) / 2,
                                y: -(MapChromeLayout.rightColumnWidth * 4 + 10)
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .matchedGeometryEffect(id: "rightLowerControl", in: rightLowerControlNamespace)
                .transition(.scale(scale: 0.55, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .frame(
            width: 148,
            height: session.joystickActive ? 148 : MapChromeLayout.rightColumnWidth * 7 + 18,
            alignment: .bottomTrailing
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.joystickActive)
    }

    private var railZoomHandle: some View {
        VStack(spacing: 8) {
            Image(systemName: "chevron.up")
            Capsule()
                .fill(Color.primary.opacity(0.45))
                .frame(width: 3, height: 70)
            Image(systemName: "chevron.down")
        }
        .font(.caption2.weight(.bold))
        .foregroundColor(.secondary)
        .frame(width: 32, height: MapChromeLayout.rightColumnWidth * 3)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Rectangle())
        .gesture(zoomGesture)
        .accessibilityLabel(L("地图缩放手势区"))
        .accessibilityHint(L("直接向上滑放大，向下滑缩小"))
    }

    private var zoomGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                activateEdgeZoomIfNeeded()
                updateEdgeZoom(value.translation.height)
                let feedbackStep = Int((value.translation.height / 72).rounded(.towardZero))
                if feedbackStep != edgeZoomFeedbackStep {
                    edgeZoomFeedbackStep = feedbackStep
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            .onEnded { _ in
                guard edgeZoomActive else { return }
                edgeZoomActive = false
                edgeZoomFeedbackStep = 0
                endEdgeZoom()
            }
    }

    private func activateEdgeZoomIfNeeded() {
        guard !edgeZoomActive else { return }
        edgeZoomActive = true
        edgeZoomFeedbackStep = 0
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        beginEdgeZoom()
    }

    private var rightLowerControls: some View {
        VStack(spacing: 0) {
            Button {
                dismissStatusDetails()
                toggleCurrentFavorite()
            } label: {
                Image(systemName: currentPinIsFavorite ? "star.fill" : "star")
                    .font(.body.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(currentPinIsFavorite ? Color.yellow : Color.primary)
            .disabled(session.selectedTargetCoordinate == nil)
            .accessibilityLabel(currentPinIsFavorite ? L("取消收藏") : L("添加收藏"))

            Divider()
                .overlay(Color.white.opacity(0.22))
                .frame(width: 32)

            rightRailIconButton("folder.fill") {
                dismissStatusDetails()
                searchFocused = false
                showPlaces = true
            }
            .accessibilityLabel(L("打开收藏夹"))

            Divider()
                .overlay(Color.white.opacity(0.22))
                .frame(width: 32)

            rightRailIconButton(SFSymbolCompat.resolved("square.3.layers.3d")) {
                dismissStatusDetails()
                session.mapStyleIndex = (session.mapStyleIndex + 1) % 2
            }
            .accessibilityLabel(L("切换地图图层"))

            Divider()
                .overlay(Color.white.opacity(0.22))
                .frame(width: 32)

            rightRailIconButton("location.fill") {
                dismissStatusDetails()
                UISelectionFeedbackGenerator().selectionChanged()
                searchFocused = false
                handleLocationButtonTap()
            }
            .accessibilityLabel(L("回到当前位置；再次轻点回正北"))
        }
        .padding(4)
        .frame(width: MapChromeLayout.rightColumnWidth)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
        .foregroundColor(.primary)
    }

    private func dismissStatusDetails() {
        NotificationCenter.default.post(name: .locusDismissStatusDetails, object: nil)
    }

    private var bottomControlClearance: CGFloat {
        MapChromeLayout.rightRailClearance
    }

    private var routeReadyState: Bool {
        routeCoords.count > 1 && !drawMode && !session.routeActive && !session.routePaused
    }

    private var canAddRouteWaypoint: Bool {
        guard let routeStart else { return false }
        return routeReadyState &&
            !routeIsHandDrawn &&
            !isRouting &&
            routeEnd != nil &&
            ChinaCoordinateTransform.usesMainlandChinaOffset(routeStart)
    }

    private var selectedPlannedRoute: PlannedRoute? {
        guard let selectedRouteOptionID else { return routeOptions.first }
        return routeOptions.first(where: { $0.id == selectedRouteOptionID }) ?? routeOptions.first
    }

    private var selectedRouteColor: Color {
        Color(red: 0.0, green: 0.42, blue: 0.24)
    }

    private var unselectedRouteColor: Color {
        Color(red: 0.39, green: 0.78, blue: 0.55).opacity(0.72)
    }

    private var presentedRouteColor: Color {
        routeIsHandDrawn ? LocusTheme.accentSecondary : LocusTheme.accent
    }

    /// The route overlay style depends on whether alternatives exist:
    /// - No alternatives: the presented route (hand-drawn dashed vs. accent solid).
    /// - With alternatives: the selected option in dark green.
    private var mainRouteColor: Color {
        routeOptions.isEmpty ? presentedRouteColor : selectedRouteColor
    }

    private var mainRouteLineWidth: CGFloat {
        if routeOptions.isEmpty { return routeIsHandDrawn ? 4 : 5 }
        return 9
    }

    private var mainRouteDashed: Bool {
        routeOptions.isEmpty && routeIsHandDrawn
    }

    private var alternativeRouteCoords: [[CLLocationCoordinate2D]] {
        routeOptions
            .filter { $0.id != selectedRouteOptionID }
            .map(\.coordinates)
    }

    private var currentPinIsFavorite: Bool {
        guard let target = session.selectedTargetCoordinate else { return false }
        return session.favorite(at: target) != nil
    }

    /// Centers on the spoofed fix while spoofing, otherwise the real GPS —
    /// never the leftover teleport pin (`.automatic` would frame that marker).
    private func goToCurrentLocation() {
        let recenterDistance: CLLocationDistance = 750
        let newRegion: MKCoordinateRegion
        if session.isSpoofing, let sim = session.simulated {
            newRegion = MKCoordinateRegion(
                center: sim,
                latitudinalMeters: recenterDistance,
                longitudinalMeters: recenterDistance
            )
        } else if let real = session.realMapCoordinate {
            newRegion = MKCoordinateRegion(
                center: real,
                latitudinalMeters: recenterDistance,
                longitudinalMeters: recenterDistance
            )
        } else {
            newRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                latitudinalMeters: 2000,
                longitudinalMeters: 2000
            )
        }
        animateRegionToken += 1
        region = newRegion
    }

    private func handleLocationButtonTap() {
        let now = Date()
        if let lastLocationButtonTap,
           now.timeIntervalSince(lastLocationButtonTap) <= 2 {
            faceMapNorth()
            self.lastLocationButtonTap = nil
        } else {
            goToCurrentLocation()
            lastLocationButtonTap = now
        }
    }

    private func faceMapNorth() {
        guard let camera = mapView?.camera else {
            goToCurrentLocation()
            return
        }
        animateRegionToken += 1
        region = MKCoordinateRegion(
            center: camera.centerCoordinate,
            span: region.span
        )
    }

    private func beginEdgeZoom() {
        edgeZoomStartRegion = region
    }

    private func updateEdgeZoom(_ verticalTranslation: CGFloat) {
        guard let start = edgeZoomStartRegion, let mapView else { return }
        let scale = pow(2, Double(verticalTranslation / 120))
        let latitudeDelta = min(120, max(0.0005, start.span.latitudeDelta * scale))
        let longitudeDelta = min(360, max(0.0005, start.span.longitudeDelta * scale))
        let newRegion = MKCoordinateRegion(
            center: start.center,
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        )
        // Apply directly to the map: routing through the `region` @State would
        // race regionDidChangeAnimated, whose write-back of the PREVIOUS frame's
        // value overwrites this frame's update before updateUIView applies it
        // (regionDiffers then sees no change) — leaving the slider dead.
        mapView.setRegion(newRegion, animated: false)
    }

    private func endEdgeZoom() {
        edgeZoomStartRegion = nil
    }

    private func rightRailIconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.primary)
    }

    private func toggleCurrentFavorite() {
        guard let target = session.selectedTargetCoordinate else { return }
        let name = session.suggestedFavoriteName(for: target, fallback: pinPlaceName)
        let result = session.toggleFavorite(name: name, coordinate: target)
        pinSelected = false
        pinExpandedActions = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if result.added, let favorite = session.favorite(at: target) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                favoriteRenameSuggestion = favorite
            }
        } else if let suggestion = favoriteRenameSuggestion,
                  session.favorite(at: suggestion.coordinate) == nil {
            favoriteRenameSuggestion = nil
        }
        showFavoriteToast(result.added ? L("已收藏：%@", "\(result.name)") : L("已取消收藏：%@", "\(result.name)"))
    }

    private func selectFavorite(_ favorite: SavedPlace) {
        suppressNextMapTap = true
        pinSelected = false
        pinPlaceName = session.favoriteDisplayName(favorite)
        searchNamedCoordinate = favorite.coordinate
        session.pin = favorite.coordinate
        if session.targetSelectionMode == .crosshair {
            session.crosshairCoordinate = favorite.coordinate
            let span = region.span
            region = MKCoordinateRegion(center: favorite.coordinate, span: span)
        }
        session.teleport(to: favorite.coordinate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            suppressNextMapTap = false
        }
    }

    private func removeFavoriteFromMap(_ favorite: SavedPlace) {
        suppressNextMapTap = true
        selectedFavoriteID = nil
        pinSelected = false
        pinExpandedActions = false
        if favoriteRenameSuggestion?.id == favorite.id {
            favoriteRenameSuggestion = nil
        }
        session.removeFavorite(favorite)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showFavoriteToast(L("已删除收藏：%@", "\(session.favoriteDisplayName(favorite))"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            suppressNextMapTap = false
        }
    }

    private func buildRouteToCurrentTarget() {
        guard !session.routeActive, !session.routePaused else {
            session.lastError = L("请先结束当前轨迹，再生成新轨迹。")
            return
        }
        guard let target = session.selectedTargetCoordinate else {
            session.lastError = session.targetSelectionMode == .crosshair
                ? L("尚未取得准星位置，请先移动地图。")
                : L("请先在地图上放置图钉。")
            return
        }
        guard let current = currentRouteLocation else {
            session.lastError = L("尚未取得当前定位，请稍后重试。")
            return
        }
        routeStart = current
        routeEnd = target
        routeWaypoints.removeAll()
        selectedWaypointIndex = nil
        editingVertices = nil
        closePinActions()
        showFavoriteToast(session.targetSelectionMode == .crosshair
                          ? L("正在生成前往准星的道路轨迹")
                          : L("正在生成前往图钉的道路轨迹"))
        buildRoadRoute()
    }

    private func closePinActions() {
        suppressNextMapTap = true
        withAnimation(.easeOut(duration: 0.15)) {
            pinSelected = false
            pinExpandedActions = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            suppressNextMapTap = false
        }
    }

    private var currentRouteLocation: CLLocationCoordinate2D? {
        // Same fallback chain as the ios16 build: simulated → real GPS → pin.
        session.simulated ?? session.realMapCoordinate ?? session.pin
    }

    private var simulatedCoordinateKey: String {
        guard let coordinate = session.simulated else { return "none" }
        return String(format: "%.7f,%.7f", coordinate.latitude, coordinate.longitude)
    }

    private func followSimulatedLocationIfNeeded() {
        guard session.autoFollowRoute,
              session.routeActive,
              let simulated = session.simulated else { return }
        guard !userIsManipulatingMap else {
            // Keep the latest position; the camera is re-centred once the
            // pinch/pan ends, so the user's zoom survives.
            deferredFollowCoordinate = simulated
            return
        }
        // Read the zoom level from the map view, not from `region`: during and
        // right after a pinch the binding still holds the pre-gesture span, and
        // re-applying that is what snapped the zoom level back.
        let span = mapView?.region.span ?? region.span
        region = MKCoordinateRegion(center: simulated, span: span)
    }

    private func showFavoriteToast(_ message: String) {
        favoriteToastTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            favoriteToast = message
        }
        favoriteToastTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                favoriteToast = nil
            }
        }
    }

    private var searchRegion: MKCoordinateRegion {
        let center = session.selectedTargetCoordinate ?? session.simulated ?? session.realMapCoordinate ??
            CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
        return MKCoordinateRegion(center: center, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
    }

    private func searchTextDirectly() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        Task {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = searchRegion
            if let response = try? await MKLocalSearch(request: request).start(),
               let item = response.mapItems.first {
                let coord = item.placemark.coordinate
                await MainActor.run {
                    applySearchResult(
                        title: item.name ?? query,
                        subtitle: item.placemark.title ?? "",
                        coordinate: coord
                    )
                }
            } else {
                await MainActor.run { session.lastError = L("没有找到匹配的地点。") }
            }
        }
    }

    private func select(completion: MKLocalSearchCompletion) {
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            if let response = try? await MKLocalSearch(request: request).start(),
               let item = response.mapItems.first {
                let coord = item.placemark.coordinate
                let title = item.name ?? completion.title
                await MainActor.run {
                    applySearchResult(
                        title: title,
                        subtitle: completion.subtitle,
                        coordinate: coord
                    )
                }
            }
        }
    }

    private func select(history entry: SearchHistoryEntry) {
        applySearchResult(title: entry.title, subtitle: entry.subtitle, coordinate: entry.coordinate)
    }

    private func applySearchResult(
        title: String,
        subtitle: String,
        coordinate: CLLocationCoordinate2D
    ) {
        pinPlaceName = title
        searchNamedCoordinate = coordinate
        session.crosshairCoordinate = coordinate
        if session.targetSelectionMode == .pin {
            session.pin = coordinate
        }
        // The animated jump below fires regionDidChangeAnimated mid-flight;
        // handleRegionSettled would overwrite the search target with a
        // half-way center. Suppress it until the jump settles.
        session.crosshairSettleSuppressedUntil = Date().addingTimeInterval(1.0)
        animateRegionToken += 1
        region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 1200,
            longitudinalMeters: 1200
        )
        searchText = ""
        search.query = ""
        searchFocused = false
        searchPresented = false
        session.pushNamedRecent(name: title, coordinate: coordinate)
        session.recordSearch(title: title, subtitle: subtitle, coordinate: coordinate)
    }

    private func syncCrosshairFromRegion() {
        guard session.targetSelectionMode == .crosshair,
              Date() > session.crosshairSettleSuppressedUntil else { return }
        session.crosshairCoordinate = region.center
    }

    private func buildRoadRoute() {
        guard !isRouting else { return }
        guard let start = routeStart, let end = routeEnd else {
            session.lastError = L("请设置路线起点和终点。")
            return
        }
        isRouting = true
        Task {
            do {
                let options = try await RouteBuilder.roadRoutes(
                    from: start,
                    to: end,
                    via: routeWaypoints,
                    mode: session.travelMode,
                    requestsAlternatives: ChinaCoordinateTransform.usesMainlandChinaOffset(start)
                )
                await MainActor.run {
                    drawnPath.removeAll()
                    drawnRouteStart = nil
                    drawnRouteEnd = nil
                    drawMode = false
                    routeIsHandDrawn = false
                    routeOptions = options
                    selectedRouteOptionID = options.first?.id
                    routeCoords = options.first?.coordinates ?? []
                    isRouting = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    showFavoriteToast(L("道路轨迹已生成"))
                }
            } catch {
                await MainActor.run {
                    isRouting = false
                    session.lastError = error.localizedDescription
                }
            }
        }
    }

    private func playRoute() {
        if let selectedPlannedRoute {
            routeOptions = [selectedPlannedRoute]
            selectedRouteOptionID = selectedPlannedRoute.id
            routeCoords = selectedPlannedRoute.coordinates
        }
        let path = routeCoords
        guard path.count >= 2 else {
            session.lastError = L("请先规划、手绘或导入一条轨迹。")
            return
        }
        showRouteSheet = false
        session.followRoute(path)
    }

    private func runGeneratedRoute() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if session.canResumeRoute {
            session.resumeRoute()
        } else {
            playRoute()
        }
    }

    private func deleteGeneratedRoute() {
        withAnimation(.easeOut(duration: 0.2)) {
            clearRoutePresentation()
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showFavoriteToast(L("轨迹已删除"))
    }

    private func clearRoutePresentation() {
        session.discardRoute()
        routeCoords.removeAll()
        routeOptions.removeAll()
        selectedRouteOptionID = nil
        routeWaypoints.removeAll()
        selectedWaypointIndex = nil
        editingVertices = nil
        drawnPath.removeAll()
        drawnRouteStart = nil
        drawnRouteEnd = nil
        drawMode = false
        routeIsHandDrawn = false
        routeStart = nil
        routeEnd = nil
    }

    private func beginDrawingRoute() {
        session.discardRoute()
        routeCoords.removeAll()
        routeOptions.removeAll()
        selectedRouteOptionID = nil
        routeWaypoints.removeAll()
        selectedWaypointIndex = nil
        editingVertices = nil
        drawnPath.removeAll()
        drawnRouteStart = nil
        drawnRouteEnd = nil
        routeIsHandDrawn = false
        routeStart = nil
        routeEnd = nil
        drawMode = true
        closePinActions()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showFavoriteToast(L("已开始手绘轨迹"))
    }

    /// Re-opens a finished hand-drawn route for further editing.
    ///
    /// `saveDrawingRoute` samples `drawnPath` into `routeCoords` and leaves draw
    /// mode, so the original vertices are what has to come back; the sampled
    /// line only exists for display. Restoring `drawnPath` keeps undo and
    /// "保存" working from where the user stopped.
    private func editHandDrawnRoute() {
        guard routeIsHandDrawn else { return }
        let vertices = editingVertices ?? (drawnPath.count > 1 ? drawnPath : routeCoords)
        guard vertices.count > 1 else {
            session.lastError = L("这条轨迹没有可编辑的手绘点。")
            return
        }
        session.discardRoute()
        drawnPath = vertices
        drawnRouteStart = nil
        drawnRouteEnd = nil
        routeOptions.removeAll()
        selectedRouteOptionID = nil
        routeWaypoints.removeAll()
        selectedWaypointIndex = nil
        editingVertices = nil
        routeIsHandDrawn = false
        routeCoords.removeAll()
        routeStart = nil
        routeEnd = nil
        drawMode = true
        closePinActions()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showFavoriteToast(L("可继续编辑手绘轨迹"))
    }

    private func cancelDrawingRoute() {
        guard drawMode else { return }
        drawnPath.removeAll()
        drawnRouteStart = nil
        drawnRouteEnd = nil
        drawMode = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showFavoriteToast(L("已取消手绘"))
    }

    private func undoDrawingPoint() {
        guard drawMode, !drawnPath.isEmpty else { return }
        drawnPath.removeLast()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func saveDrawingRoute() {
        guard drawMode, drawnPath.count > 1,
              let start = drawnPath.first,
              let end = drawnPath.last else {
            session.lastError = L("请至少绘制两个点后再保存。")
            return
        }
        drawnRouteStart = start
        drawnRouteEnd = end
        routeIsHandDrawn = true
        routeOptions.removeAll()
        selectedRouteOptionID = nil
        routeWaypoints.removeAll()
        selectedWaypointIndex = nil
        editingVertices = nil
        routeCoords = RouteBuilder.sample(coordinates: drawnPath, every: 10)
        drawnPath.removeAll()
        drawMode = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showFavoriteToast(L("手绘轨迹已保存"))
    }

    private func importGPXFromPicker() {
        // Presented on the route sheet itself, so the page stays put; closing it
        // first made the sheet disappear the moment the picker appeared.
        LocusDocumentExchange.pickDocument(contentTypes: [.xml, .data]) { url in
            importGPX(url)
        }
    }
    private func importGPX(_ url: URL) {
        do {
            try applyGPX(LocusFileReader.data(from: url))
            // The route is on the map now; the sheet has served its purpose.
            showRouteSheet = false
        } catch {
            LocusDocumentExchange.notify(title: L("导入 GPX 失败"), message: error.localizedDescription)
        }
    }

    private func importGPX(data: Data) {
        do {
            try applyGPX(data)
        } catch {
            LocusDocumentExchange.notify(title: L("导入 GPX 失败"), message: error.localizedDescription)
        }
    }

    private func applyGPX(_ data: Data) throws {
        let coords = try GPXCodec.parse(data: data)
        drawnPath.removeAll()
        drawnRouteStart = nil
        drawnRouteEnd = nil
        drawMode = false
        routeIsHandDrawn = false
        routeOptions.removeAll()
        selectedRouteOptionID = nil
        routeWaypoints.removeAll()
        selectedWaypointIndex = nil
        editingVertices = nil
        routeCoords = RouteBuilder.sample(coordinates: coords, every: 10)
        generatedRouteReady = routeReadyState
        if let first = coords.first {
            session.pin = first
            region = MKCoordinateRegion(center: first, latitudinalMeters: 2000, longitudinalMeters: 2000)
        }
    }

    private func exportGPXFromSheet() {
        // The share sheet is presented on the topmost controller, so the route
        // sheet no longer has to close first; UIKit presents it over the page.
        exportGPX()
    }

    // MARK: - Saved routes

    /// Path currently on the map, preferring the sampled route over the raw
    /// drawing so a saved route matches what is displayed.
    private var currentRoutePath: [CLLocationCoordinate2D] {
        routeCoords.isEmpty ? drawnPath : routeCoords
    }

    private func saveRouteFromSheet() {
        let path = currentRoutePath
        guard path.count > 1 else {
            session.lastError = L("当前没有可保存的轨迹。")
            return
        }
        // The rename alert is hosted by the map view, so the route sheet has to
        // close first; that also matches how the other alerts are presented.
        showRouteSheet = false
        let suggestion = defaultRouteName()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            LocusDocumentExchange.promptForText(
                title: L("保存轨迹"),
                message: L("为这条轨迹命名，之后可在轨迹页的「已保存轨迹」中重新载入。"),
                placeholder: L("轨迹名称"),
                initialText: suggestion
            ) { name in
                commitRouteSave(name: name)
            }
        }
    }

    private func showSavedRoutesFromSheet() {
        showRouteSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            showSavedRoutes = true
        }
    }

    private func defaultRouteName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return L("轨迹 %@", "\(formatter.string(from: Date()))")
    }

    private func commitRouteSave(name input: String) {
        let path = currentRoutePath
        guard path.count > 1 else {
            session.lastError = L("当前没有可保存的轨迹。")
            return
        }
        guard path.count <= SavedRoute.maxStoredPoints else {
            session.lastError = SavedRouteError.tooManyPoints(path.count).localizedDescription
            return
        }

        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // `routeIsHandDrawn` is only set once a drawing is committed; while the
        // user is still in draw mode it is false, so drawMode has to be checked
        // first or an in-progress sketch is saved as a plain route.
        let source: SavedRoute.Source = drawMode
            ? .drawn
            : (routeIsHandDrawn ? .drawn : (routeOptions.isEmpty ? .imported : .planned))

        var routes = SavedRoute.load()
        // A hand-drawn route keeps its original vertices: the displayed line is
        // resampled every 10 m, which loses the corners needed to edit it again.
        let raw: [CLLocationCoordinate2D]? = (drawMode || routeIsHandDrawn)
            ? (drawnPath.count > 1 ? drawnPath : (editingVertices ?? path))
            : nil
        let route = SavedRoute(
            name: name.isEmpty ? defaultRouteName() : name,
            coordinates: path,
            source: source,
            rawVertices: raw
        )
        routes.insert(route, at: 0)
        if routes.count > SavedRoute.maxStoredRoutes {
            routes = Array(routes.prefix(SavedRoute.maxStoredRoutes))
        }
        SavedRoute.save(routes)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showFavoriteToast(L("轨迹已保存"))
    }

    private func loadSavedRoute(_ route: SavedRoute) {
        let coords = route.coordinates
        guard coords.count > 1 else { return }
        drawnPath.removeAll()
        drawMode = false
        routeOptions.removeAll()
        selectedRouteOptionID = nil
        routeWaypoints.removeAll()
        selectedWaypointIndex = nil
        editingVertices = nil
        routeCoords = RouteBuilder.sample(coordinates: coords, every: 10)
        // Restore the same presentation the route had when it was saved: a
        // hand-drawn track is dashed and orange (and brings back its end caps),
        // an imported or planned one keeps the solid accent stroke.
        routeIsHandDrawn = route.source == .drawn
        if routeIsHandDrawn {
            drawnRouteStart = coords.first
            drawnRouteEnd = coords.last
            editingVertices = route.editableVertices
        } else {
            drawnRouteStart = nil
            drawnRouteEnd = nil
            editingVertices = nil
        }
        generatedRouteReady = routeReadyState
        if let first = coords.first {
            session.pin = first
            region = MKCoordinateRegion(center: first, latitudinalMeters: 2000, longitudinalMeters: 2000)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showFavoriteToast(L("已载入「%@」", "\(route.name)"))
    }

    private func exportGPX() {
        let path = routeCoords.isEmpty ? drawnPath : routeCoords
        guard !path.isEmpty else {
            // `session.lastError` drives a SwiftUI alert that is swallowed while
            // this sheet is up, so failures are reported through UIKit alerts.
            LocusDocumentExchange.notify(title: L("导出 GPX"), message: L("当前没有可导出的轨迹。"))
            return
        }
        let gpx = GPXCodec.export(path)
        guard let data = gpx.data(using: .utf8) else {
            LocusDocumentExchange.notify(title: L("导出 GPX"), message: L("无法生成 GPX 数据。"))
            return
        }
        GPXCodec.RecentExports.store(data, filename: "Locus-Route.gpx")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Locus-Route.gpx")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            LocusDocumentExchange.notify(title: L("导出失败"), message: error.localizedDescription)
            return
        }
        LocusDocumentExchange.share(fileAt: url) { error in
            LocusDocumentExchange.notify(title: L("导出失败"), message: error.localizedDescription)
        }
    }
}

private struct FavoriteMapMarker: View {
    var selected: Bool
    var onSelect: () -> Void
    var onLongPress: () -> Void
    var onRemove: () -> Void
    @State private var isPressing = false
    @State private var longPressActivated = false
    @State private var longPressTask: Task<Void, Never>?
    @State private var pressStarted = false
    @State private var pressCancelled = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Button {
                guard !longPressActivated, !pressCancelled else { return }
                onSelect()
            } label: {
                Image(systemName: "star.fill")
                    .font(.title3.weight(.bold))
                    .foregroundColor(.yellow)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .frame(width: 44, height: 44)
                    .scaleEffect(isPressing ? 0.92 : 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(favoritePressGesture)

            if selected {
                Label(L("删除收藏"), systemImage: "trash.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(LocusTheme.danger)
                    .lineLimit(1)
                    .frame(width: 150, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onRemove()
                    }
                    .accessibilityLabel(L("删除收藏"))
                    .accessibilityAddTraits(.isButton)
                    .locusGlass(.regular, in: Capsule())
                    .offset(y: -46)
                    .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
            }
        }
        // The delete button remains inside this frame, so the map cannot receive
        // it as a background tap and create a replacement pin.
        .frame(width: 160, height: 92, alignment: .bottom)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: selected)
        .animation(.easeOut(duration: 0.12), value: isPressing)
        .onDisappear {
            longPressTask?.cancel()
            longPressTask = nil
        }
    }

    private var favoritePressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !pressStarted {
                    pressStarted = true
                    pressCancelled = false
                    isPressing = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    longPressTask?.cancel()
                    longPressTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled, pressStarted, !longPressActivated else { return }
                        longPressActivated = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onLongPress()
                    }
                }

                let movement = max(abs(value.translation.width), abs(value.translation.height))
                if movement > 12, !longPressActivated {
                    longPressTask?.cancel()
                    longPressTask = nil
                    pressCancelled = true
                    isPressing = false
                }
            }
            .onEnded { _ in
                longPressTask?.cancel()
                longPressTask = nil
                pressStarted = false
                isPressing = false
                if longPressActivated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        longPressActivated = false
                        pressCancelled = false
                    }
                } else if pressCancelled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        pressCancelled = false
                    }
                }
            }
    }
}

private struct RouteEndpointMarker: View {
    let color: Color
    let systemImage: String

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundColor(.white)
        }
        .frame(width: 24, height: 24)
        .overlay(Circle().stroke(.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .accessibilityHidden(true)
    }
}

private struct RouteWaypointMarker: View {
    let number: Int
    var selected: Bool = false
    var onTap: () -> Void = {}
    var onRemove: () -> Void = {}

    var body: some View {
        ZStack(alignment: .bottom) {
            Button(action: onTap) {
                ZStack {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title.weight(.semibold))
                        .foregroundColor(selected ? LocusTheme.accent : .blue)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    Text("\(number)")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                        .offset(y: -2)
                }
                .frame(width: 38, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected {
                // Same pattern as the favorite star: tapping selects, then the
                // delete pill appears above the marker.
                Button(action: onRemove) {
                    Label(L("删除途经点"), systemImage: "trash.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(LocusTheme.danger)
                        .lineLimit(1)
                        .frame(width: 140, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .locusGlass(.regular, in: Capsule())
                .offset(y: -46)
                .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                .accessibilityLabel(L("删除途经点 %@", "\(number)"))
            }
        }
        .frame(width: 140, height: 92, alignment: .bottom)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: selected)
        .accessibilityLabel(L("途经点 %@", "\(number)"))
        .accessibilityHint(selected ? L("再次轻点收起，或点上方按钮删除") : L("轻点显示删除按钮"))
    }
}

// MARK: - MKMapView bridge (iOS 16)

/// UIViewRepresentable wrapping MKMapView so the map works on iOS 16, where the
/// SwiftUI Map / MapReader / MapCameraPosition API is unavailable.
struct LocusMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    var mapType: MKMapType
    /// Bump to ease the next region change over 0.35s (locate button).
    var animateRegionToken: Int
    var simulated: CLLocationCoordinate2D?
    var routeCoords: [CLLocationCoordinate2D]
    var routeColor: Color
    var routeLineWidth: CGFloat
    var routeDashed: Bool
    var alternativeRouteCoords: [[CLLocationCoordinate2D]]
    var drawnPath: [CLLocationCoordinate2D]
    var onMapViewCreated: (MKMapView) -> Void
    var onMapTap: (CLLocationCoordinate2D) -> Void
    var onMapLongPress: (CLLocationCoordinate2D) -> Void
    var onRegionSettled: (() -> Void)?
    /// Fires continuously while the user pans/zooms, so screen-space overlays
    /// (favorite stars, pins) track the map instead of jumping on release.
    var onRegionChanging: ((MKCoordinateRegion) -> Void)?
    /// Fires when the user starts/ends a pan, pinch or rotation.
    var onUserInteractionBegan: (() -> Void)?
    var onUserInteractionEnded: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(self)
        coordinator.onRegionSettled = onRegionSettled
        coordinator.onRegionChanging = onRegionChanging
        coordinator.onUserInteractionBegan = onUserInteractionBegan
        coordinator.onUserInteractionEnded = onUserInteractionEnded
        return coordinator
    }

    func makeUIView(context: Context) -> MKMapView {
        // Create with a real frame (not .zero): on iOS 16, VectorKit's Metal
        // canvas initializes against the creation geometry and never recovers
        // from a zero frame, leaving a black map. Using the screen bounds gives
        // the renderer a valid canvas from the start.
        let mapView = MKMapView(frame: UIScreen.main.bounds)
        // Style is driven via mapView.mapType, NOT preferredConfiguration:
        // switching preferredConfiguration on iOS 16 corrupts VectorKit's
        // renderer ("Tracking renderables for inactive registry", SO 77818532)
        // and leaves a black map. mapType is soft-deprecated but works reliably
        // on iOS 16 and is what Geranium-style apps use.
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = false
        // Do NOT call setRegion here: at this point the view still has a zero
        // frame (it has not been laid out yet), and applying a region against
        // empty geometry can leave the map renderer in a broken black state.
        // The initial region is applied in updateUIView once bounds are valid.

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.mapTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        mapView.addGestureRecognizer(tap)

        // Long-press: waypoint insertion (mainland China) / expanded pin actions.
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.mapLongPressed(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.cancelsTouchesInView = false
        longPress.delaysTouchesBegan = false
        mapView.addGestureRecognizer(longPress)

        // MKMapView's internal recognizers (double-tap-to-zoom etc.) cancel touches by
        // default, which swallows the first tap on SwiftUI buttons overlaid on the map.
        // Disabling cancellation lets the button's touch sequence survive arbitration.
        Self.disableTouchCancellation(in: mapView)

        // Gate every recognizer (ours and MapKit's, on the map view itself) so
        // they only see touches that land inside the map's own view hierarchy.
        // SwiftUI buttons overlaid on the map live outside that hierarchy, so
        // their taps no longer enter the map's gesture arbitration. Recursing
        // into MapKit's internal subviews breaks its pan/zoom coordination, so
        // only the map view's own recognizers are gated.
        let gate = MapTouchGate()
        context.coordinator.touchGate = gate
        for recognizer in mapView.gestureRecognizers ?? [] {
            recognizer.delegate = gate
            // The double-tap-to-zoom recognizer is the one that swallows the
            // first tap on overlay buttons: it waits to see whether a second
            // tap follows. Disable it outright — two-finger pinch, the zoom
            // slider and the joystick cover zooming.
            if let tap = recognizer as? UITapGestureRecognizer,
               tap.numberOfTapsRequired == 2 {
                tap.isEnabled = false
            }
        }
        tap.delegate = gate
        longPress.delegate = gate

        // Observers that report "the user is driving the camera" without
        // competing with MapKit's own recognizers: they recognise alongside the
        // map's pan/pinch and never consume the gesture.
        let cameraObserver = CameraGestureObserver(
            onBegan: { context.coordinator.onUserInteractionBegan?() },
            onEnded: { context.coordinator.onUserInteractionEnded?() }
        )
        context.coordinator.cameraObserver = cameraObserver
        for recognizer in cameraObserver.makeRecognizers() {
            recognizer.delegate = cameraObserver
            mapView.addGestureRecognizer(recognizer)
        }

        onMapViewCreated(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // VectorKit adds internal recognizers lazily after first interaction;
        // re-apply so late arrivals also stop cancelling overlay button touches.
        Self.disableTouchCancellation(in: mapView)

        // Only touch the map type when the requested one changed; re-assigning
        // it on every update churns MapKit's VectorKit renderer and can blank
        // the map (iOS 16.x).
        if mapView.mapType != mapType {
            mapView.mapType = mapType
        }

        // Apply the initial region only once the view has a real frame.
        if !context.coordinator.didSetInitialRegion, mapView.bounds.size != .zero {
            context.coordinator.didSetInitialRegion = true
            mapView.setRegion(region, animated: false)
            context.coordinator.lastRegion = region
            // Seed the recorded camera immediately: `mapViewDidChangeVisibleRegion`
            // also covers this, but seeding here guarantees a valid value even if
            // the user switches language before the first delegate callback.
            context.coordinator.onRegionChanging?(mapView.region)
        }

        // Apply programmatic region changes only; never fight the user's pan.
        if let last = context.coordinator.lastRegion, Self.regionDiffers(last, region) {
            if context.coordinator.animateRegionToken != animateRegionToken {
                UIView.animate(withDuration: 0.35, delay: 0, options: .curveEaseInOut) {
                    mapView.setRegion(region, animated: false)
                }
            } else {
                mapView.setRegion(region, animated: false)
            }
            context.coordinator.lastRegion = region
        }
        context.coordinator.animateRegionToken = animateRegionToken

        // Rebuilding overlays is expensive (hundreds of points, add/remove
        // churn on the renderer), and updateUIView fires on every body change
        // (status updates, region settles...). Only rebuild when the route
        // data actually changed; otherwise taps feel laggy while the main
        // thread churns through polyline construction.
        let routeKey = Self.coordinatesKey(routeCoords)
        let alternativesKey = alternativeRouteCoords.map(Self.coordinatesKey)
        let drawnKey = Self.coordinatesKey(drawnPath)
        if routeKey != context.coordinator.routeKey
            || alternativesKey != context.coordinator.alternativesKey
            || drawnKey != context.coordinator.drawnKey {
            context.coordinator.routeKey = routeKey
            context.coordinator.alternativesKey = alternativesKey
            context.coordinator.drawnKey = drawnKey

            // Alternative route polylines (unselected options) — added first so
            // the selected route below renders on top (later overlays win).
            for overlay in context.coordinator.alternativeOverlays {
                mapView.removeOverlay(overlay)
            }
            context.coordinator.alternativeOverlays.removeAll()
            for coords in alternativeRouteCoords where coords.count > 1 {
                let polyline = MKPolyline(coordinates: coords, count: coords.count)
                context.coordinator.alternativeOverlays.append(polyline)
                mapView.addOverlay(polyline)
            }

            // Selected / presented route polyline.
            if routeCoords.count > 1 {
                if let overlay = context.coordinator.routeOverlay { mapView.removeOverlay(overlay) }
                let polyline = MKPolyline(coordinates: routeCoords, count: routeCoords.count)
                // Assign before addOverlay: MapKit may call rendererFor synchronously
                // from within addOverlay, and rendererFor dispatches on identity.
                context.coordinator.routeOverlay = polyline
                mapView.addOverlay(polyline)
            } else if let overlay = context.coordinator.routeOverlay {
                mapView.removeOverlay(overlay)
                context.coordinator.routeOverlay = nil
            }

            // Drawn path polyline (dashed).
            if drawnPath.count > 1 {
                if let overlay = context.coordinator.drawnOverlay { mapView.removeOverlay(overlay) }
                let polyline = MKPolyline(coordinates: drawnPath, count: drawnPath.count)
                context.coordinator.drawnOverlay = polyline
                mapView.addOverlay(polyline)
            } else if let overlay = context.coordinator.drawnOverlay {
                mapView.removeOverlay(overlay)
                context.coordinator.drawnOverlay = nil
            }
        }
    }

    private static func coordinatesKey(_ coords: [CLLocationCoordinate2D]) -> String {
        guard let first = coords.first, let last = coords.last else { return "\(coords.count)" }
        return "\(coords.count):\(first.latitude),\(first.longitude)-\(last.latitude),\(last.longitude)"
    }

    private static func disableTouchCancellation(in view: UIView) {
        view.gestureRecognizers?.forEach {
            $0.cancelsTouchesInView = false
            // MKMapView's double-tap-to-zoom recognizer delays touchesEnded
            // while it waits to see whether a second tap follows. Buttons
            // overlaid on the map (route run/delete, route choices) then need
            // several taps before SwiftUI sees a clean touch sequence.
            $0.delaysTouchesBegan = false
            $0.delaysTouchesEnded = false
        }
        view.subviews.forEach { disableTouchCancellation(in: $0) }
    }

    /// Lets map gesture recognizers see only touches that land inside the map's
    /// own view hierarchy. SwiftUI controls overlaid on the map live outside
    /// that hierarchy, so their taps never enter the map's gesture arbitration
    /// and never get swallowed by double-tap-to-zoom / pan / pinch.
    final class MapTouchGate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let mapView = gestureRecognizer.view else { return false }
            guard let view = touch.view else { return false }
            let inMap = view === mapView || view.isDescendant(of: mapView)
            return inMap
        }
    }

    private static func regionDiffers(_ lhs: MKCoordinateRegion, _ rhs: MKCoordinateRegion) -> Bool {
        lhs.center.latitude != rhs.center.latitude
            || lhs.center.longitude != rhs.center.longitude
            || lhs.span.latitudeDelta != rhs.span.latitudeDelta
            || lhs.span.longitudeDelta != rhs.span.longitudeDelta
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: LocusMapView
        var lastRegion: MKCoordinateRegion?
        var didSetInitialRegion = false
        var animateRegionToken = 0
        var routeOverlay: MKPolyline?
        var alternativeOverlays: [MKPolyline] = []
        var drawnOverlay: MKPolyline?
        var routeKey: String?
        var alternativesKey: [String]?
        var drawnKey: String?
        var touchGate: MapTouchGate?
        var onRegionSettled: (() -> Void)?
        var onRegionChanging: ((MKCoordinateRegion) -> Void)?
        var onUserInteractionBegan: (() -> Void)?
        var onUserInteractionEnded: (() -> Void)?
        var cameraObserver: CameraGestureObserver?

        init(_ parent: LocusMapView) {
            self.parent = parent
        }

        @objc func mapTapped(_ recognizer: UITapGestureRecognizer) {
            guard let mapView = recognizer.view as? MKMapView else { return }
            let coordinate = mapView.convert(recognizer.location(in: mapView), toCoordinateFrom: mapView)
            parent.onMapTap(coordinate)
        }

        @objc func mapLongPressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let mapView = recognizer.view as? MKMapView else { return }
            let coordinate = mapView.convert(recognizer.location(in: mapView), toCoordinateFrom: mapView)
            parent.onMapLongPress(coordinate)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            lastRegion = mapView.region
            // During the initial frame, MKMapView reports its default region
            // (e.g. the whole country view) before the app's initial region has
            // been applied; writing that back to the @Binding would clobber the
            // initial region and leave the map anywhere but where the app asked.
            // Defer callbacks until the initial region is applied.
            guard didSetInitialRegion else { return }
            parent.region = mapView.region
            onRegionSettled?()
        }

        /// Called continuously while the visible region changes — including
        /// mid-gesture, which `regionDidChangeAnimated` never does.
        ///
        /// The marker repositioning happens here, synchronously, because this
        /// callback runs inside MapKit's own layout pass: views moved now are
        /// drawn in the same frame as the map behind them. Routing it through
        /// SwiftUI state instead deferred the move by at least one runloop turn,
        /// which is what made markers trail the map.
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            guard didSetInitialRegion else { return }
            onRegionChanging?(mapView.region)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.lineCap = .round
                renderer.lineJoin = .round
                if polyline === routeOverlay {
                    let renderer = ArrowPolylineRenderer(polyline: polyline)
                    renderer.lineCap = .round
                    renderer.lineJoin = .round
                    renderer.strokeColor = UIColor(parent.routeColor)
                    renderer.lineWidth = parent.routeLineWidth
                    if parent.routeDashed {
                        renderer.lineDashPattern = [6, 4]
                    }
                    return renderer
                } else if alternativeOverlays.contains(where: { $0 === polyline }) {
                    renderer.strokeColor = UIColor(
                        Color(red: 0.39, green: 0.78, blue: 0.55)
                            .opacity(0.72)
                    )
                    renderer.lineWidth = 4
                } else if polyline === drawnOverlay {
                    renderer.strokeColor = UIColor(LocusTheme.accentSecondary)
                    renderer.lineWidth = 4
                    renderer.lineDashPattern = [6, 4]
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

/// Polyline renderer that draws white chevron arrowheads (">" shapes, no
/// tails) spaced along the route, over the colored stroke — the Gaode-map
/// style. Arrowheads are drawn in screen space (fixed size at any zoom).
private final class ArrowPolylineRenderer: MKPolylineRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let points = polyline.points()
        let count = polyline.pointCount
        guard count >= 2 else { return }

        // Compensate with the context's ACTUAL scale (a fixed screen size
        // divided by ctm, multiplied back by ctm during drawing, stays
        // constant at every zoom) — the zoomScale parameter does not track it.
        let scale = (context.ctm.a * context.ctm.a + context.ctm.b * context.ctm.b).squareRoot()
        guard scale.isFinite, scale > 0 else { return }

        context.saveGState()
        context.setLineWidth(lineWidth / scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if let color = strokeColor {
            context.setStrokeColor(color.cgColor)
        }
        context.move(to: point(for: points[0]))
        for i in 1..<count {
            context.addLine(to: point(for: points[i]))
        }
        context.strokePath()
        context.restoreGState()

        // Cumulative path length in drawing space (uniform scale, so angles and
        // ratios here match the rendered line). Arrows are placed by equal arc
        // length — never by a fixed spacing that can exceed the path length at
        // low zoom (that is exactly how arrows silently vanish).
        var cumulative: [CGFloat] = [0]
        cumulative.reserveCapacity(count)
        for i in 1..<count {
            let a = points[i - 1]
            let b = points[i]
            let dx = CGFloat(b.x - a.x)
            let dy = CGFloat(b.y - a.y)
            cumulative.append(cumulative[i - 1] + sqrt(dx * dx + dy * dy))
        }
        let total = cumulative[count - 1]
        guard total > 0 else { return }

        let screenSpacing: CGFloat = 80
        // Flat chevron that spans the stroke width (tips touch both line edges)
        // with a thin stroke — reads as a ">" arrowhead, not a fat triangle.
        let halfWidth = lineWidth / 2 / scale
        let fwd: CGFloat = 3 / scale
        let back: CGFloat = 3 / scale

        // Equal-arc placement, at least one arrow no matter how short the path.
        let arrowCount = max(1, Int(total / (screenSpacing / scale)))
        let arcStep = total / CGFloat(arrowCount)

        context.saveGState()
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(max(1, lineWidth * 0.2) / scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for slot in 0..<arrowCount {
            let target = arcStep * (CGFloat(slot) + 0.5)
            guard let idx = cumulative.firstIndex(where: { $0 >= target }), idx > 0 else {
                continue
            }
            let a = points[idx - 1]
            let b = points[idx]
            let span = cumulative[idx] - cumulative[idx - 1]
            let ratio = span > 0 ? (target - cumulative[idx - 1]) / span : 0
            let position = MKMapPoint(
                x: a.x + (b.x - a.x) * Double(ratio),
                y: a.y + (b.y - a.y) * Double(ratio)
            )
            let angle = atan2(CGFloat(b.y - a.y), CGFloat(b.x - a.x))
            let center = point(for: position)
            let ux = cos(angle)
            let uy = sin(angle)
            let nx = -uy
            let ny = ux
            let tip = CGPoint(
                x: center.x + ux * fwd,
                y: center.y + uy * fwd
            )
            let left = CGPoint(
                x: center.x - ux * back + nx * halfWidth,
                y: center.y - uy * back + ny * halfWidth
            )
            let right = CGPoint(
                x: center.x - ux * back - nx * halfWidth,
                y: center.y - uy * back - ny * halfWidth
            )
            context.move(to: left)
            context.addLine(to: tip)
            context.addLine(to: right)
            context.strokePath()
        }

        context.restoreGState()
    }
}

@MainActor
final class PlaceSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    var query: String = "" {
        didSet { completer.queryFragment = query }
    }

    var region: MKCoordinateRegion {
        get { completer.region }
        set { completer.region = newValue }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let items = completer.results
        Task { @MainActor in self.results = items }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}
