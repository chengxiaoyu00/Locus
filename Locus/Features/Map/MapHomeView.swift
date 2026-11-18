import MapKit
import SwiftUI

struct MapHomeView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore

    @StateObject private var search = PlaceSearch()
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @FocusState private var searchFocused: Bool
    @State private var routeStart: CLLocationCoordinate2D?
    @State private var routeEnd: CLLocationCoordinate2D?
    @State private var routeCoords: [CLLocationCoordinate2D] = []
    @State private var isRouting = false
    @State private var showRouteSheet = false
    @State private var showGPXImporter = false
    @State private var drawnPath: [CLLocationCoordinate2D] = []
    @State private var drawMode = false
    @State private var pinSelected = false
    @State private var isDraggingPin = false
    @State private var suppressNextMapTap = false
    /// Set when the pin comes from search / a named place so starring keeps the title.
    @State private var pinPlaceName: String?

    private var mapStyle: MapStyle {
        switch session.mapStyleIndex {
        case 1: return .hybrid(elevation: .realistic)
        case 2: return .imagery(elevation: .realistic)
        default: return .standard(elevation: .realistic)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Keep Map inside the safe layout bounds so MapProxy.convert matches
            // finger position. Ignoring the safe area makes the tiles full-bleed but
            // shifts convert() upward by ~status-bar height.
            MapReader { proxy in
                Map(position: $position) {
                    UserAnnotation()

                    if let pin = session.pin {
                        Annotation("", coordinate: pin, anchor: .bottom) {
                            MapDropPin(
                                selected: pinSelected,
                                isDragging: isDraggingPin,
                                onSelect: {
                                    search.dismissResults()
                                    searchFocused = false
                                    suppressNextMapTap = true
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                        pinSelected.toggle()
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        suppressNextMapTap = false
                                    }
                                },
                                onRemove: {
                                    suppressNextMapTap = true
                                    withAnimation {
                                        session.pin = nil
                                        pinSelected = false
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        suppressNextMapTap = false
                                    }
                                },
                                onDragBegan: {
                                    search.dismissResults()
                                    searchFocused = false
                                    suppressNextMapTap = true
                                    pinSelected = false
                                    isDraggingPin = true
                                },
                                onDragMoved: { globalPoint in
                                    if let coord = proxy.convert(globalPoint, from: .global) {
                                        session.pin = coord
                                    }
                                },
                                onDragEnded: {
                                    isDraggingPin = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                        suppressNextMapTap = false
                                    }
                                }
                            )
                        }
                    }
                    if let sim = session.simulated {
                        Annotation("Spoof", coordinate: sim) {
                            ZStack {
                                Circle().fill(LocusTheme.accent.opacity(0.25)).frame(width: 44, height: 44)
                                Circle().fill(LocusTheme.accent).frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                            }
                        }
                    }
                    if routeCoords.count > 1 {
                        MapPolyline(coordinates: routeCoords)
                            .stroke(LocusTheme.accent, lineWidth: 5)
                    }
                    if drawnPath.count > 1 {
                        MapPolyline(coordinates: drawnPath)
                            .stroke(LocusTheme.accentSecondary, style: StrokeStyle(lineWidth: 4, dash: [6, 4]))
                    }
                }
                .mapStyle(mapStyle)
                .mapControlVisibility(.hidden)
                .onTapGesture { point in
                    guard !suppressNextMapTap, !isDraggingPin else { return }
                    searchFocused = false
                    search.dismissResults()
                    pinSelected = false
                    placePin(at: point, proxy: proxy)
                }
            }
            .background(Color.black.ignoresSafeArea())

            topChrome
        }
        .onAppear {
            session.startLocationUpdates()
        }
        .onDisappear { search.dismissResults() }
        .onChange(of: session.pin?.latitude) { _, newValue in
            if newValue == nil { pinSelected = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusImportGPX)) { note in
            guard let url = note.object as? URL else { return }
            importGPX(url)
        }
        .fileImporter(isPresented: $showGPXImporter, allowedContentTypes: [.xml, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                importGPX(url)
            }
        }
        .sheet(isPresented: $showRouteSheet) {
            RoutePlannerSheet(
                start: $routeStart,
                end: $routeEnd,
                isRouting: $isRouting,
                onBuild: buildRoadRoute,
                onPlay: playRoute,
                onImportGPX: { showGPXImporter = true },
                onExportGPX: exportGPX,
                onUseDrawn: {
                    routeCoords = RouteBuilder.sample(coordinates: drawnPath, every: 10)
                    drawnPath.removeAll()
                    drawMode = false
                }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func placePin(at point: CGPoint, proxy: MapProxy) {
        guard let coord = proxy.convert(point, from: .local) else { return }
        if drawMode {
            drawnPath.append(coord)
        } else {
            session.pin = coord
            pinPlaceName = nil
            pinSelected = false
        }
    }

    private var topChrome: some View {
        VStack(spacing: 10) {
            StatusBarView()

            searchBar

            if search.showsResults { searchResults }

            HStack(alignment: .center, spacing: 10) {
                mapChromeButtons
                Spacer(minLength: 0)
                locateButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .safeAreaPadding(.top, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search places", text: Binding(get: { search.text }, set: { search.edit($0) }))
                .accessibilityIdentifier("placeSearchField")
                .textInputAutocapitalization(.words)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { submitAddress(search.text) }
            PasteButton(payloadType: String.self) { strings in
                guard let address = strings.first else { return }
                submitAddress(address)
            }
            .labelStyle(.titleOnly)
            .controlSize(.small)
            .tint(LocusTheme.accent)
            .accessibilityLabel("Paste address")
            .accessibilityIdentifier("pasteAddress")
            if searchFocused || !search.text.isEmpty {
                Button {
                    search.clear()
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear and dismiss keyboard")
            }
            if searchFocused {
                Button("Done") {
                    searchFocused = false
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(LocusTheme.accent)
            }
        }
        .padding(12)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch search.results {
            case .suggestions(let items):
                ForEach(items.prefix(5), id: \.self) { item in
                    searchRow(title: item.title, subtitle: item.subtitle) {
                        search.select(item, onSelection: placeSearchPin)
                    }
                }
            case .matches(let places):
                ForEach(places.prefix(5), id: \.self) { place in
                    searchRow(title: place.name ?? search.text, subtitle: place.searchAddress) {
                        placeSearchPin(place, search.text)
                    }
                }
            case .loading:
                ProgressView("Searching…").padding(12)
            case .emptyQuery:
                Text("Enter an address to search.").padding(12)
            case .noMatches:
                Text("No places found. Try adding a city or street number.").padding(12)
            case .unavailable:
                Text("Search is unavailable. Please try again.").padding(12)
            }
        }
        .font(.subheadline)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func searchRow(title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty, subtitle != title {
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var mapChromeButtons: some View {
        HStack(spacing: 4) {
            chromeIconButton("square.3.layers.3d") {
                session.mapStyleIndex = (session.mapStyleIndex + 1) % 3
            }
            chromeIconButton("point.topleft.down.to.point.bottomright.curvepath") {
                showRouteSheet = true
            }
            chromeIconButton(drawMode ? "pencil.tip.crop.circle.badge.minus" : "pencil.tip.crop.circle") {
                drawMode.toggle()
                if !drawMode { drawnPath.removeAll() }
            }
            .foregroundStyle(drawMode ? LocusTheme.accentSecondary : .primary)

            if session.pin != nil {
                chromeIconButton("star.circle") {
                    if let pin = session.pin {
                        let name = session.suggestedFavoriteName(for: pin, fallback: pinPlaceName)
                        session.addFavorite(name: name, coordinate: pin)
                    }
                }
            }
        }
        .padding(6)
        .locusGlass(.clear, in: Capsule())
        .contentShape(Capsule())
    }

    private var locateButton: some View {
        Button {
            searchFocused = false
            goToCurrentLocation()
        } label: {
            Image(systemName: "location.fill")
                .font(.body.weight(.semibold))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .locusGlass(.interactive, in: Circle())
        .foregroundStyle(.primary)
        .contentShape(Circle())
        .accessibilityLabel("Current location")
    }

    /// Centers on the spoofed fix while spoofing, otherwise the real GPS —
    /// never the leftover teleport pin (`.automatic` would frame that marker).
    private func goToCurrentLocation() {
        search.dismissResults()
        let meters: CLLocationDistance = 900
        withAnimation(.easeInOut(duration: 0.35)) {
            if session.isSpoofing, let sim = session.simulated {
                position = .region(MKCoordinateRegion(
                    center: sim,
                    latitudinalMeters: meters,
                    longitudinalMeters: meters
                ))
            } else if let real = session.realCoordinate {
                position = .region(MKCoordinateRegion(
                    center: real,
                    latitudinalMeters: meters,
                    longitudinalMeters: meters
                ))
            } else {
                position = .userLocation(
                    followsHeading: false,
                    fallback: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                        latitudinalMeters: 2000,
                        longitudinalMeters: 2000
                    ))
                )
            }
        }
    }

    private func chromeIconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func submitAddress(_ input: String) {
        searchFocused = false
        search.submit(input, onSelection: placeSearchPin)
    }

    private func placeSearchPin(_ item: MKMapItem, _ fallbackTitle: String) {
        let coord = item.searchCoordinate
        let title = item.name ?? fallbackTitle
        search.clear()
        searchFocused = false
        pinSelected = false
        session.pin = coord
        pinPlaceName = title
        position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: 1200, longitudinalMeters: 1200))
        session.addFavorite(name: title, coordinate: coord)
        session.pushNamedRecent(name: title, coordinate: coord)
    }

    private func buildRoadRoute() {
        guard let start = routeStart ?? session.simulated ?? session.pin,
              let end = routeEnd else {
            session.lastError = "Set a route start and end."
            return
        }
        isRouting = true
        Task {
            do {
                let coords = try await RouteBuilder.roadRoute(from: start, to: end, mode: session.travelMode)
                await MainActor.run {
                    routeCoords = coords
                    isRouting = false
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
        let path = routeCoords.isEmpty ? drawnPath : routeCoords
        guard path.count >= 2 else {
            session.lastError = "Build or draw a route first."
            return
        }
        showRouteSheet = false
        session.followRoute(path, pairing: pairing)
    }

    private func importGPX(_ url: URL) {
        do {
            let coords = try GPXCodec.parse(url)
            routeCoords = RouteBuilder.sample(coordinates: coords, every: 10)
            if let first = coords.first {
                session.pin = first
                position = .region(MKCoordinateRegion(center: first, latitudinalMeters: 2000, longitudinalMeters: 2000))
            }
        } catch {
            session.lastError = error.localizedDescription
        }
    }

    private func exportGPX() {
        let path = routeCoords.isEmpty ? drawnPath : routeCoords
        guard !path.isEmpty else {
            session.lastError = "Nothing to export."
            return
        }
        let gpx = GPXCodec.export(path)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Locus-Route.gpx")
        do {
            try gpx.data(using: .utf8)?.write(to: url)
            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.keyWindow?.rootViewController {
                root.present(av, animated: true)
            }
        } catch {
            session.lastError = error.localizedDescription
        }
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first { $0.isKeyWindow } }
}

private extension MKMapItem {
    var searchAddress: String? {
        if #available(iOS 26.0, *) { return address?.fullAddress }
        return placemark.title
    }

    var searchCoordinate: CLLocationCoordinate2D {
        if #available(iOS 26.0, *) { return location.coordinate }
        return placemark.coordinate
    }
}

@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    enum Results {
        case suggestions([MKLocalSearchCompletion])
        case loading
        case matches([MKMapItem])
        case emptyQuery, noMatches, unavailable
    }

    @Published private(set) var text = ""
    @Published private(set) var results: Results = .suggestions([])
    private var completer: MKLocalSearchCompleter?
    private var lookup: MKLocalSearch?

    var showsResults: Bool {
        if case .suggestions(let items) = results { return !items.isEmpty }
        return true
    }

    func edit(_ input: String) {
        dismissResults()
        text = input
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let completer = MKLocalSearchCompleter()
        self.completer = completer
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.queryFragment = input
    }

    func submit(_ input: String, onSelection: @escaping (MKMapItem, String) -> Void) {
        dismissResults()
        text = input.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else {
            results = .emptyQuery
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        resolve(request, title: text, chooseFirst: false, onSelection: onSelection)
    }

    func select(_ completion: MKLocalSearchCompletion, onSelection: @escaping (MKMapItem, String) -> Void) {
        dismissResults()
        resolve(.init(completion: completion), title: completion.title, chooseFirst: true, onSelection: onSelection)
    }

    func dismissResults() {
        completer?.delegate = nil
        completer?.cancel()
        completer = nil
        let previous = lookup
        lookup = nil
        previous?.cancel()
        results = .suggestions([])
    }

    func clear() {
        dismissResults()
        text = ""
    }

    private func resolve(_ request: MKLocalSearch.Request, title: String, chooseFirst: Bool,
                         onSelection: @escaping (MKMapItem, String) -> Void) {
        let search = MKLocalSearch(request: request)
        lookup = search
        results = .loading
        search.start { [weak self, weak search] response, error in
            guard let self, let search, self.lookup === search else { return }
            self.lookup = nil
            if let error {
                self.results = (error as? MKError)?.code == .placemarkNotFound ? .noMatches : .unavailable
                return
            }
            let items = response?.mapItems ?? []
            guard let first = items.first else {
                self.results = .noMatches
                return
            }
            if chooseFirst || items.count == 1 {
                self.results = .suggestions([])
                onSelection(first, title)
            } else {
                self.results = .matches(items)
            }
        }
    }

    nonisolated func completerDidUpdateResults(_ source: MKLocalSearchCompleter) {
        let id = ObjectIdentifier(source)
        Task { @MainActor in
            guard let current = self.completer, ObjectIdentifier(current) == id else { return }
            self.results = .suggestions(current.results)
        }
    }

    nonisolated func completer(_ source: MKLocalSearchCompleter, didFailWithError error: Error) {
        let id = ObjectIdentifier(source)
        Task { @MainActor in
            guard let current = self.completer, ObjectIdentifier(current) == id else { return }
            self.results = .suggestions([])
        }
    }
}
