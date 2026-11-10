import SwiftUI
import PhotosUI
import MapKit
import CoreLocation
import UserNotifications

struct EditRequest: Identifiable {
    let id = UUID()
    var card: GymCard
}

struct ContentView: View {
    @ObservedObject private var store = Store.shared
    @State private var editing: EditRequest?
    @State private var scanning = false
    @State private var scanned: GymCard?
    @State private var photo: PhotosPickerItem?
    @State private var photoFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if store.card != nil {
                    CardHome(editing: $editing)
                } else {
                    welcome
                }
            }
            .navigationTitle("Gym Pass")
        }
        .sheet(item: $editing) { req in CardEditor(draft: req.card) }
        .sheet(isPresented: $scanning, onDismiss: {
            if let c = scanned { scanned = nil; editing = EditRequest(card: c) }
        }) {
            ScanSheet { value, kind in
                var c = store.card ?? GymCard()
                c.value = value
                c.kind = kind
                scanned = c
            }
        }
        .fullScreenCover(isPresented: $store.showBarcode) {
            if let c = store.card { BarcodeScreen(card: c) }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                let hit = data.flatMap { PhotoBarcode.detect(in: $0) }
                await MainActor.run {
                    photo = nil
                    if let hit {
                        var c = GymCard()
                        c.value = hit.0
                        c.kind = hit.1
                        editing = EditRequest(card: c)
                    } else {
                        photoFailed = true
                    }
                }
            }
        }
        .alert("No barcode found", isPresented: $photoFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try a sharper photo or screenshot where the whole barcode is visible, or type the number in.")
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.orange)
                    .padding(.top, 40)
                Text("Your gym barcode,\nright when you walk in.")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Add your membership barcode. When you get to the gym, your iPhone shows a notification. Tap it and the barcode opens full screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(spacing: 12) {
                    Button { scanning = true } label: {
                        Label("Scan it with the camera", systemImage: "camera.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose a photo or screenshot", systemImage: "photo").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button { editing = EditRequest(card: GymCard()) } label: {
                        Label("Type the number in", systemImage: "keyboard").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .tint(.orange)
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            .padding(.bottom, 40)
        }
    }
}

// MARK: Home (card saved)

struct CardHome: View {
    @Binding var editing: EditRequest?
    @ObservedObject private var store = Store.shared
    @ObservedObject private var loc = LocationService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var locating = false
    @State private var searching = false
    @State private var confirmDelete = false
    @State private var locateFailed = false
    @State private var notifAllowed = true

    var body: some View {
        if let card = store.card {
            List {
                Section {
                    Button { store.showBarcode = true } label: { CardView(card: card) }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("Tap the card to show it full screen.")
                }

                arrivalSection(card)

                Section {
                    Button { editing = EditRequest(card: card) } label: { Label("Edit card", systemImage: "pencil") }
                    Button { Notifier.requestPermission(); Notifier.arrived(force: true) } label: { Label("Send a test notification", systemImage: "bell.badge") }
                } footer: {
                    Text("Tip: say “Show my gym barcode in Gym Pass” to Siri, or set the Action button to the Gym Pass shortcut in Settings > Action Button > Shortcut.")
                }

                Section {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete card", systemImage: "trash") }
                }
            }
            .sheet(isPresented: $searching) { GymSearch(initialQuery: card.gymName) }
            .confirmationDialog("Delete your gym card?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { store.card = nil }
            }
            .alert("Couldn't find your location", isPresented: $locateFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Allow location for Gym Pass in Settings, or search for the gym instead.")
            }
            .task { await checkNotifications() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await checkNotifications() } }
            }
        }
    }

    @ViewBuilder
    private func arrivalSection(_ card: GymCard) -> some View {
        Section {
            Toggle("Notify me when I arrive", isOn: Binding(
                get: { card.notify },
                set: { on in
                    store.update { $0.notify = on }
                    if on { Notifier.requestPermission() }
                }
            ))

            if let lat = card.latitude, let lon = card.longitude {
                let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: card.radius * 4,
                                                                longitudinalMeters: card.radius * 4))) {
                    Marker(card.gymName.isEmpty ? "Gym" : card.gymName, systemImage: "dumbbell.fill", coordinate: center)
                        .tint(.orange)
                    MapCircle(center: center, radius: card.radius)
                        .foregroundStyle(.orange.opacity(0.18))
                        .stroke(.orange, lineWidth: 2)
                }
                .id("\(lat),\(lon),\(card.radius)")
                .frame(height: 170)
                .allowsHitTesting(false)
                .listRowInsets(EdgeInsets())

                Picker("Distance", selection: Binding(get: { card.radius }, set: { r in store.update { $0.radius = r } })) {
                    ForEach([100.0, 150, 250, 400], id: \.self) { r in
                        Text(Measurement(value: r, unit: UnitLength.meters)
                            .formatted(.measurement(width: .abbreviated, usage: .road))).tag(r)
                    }
                }
            }

            Button {
                locating = true
                LocationService.shared.currentLocation { location in
                    locating = false
                    guard let location else { locateFailed = true; return }
                    store.update {
                        $0.latitude = location.coordinate.latitude
                        $0.longitude = location.coordinate.longitude
                        $0.notify = true
                    }
                    Notifier.requestPermission()
                }
            } label: {
                HStack {
                    Label("I'm at the gym now, use this spot", systemImage: "location.fill")
                    if locating { Spacer(); ProgressView() }
                }
            }
            .disabled(locating)

            Button { searching = true } label: {
                Label(card.hasLocation ? "Change gym location" : "Search for the gym", systemImage: "magnifyingglass")
            }
        } header: {
            Text("Arrival alert")
        } footer: {
            arrivalFooter(card)
        }
    }

    @ViewBuilder
    private func arrivalFooter(_ card: GymCard) -> some View {
        if !card.hasLocation {
            Text("Set your gym's location so your iPhone can tell you when you get there.")
        } else if !card.notify {
            Text("Arrival alerts are off.")
        } else if loc.status != .authorizedAlways {
            VStack(alignment: .leading, spacing: 6) {
                Text("⚠️ Set Location to **Always** so this works while the app is closed: Settings > Apps > Gym Pass > Location > Always, and turn on Precise Location.")
                Button("Open Settings") { openSettings() }
            }
        } else if !notifAllowed {
            VStack(alignment: .leading, spacing: 6) {
                Text("⚠️ Notifications are off for Gym Pass.")
                Button("Open Settings") { openSettings() }
            }
        } else if let err = loc.lastError {
            Text("⚠️ iOS couldn't watch this location: \(err)")
        } else {
            Text("✅ All set. You'll get a notification when you arrive, at most once every 2 hours. Tap it to open your barcode.")
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private func checkNotifications() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { notifAllowed = s.authorizationStatus == .authorized || s.authorizationStatus == .notDetermined }
    }
}

// MARK: The card

struct CardView: View {
    let card: GymCard

    var body: some View {
        let bg = Color(hex: card.colorHex)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.gymName.isEmpty ? "My Gym" : card.gymName)
                        .font(.title3.bold())
                    if !card.memberName.isEmpty {
                        Text(card.memberName).font(.subheadline).opacity(0.85)
                    }
                }
                Spacer()
                Image(systemName: "dumbbell.fill").font(.title2).opacity(0.85)
            }
            .foregroundStyle(bg.readableText)

            VStack(spacing: 6) {
                BarcodeImage(value: card.value, kind: card.kind)
                    .frame(maxHeight: card.kind.isSquare ? 170 : 110)
                Text(card.value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(18)
        .background(
            LinearGradient(colors: [bg, bg.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

struct BarcodeImage: View {
    let value: String
    let kind: BarcodeKind

    var body: some View {
        if let img = Barcode.image(value, kind: kind) {
            Image(uiImage: img)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            Text(Barcode.problem(value, kind: kind) ?? "Can't make this barcode.")
                .font(.footnote)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }
}

/// Full screen, max brightness, screen stays on. Tap to close.
struct BarcodeScreen: View {
    let card: GymCard
    @Environment(\.dismiss) private var dismiss
    @State private var oldBrightness: CGFloat = 0.5

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 24) {
                Text(card.gymName.isEmpty ? "My Gym" : card.gymName)
                    .font(.title.bold())
                    .foregroundStyle(.black)
                if !card.memberName.isEmpty {
                    Text(card.memberName).font(.headline).foregroundStyle(.gray)
                }
                BarcodeImage(value: card.value, kind: card.kind)
                    .frame(maxWidth: card.kind.isSquare ? 320 : .infinity)
                    .padding(.horizontal, 20)
                Text(card.value)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.black)
                    .textSelection(.enabled)
                Text("Tap anywhere to close")
                    .font(.footnote)
                    .foregroundStyle(.gray)
                    .padding(.top, 20)
            }
            .padding(.vertical, 40)
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .statusBarHidden()
        .onAppear {
            oldBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIScreen.main.brightness = oldBrightness
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: Editor

struct CardEditor: View {
    @State var draft: GymCard
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var photo: PhotosPickerItem?
    @State private var photoFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section { CardView(card: draft).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }

                Section {
                    TextField("Gym name", text: $draft.gymName)
                        .textInputAutocapitalization(.words)
                    TextField("Your name (optional)", text: $draft.memberName)
                        .textInputAutocapitalization(.words)
                    ColorPicker("Card color", selection: Binding(
                        get: { Color(hex: draft.colorHex) },
                        set: { draft.colorHex = $0.hex }
                    ), supportsOpacity: false)
                } header: { Text("Card") }

                Section {
                    TextField("Barcode number", text: $draft.value)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Type", selection: $draft.kind) {
                        ForEach(BarcodeKind.allCases) { Text($0.name).tag($0) }
                    }
                    Button { scanning = true } label: { Label("Scan with camera", systemImage: "camera.viewfinder") }
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Read from a photo or screenshot", systemImage: "photo")
                    }
                } header: {
                    Text("Barcode")
                } footer: {
                    if let p = Barcode.problem(draft.value, kind: draft.kind) {
                        Text(p).foregroundStyle(.red)
                    } else {
                        Text("Scanning sets the right type. If you type it in, most gym cards are Code 128 or Code 39.")
                    }
                }
            }
            .navigationTitle("Gym card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        // keep the location settings that are already saved
                        if let old = Store.shared.card {
                            draft.latitude = draft.latitude ?? old.latitude
                            draft.longitude = draft.longitude ?? old.longitude
                        }
                        Store.shared.card = draft
                        dismiss()
                    }
                    .bold()
                    .disabled(Barcode.problem(draft.value, kind: draft.kind) != nil)
                }
            }
            .sheet(isPresented: $scanning) {
                ScanSheet { value, kind in draft.value = value; draft.kind = kind }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    let hit = data.flatMap { PhotoBarcode.detect(in: $0) }
                    await MainActor.run {
                        photo = nil
                        if let hit { draft.value = hit.0; draft.kind = hit.1 } else { photoFailed = true }
                    }
                }
            }
            .alert("No barcode found", isPresented: $photoFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try a sharper photo where the whole barcode is visible.")
            }
        }
    }
}

// MARK: Gym search

struct GymSearch: View {
    let initialQuery: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                if busy { HStack { Spacer(); ProgressView(); Spacer() } }
                ForEach(results, id: \.self) { item in
                    Button {
                        let c = item.placemark.coordinate
                        Store.shared.update {
                            $0.latitude = c.latitude
                            $0.longitude = c.longitude
                            $0.notify = true
                            if $0.gymName.isEmpty { $0.gymName = item.name ?? "" }
                        }
                        Notifier.requestPermission()
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Place").foregroundStyle(.primary)
                            Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !busy && results.isEmpty && !query.isEmpty {
                    Text("Search for your gym's name or address, then pick it.").foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Gym name or address")
            .onSubmit(of: .search) { search() }
            .navigationTitle("Find your gym")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                if query.isEmpty, !initialQuery.isEmpty { query = initialQuery; search() }
            }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        busy = true
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        if let here = LocationService.shared.manager.location {
            req.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        MKLocalSearch(request: req).start { response, _ in
            DispatchQueue.main.async {
                busy = false
                results = response?.mapItems ?? []
            }
        }
    }
}
