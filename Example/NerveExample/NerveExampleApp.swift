import SwiftUI

#if DEBUG
import Nerve
#endif

@main
struct NerveExampleApp: App {
    init() {
        #if DEBUG
        Nerve.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    print("[nerve] Deeplink received: \(url)")
                    DeeplinkState.shared.lastURL = url.absoluteString
                }
        }
    }
}

/// Tracks deeplink state for testing
class DeeplinkState: ObservableObject {
    static let shared = DeeplinkState()
    @Published var lastURL: String = ""
}

// MARK: - Main Tab View

struct ContentView: View {
    var body: some View {
        TabView {
            HomeTab()
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .accessibilityIdentifier("tab-home")

            OrdersTab()
                .tabItem {
                    Label("Orders", systemImage: "bag")
                }
                .accessibilityIdentifier("tab-orders")

            SettingsTab()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .accessibilityIdentifier("tab-settings")

            TestsTab()
                .tabItem {
                    Label("Tests", systemImage: "flask")
                }
                .accessibilityIdentifier("tab-tests")
        }
    }
}

// MARK: - Home Tab

struct HomeTab: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Featured") {
                    NavigationLink("Product A", destination: ProductDetailView(name: "Product A", price: 29.99))
                        .accessibilityIdentifier("product-a")
                    NavigationLink("Product B", destination: ProductDetailView(name: "Product B", price: 49.99))
                        .accessibilityIdentifier("product-b")
                    NavigationLink("Product C", destination: ProductDetailView(name: "Product C", price: 99.99))
                        .accessibilityIdentifier("product-c")
                }

                Section("Actions") {
                    NavigationLink("Login", destination: LoginView())
                        .accessibilityIdentifier("login-link")
                }
            }
            .navigationTitle("Home")
        }
    }
}

// MARK: - Product Detail

struct ProductDetailView: View {
    let name: String
    let price: Double
    @State private var quantity = 1
    @State private var addedToCart = false

    var body: some View {
        VStack(spacing: 20) {
            Text(name)
                .font(.largeTitle)
                .accessibilityIdentifier("product-name")

            Text("$\(price, specifier: "%.2f")")
                .font(.title)
                .accessibilityIdentifier("product-price")

            Stepper("Quantity: \(quantity)", value: $quantity, in: 1...10)
                .accessibilityIdentifier("quantity-stepper")

            Button(addedToCart ? "Added to Cart" : "Add to Cart") {
                print("[nerve] Adding \(name) to cart, qty=\(quantity)")
                addedToCart = true
                print("[nerve] \(name) added to cart successfully")
            }
            .buttonStyle(.borderedProminent)
            .disabled(addedToCart)
            .accessibilityIdentifier("add-to-cart-btn")

            if addedToCart {
                Label("Added to cart!", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .accessibilityIdentifier("cart-confirmation")
            }

            Spacer()
        }
        .padding()
        .navigationTitle(name)
    }
}

// MARK: - Login View

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var loginResult: String?
    @State private var showError = false

    var body: some View {
        Form {
            Section("Credentials") {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .accessibilityIdentifier("email-field")

                SecureField("Password", text: $password)
                    .accessibilityIdentifier("password-field")
            }

            Section {
                Button(isLoading ? "Signing in..." : "Sign In") {
                    login()
                }
                .disabled(email.isEmpty || password.isEmpty || isLoading)
                .accessibilityIdentifier("login-btn")
            }

            if let result = loginResult {
                Section("Result") {
                    Text(result)
                        .accessibilityIdentifier("login-result")
                }
            }
        }
        .navigationTitle("Login")
        .alert("Login Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginResult ?? "Unknown error")
        }
    }

    private func login() {
        print("[nerve] Login attempt: email=\(email)")
        isLoading = true
        loginResult = nil

        // Simulate network delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            isLoading = false
            if email.contains("@") && password.count >= 4 {
                loginResult = "Welcome, \(email)!"
                print("[nerve] Login success: \(email)")
            } else {
                loginResult = "Invalid credentials"
                showError = true
                print("[nerve] Login failed: invalid credentials")
            }
        }
    }
}

// MARK: - Orders Tab

struct OrdersTab: View {
    @StateObject private var viewModel = OrdersViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView("Loading orders...")
                        .accessibilityIdentifier("orders-loading")
                } else if viewModel.orders.isEmpty {
                    VStack {
                        Text("No orders yet")
                            .accessibilityIdentifier("no-orders")
                        Button("Place Sample Order") {
                            viewModel.placeSampleOrder()
                        }
                        .accessibilityIdentifier("place-sample-order")
                    }
                } else {
                    List(viewModel.orders) { order in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Order #\(order.id)")
                                    .font(.headline)
                                Text(order.item)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(order.status)
                                .font(.caption)
                                .padding(4)
                                .background(order.status == "Delivered" ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                                .cornerRadius(4)
                        }
                        .accessibilityIdentifier("order-\(order.id)")
                    }
                }
            }
            .navigationTitle("Orders")
            .toolbar {
                Button("Refresh") {
                    viewModel.refresh()
                }
                .accessibilityIdentifier("refresh-btn")
            }
        }
    }
}

class OrdersViewModel: ObservableObject {
    struct Order: Identifiable {
        let id: String
        let item: String
        let status: String
    }

    @Published var orders: [Order] = []
    @Published var isLoading = false

    func refresh() {
        print("[nerve] Refreshing orders...")
        isLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isLoading = false
            print("[nerve] Orders loaded: \(self.orders.count) orders")
        }
    }

    func placeSampleOrder() {
        print("[nerve] Placing sample order...")
        isLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let orderId = String(Int.random(in: 1000...9999))
            let order = Order(id: orderId, item: "Product A", status: "Processing")
            self.orders.append(order)
            self.isLoading = false
            print("[nerve] Order placed: #\(orderId)")
        }
    }
}

// MARK: - Settings Tab

struct SettingsTab: View {
    @AppStorage("darkMode") private var darkMode = false
    @AppStorage("notifications") private var notifications = true
    @AppStorage("username") private var username = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Username", text: $username)
                        .accessibilityIdentifier("username-field")
                }

                Section("Preferences") {
                    Toggle("Dark Mode", isOn: $darkMode)
                        .accessibilityIdentifier("dark-mode-toggle")

                    Toggle("Notifications", isOn: $notifications)
                        .accessibilityIdentifier("notifications-toggle")
                }

                Section("Info") {
                    NavigationLink("About") {
                        AboutView()
                    }
                    .accessibilityIdentifier("about-link")
                }

                Section {
                    Button("Reset All Settings", role: .destructive) {
                        print("[nerve] Resetting settings")
                        darkMode = false
                        notifications = true
                        username = ""
                        print("[nerve] Settings reset complete")
                    }
                    .accessibilityIdentifier("reset-btn")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("NerveExample")
                .font(.largeTitle)
                .accessibilityIdentifier("about-title")

            Text("Version 1.0.0")
                .foregroundColor(.secondary)
                .accessibilityIdentifier("about-version")

            Text("An example app for testing the Nerve framework.")
                .multilineTextAlignment(.center)
                .padding()

            Spacer()
        }
        .navigationTitle("About")
    }
}

// MARK: - Tests Tab (exercises all 17 Nerve capabilities)

struct TestsTab: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Interaction Tests") {
                    NavigationLink("Alerts & Sheets", destination: AlertSheetTestView())
                        .accessibilityIdentifier("test-alerts")
                    NavigationLink("Long List (Lazy)", destination: LazyListTestView())
                        .accessibilityIdentifier("test-lazy-list")
                    NavigationLink("Custom Actions", destination: CustomActionsTestView())
                        .accessibilityIdentifier("test-custom-actions")
                    NavigationLink("Overlays", destination: OverlayTestView())
                        .accessibilityIdentifier("test-overlays")
                    NavigationLink("Long Press", destination: LongPressTestView())
                        .accessibilityIdentifier("test-long-press")
                }

                Section("Gesture Tests") {
                    NavigationLink("Double Tap", destination: DoubleTapTestView())
                        .accessibilityIdentifier("test-double-tap")
                    NavigationLink("Drag & Drop", destination: DragDropTestView())
                        .accessibilityIdentifier("test-drag-drop")
                    NavigationLink("Pinch Zoom", destination: PinchTestView())
                        .accessibilityIdentifier("test-pinch")
                    NavigationLink("Context Menu", destination: ContextMenuTestView())
                        .accessibilityIdentifier("test-context-menu")
                }

                Section("Network Tests") {
                    NavigationLink("Network Request", destination: NetworkTestView())
                        .accessibilityIdentifier("test-network")
                }

                Section("Accessibility Tests") {
                    NavigationLink("Disabled Elements", destination: DisabledTestView())
                        .accessibilityIdentifier("test-disabled")
                    NavigationLink("VoiceOver Labels", destination: VoiceOverTestView())
                        .accessibilityIdentifier("test-voiceover")
                    NavigationLink("Auto-Tag Test", destination: AutoTagTestView())
                        .accessibilityIdentifier("test-autotag")
                }

                // Bottom padding so last items can scroll above the tab bar
                Section {} footer: { Spacer().frame(height: 60) }
            }
            .navigationTitle("Tests")
        }
    }
}

// MARK: - #3: Alert & Sheet Test

struct AlertSheetTestView: View {
    @State private var showAlert = false
    @State private var showSheet = false
    @State private var alertResult = ""

    var body: some View {
        VStack(spacing: 20) {
            Button("Show Alert") {
                showAlert = true
            }
            .accessibilityIdentifier("show-alert-btn")

            Button("Show Sheet") {
                showSheet = true
            }
            .accessibilityIdentifier("show-sheet-btn")

            if !alertResult.isEmpty {
                Text(alertResult)
                    .accessibilityIdentifier("alert-result")
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Alerts & Sheets")
        .alert("Confirm Action", isPresented: $showAlert) {
            Button("Cancel", role: .cancel) {
                alertResult = "Cancelled"
                print("[nerve] Alert: cancelled")
            }
            Button("Confirm") {
                alertResult = "Confirmed"
                print("[nerve] Alert: confirmed")
            }
        } message: {
            Text("Do you want to proceed?")
        }
        .sheet(isPresented: $showSheet) {
            SheetContentView()
        }
    }
}

struct SheetContentView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Sheet Content")
                    .font(.title)
                    .accessibilityIdentifier("sheet-title")

                Button("Save") {
                    print("[nerve] Sheet: saved")
                    dismiss()
                }
                .accessibilityIdentifier("sheet-save-btn")

                Button("Close") {
                    dismiss()
                }
                .accessibilityIdentifier("sheet-close-btn")
            }
            .navigationTitle("Sheet")
        }
    }
}

// MARK: - #9: Lazy List Test (scroll-to-find)

struct LazyListTestView: View {
    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(0..<100) { i in
                    Text("Item \(i)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityIdentifier("lazy-item-\(i)")
                }
            }
        }
        .navigationTitle("Lazy List")
    }
}

// MARK: - #15: Custom Actions Test

struct CustomActionsTestView: View {
    @State private var actionResult = "No action performed"
    @State private var items = ["Apple", "Banana", "Cherry", "Date", "Elderberry"]

    var body: some View {
        VStack {
            Text(actionResult)
                .accessibilityIdentifier("action-result")
                .padding()

            List {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .accessibilityIdentifier("action-item-\(item.lowercased())")
                        .accessibilityAction(named: "Favorite") {
                            actionResult = "Favorited \(item)"
                            print("[nerve] Custom action: favorited \(item)")
                        }
                        .accessibilityAction(named: "Share") {
                            actionResult = "Shared \(item)"
                            print("[nerve] Custom action: shared \(item)")
                        }
                }
                .onDelete { indexSet in
                    let deleted = indexSet.map { items[$0] }
                    items.remove(atOffsets: indexSet)
                    actionResult = "Deleted \(deleted.joined(separator: ", "))"
                    print("[nerve] Deleted: \(deleted)")
                }
            }
        }
        .navigationTitle("Custom Actions")
    }
}

// MARK: - #6: Overlay Test (5-point hit test)

struct OverlayTestView: View {
    @State private var tapped = false
    @State private var overlayVisible = true

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                Button("Hidden Behind Overlay") {
                    tapped = true
                    print("[nerve] Tapped hidden button")
                }
                .accessibilityIdentifier("hidden-btn")

                Button("Toggle Overlay") {
                    overlayVisible.toggle()
                }
                .accessibilityIdentifier("toggle-overlay-btn")

                Text(tapped ? "Button was tapped!" : "Button not tapped")
                    .accessibilityIdentifier("overlay-result")

                Spacer()
            }
            .padding(.top, 40)

            if overlayVisible {
                VStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.3))
                        .frame(height: 100)
                        .accessibilityIdentifier("overlay-cover")
                    Spacer()
                }
            }
        }
        .navigationTitle("Overlays")
    }
}

// MARK: - #8: Long Press Test

struct LongPressTestView: View {
    @State private var longPressResult = "Long press a button"
    @State private var showContextMenu = false

    var body: some View {
        VStack(spacing: 20) {
            Text(longPressResult)
                .accessibilityIdentifier("longpress-result")

            Text("Long Press Me")
                .font(.headline)
                .padding()
                .background(Color.blue.opacity(0.15))
                .cornerRadius(10)
                .accessibilityIdentifier("longpress-btn")
                .onTapGesture {
                    longPressResult = "Tapped (not long-pressed)"
                    print("[nerve] longpress-btn: regular TAP fired")
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    longPressResult = "Long press detected!"
                    print("[nerve] longpress-btn: LONG PRESS detected (0.5s)")
                }

            Text("Context Menu Item")
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
                .accessibilityIdentifier("context-menu-target")
                .contextMenu {
                    Button("Copy") {
                        longPressResult = "Copied"
                        print("[nerve] Context menu: copy")
                    }
                    Button("Share") {
                        longPressResult = "Shared"
                        print("[nerve] Context menu: share")
                    }
                    Button("Delete", role: .destructive) {
                        longPressResult = "Deleted"
                        print("[nerve] Context menu: delete")
                    }
                }

            Spacer()
        }
        .padding()
        .navigationTitle("Long Press")
    }
}

// MARK: - Disabled Elements Test

struct DisabledTestView: View {
    var body: some View {
        VStack(spacing: 20) {
            Button("Enabled Button") {
                print("[nerve] Enabled button tapped")
            }
            .accessibilityIdentifier("enabled-btn")

            Button("Disabled Button") {
                print("[nerve] This should never fire")
            }
            .disabled(true)
            .accessibilityIdentifier("disabled-btn")

            TextField("Disabled Field", text: .constant("Can't edit"))
                .disabled(true)
                .accessibilityIdentifier("disabled-field")

            Toggle("Disabled Toggle", isOn: .constant(true))
                .disabled(true)
                .accessibilityIdentifier("disabled-toggle")

            Spacer()
        }
        .padding()
        .navigationTitle("Disabled")
    }
}

// MARK: - #13: VoiceOver Label Test

struct VoiceOverTestView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Standard Label")
                .accessibilityLabel("Standard Label")
                .accessibilityIdentifier("standard-label")

            // This button has a label that should always be visible
            // because _AXSSetAutomationEnabled activates the accessibility tree
            Button(action: {}) {
                Image(systemName: "star.fill")
            }
            .accessibilityLabel("Favorite Star")
            .accessibilityIdentifier("voiceover-star")

            // A view with accessibilityValue
            Text("Progress: 75%")
                .accessibilityValue("75 percent")
                .accessibilityIdentifier("progress-value")

            Spacer()
        }
        .padding()
        .navigationTitle("VoiceOver")
    }
}

// MARK: - #10: Auto-Tag Test (elements without identifiers)

struct AutoTagTestView: View {
    @State private var text = ""

    var body: some View {
        VStack(spacing: 20) {
            // These elements intentionally have NO accessibilityIdentifier.
            // Nerve's auto-tagging should assign them identifiers automatically.

            Button("Untagged Button") {
                print("[nerve] Untagged button tapped")
            }
            // NO .accessibilityIdentifier here

            Text("Untagged Label")
            // NO .accessibilityIdentifier here

            TextField("Untagged Field", text: $text)
            // NO .accessibilityIdentifier here

            // This one HAS an identifier — should NOT be overwritten
            Button("Tagged Button") {
                print("[nerve] Tagged button tapped")
            }
            .accessibilityIdentifier("already-tagged-btn")

            Spacer()
        }
        .padding()
        .navigationTitle("Auto-Tag")
    }
}

// MARK: - Double Tap Test

struct DoubleTapTestView: View {
    @State private var tapCount = 0
    @State private var result = "Double tap the box"

    var body: some View {
        VStack(spacing: 20) {
            Text(result)
                .accessibilityIdentifier("doubletap-result")

            Text("Tap Target")
                .font(.title)
                .frame(width: 200, height: 100)
                .background(Color.blue.opacity(0.2))
                .cornerRadius(12)
                .accessibilityIdentifier("doubletap-target")
                .onTapGesture(count: 2) {
                    tapCount += 1
                    result = "Double tap #\(tapCount)"
                    print("[nerve] Double tap detected: #\(tapCount)")
                }
                .onTapGesture(count: 1) {
                    result = "Single tap (not double)"
                    print("[nerve] Single tap on doubletap-target")
                }

            Spacer()
        }
        .padding()
        .navigationTitle("Double Tap")
    }
}

// MARK: - Drag & Drop Test

struct DragDropTestView: View {
    @State private var items = ["Item A", "Item B", "Item C", "Item D"]
    @State private var result = "Drag items to reorder"

    var body: some View {
        VStack {
            Text(result)
                .accessibilityIdentifier("dragdrop-result")
                .padding()

            List {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .accessibilityIdentifier("drag-\(item.lowercased().replacingOccurrences(of: " ", with: "-"))")
                }
                .onMove { from, to in
                    items.move(fromOffsets: from, toOffset: to)
                    result = "Reordered: \(items.joined(separator: ", "))"
                    print("[nerve] Reordered: \(items)")
                }
            }
            .environment(\.editMode, .constant(.active))
        }
        .navigationTitle("Drag & Drop")
    }
}

// MARK: - Pinch Zoom Test

struct PinchTestView: View {
    @State private var scale: CGFloat = 1.0
    @State private var result = "Pinch to zoom"

    var body: some View {
        VStack(spacing: 20) {
            Text(result)
                .accessibilityIdentifier("pinch-result")

            Image(systemName: "photo")
                .resizable()
                .frame(width: 200, height: 200)
                .scaleEffect(scale)
                .accessibilityIdentifier("pinch-target")
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = value
                        }
                        .onEnded { value in
                            result = "Zoomed to \(String(format: "%.1f", value))x"
                            print("[nerve] Pinch zoom: \(value)x")
                        }
                )

            Text("Scale: \(String(format: "%.1f", scale))x")
                .accessibilityIdentifier("pinch-scale")

            Button("Reset") {
                scale = 1.0
                result = "Pinch to zoom"
            }
            .accessibilityIdentifier("pinch-reset")

            Spacer()
        }
        .padding()
        .navigationTitle("Pinch Zoom")
    }
}

// MARK: - Context Menu Test

struct ContextMenuTestView: View {
    @State private var result = "Long press for context menu"

    var body: some View {
        VStack(spacing: 20) {
            Text(result)
                .accessibilityIdentifier("contextmenu-result")

            Text("Long Press Me")
                .font(.headline)
                .padding()
                .background(Color.green.opacity(0.2))
                .cornerRadius(10)
                .accessibilityIdentifier("contextmenu-target")
                .contextMenu {
                    Button {
                        result = "Copied!"
                        print("[nerve] Context menu: Copy")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    Button {
                        result = "Shared!"
                        print("[nerve] Context menu: Share")
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }

                    Button(role: .destructive) {
                        result = "Deleted!"
                        print("[nerve] Context menu: Delete")
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

            Spacer()
        }
        .padding()
        .navigationTitle("Context Menu")
    }
}

// MARK: - Network Test

struct NetworkTestView: View {
    @State private var result = "Not started"
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 20) {
            Text(result)
                .accessibilityIdentifier("network-result")

            Button("Fetch Data") {
                isLoading = true
                result = "Loading..."
                print("[nerve] Fetching data from httpbin...")
                Task {
                    do {
                        let url = URL(string: "https://httpbin.org/get?test=nerve")!
                        let session = URLSession(configuration: .default)
                        let (_, response) = try await session.data(from: url)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        result = "Status: \(status)"
                        print("[nerve] Network request completed: \(status)")
                    } catch {
                        result = "Error: \(error.localizedDescription)"
                        print("[nerve] Network request failed: \(error)")
                    }
                    isLoading = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)
            .accessibilityIdentifier("fetch-btn")

            Spacer()
        }
        .padding()
        .navigationTitle("Network")
    }
}
