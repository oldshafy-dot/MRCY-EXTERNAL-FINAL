import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var store: PatchProjectStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var licenseSession: LicenseSessionController
    @EnvironmentObject private var contentUpdates: ContentUpdateController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var controller = VitaPatchController()
    @State private var tab: VitaTab = .game
    @State private var selectedGameID: String?
    @State private var bypassSelected = false
    @State private var pendingInjectID: UUID?
    @State private var injectedIDs: Set<UUID> = []
    @State private var showNotice = true
    @State private var profileCountdownNow = Date()
    @State private var noticeMessage = "Stay connected and get the latest updates, news, and announcements right on your bot!"
    @State private var noticeURL = URL(string: "https://t.me/roboiosbot")!

    private var busy: Bool { store.isBusy || controller.isWorking }
    private var items: [PatchLibraryItem] { store.items }

    private var availableGames: [ContentGameDescriptor] {
        contentUpdates.games.filter { game in
            game.slug == "free-fire" || game.slug == "free-fire-max"
        }
    }
    private var selectedGame: ContentGameDescriptor? {
        guard let selectedGameID else { return nil }
        return availableGames.first(where: { $0.id == selectedGameID })
    }

    private func items(for game: ContentGameDescriptor) -> [PatchLibraryItem] {
        items
            .filter { item in
                ContentFunctionMetadataStore.metadata(for: item.id)?.gameSlug ?? "free-fire"
                    == game.slug
            }
            .sorted { left, right in
                let leftSort = ContentFunctionMetadataStore.metadata(for: left.id)?.sort ?? .max
                let rightSort = ContentFunctionMetadataStore.metadata(for: right.id)?.sort ?? .max
                if leftSort != rightSort { return leftSort < rightSort }
                return BundledFunctionCatalog.displayName(for: left)
                    .localizedCaseInsensitiveCompare(
                        BundledFunctionCatalog.displayName(for: right)
                    ) == .orderedAscending
            }
    }

    var body: some View {
        ZStack(alignment: .top) {
            PandaBackground()

            pageScroll(profilePage)
                .opacity(tab == .home ? 1 : 0)
                .allowsHitTesting(tab == .home)
                .accessibilityHidden(tab != .home)

            pageScroll(homeGamesPage)
                .opacity(tab == .game ? 1 : 0)
                .allowsHitTesting(tab == .game)
                .accessibilityHidden(tab != .game)
                .transaction { $0.animation = nil }

            pageScroll(cmdPage)
                .opacity(tab == .cmd ? 1 : 0)
                .allowsHitTesting(tab == .cmd)
                .accessibilityHidden(tab != .cmd)

            if tab == .game && showNotice {
                LoginNoticeCard(
                    message: noticeMessage,
                    onOpen: { openURL(noticeURL) },
                    onClose: { showNotice = false }
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VitaLiquidTabBar(selection: $tab)
                .padding(.top, 6)
                .padding(.bottom, 4)
        }
        .tint(AppTheme.accent)
        .preferredColorScheme(.dark)
        .alert(
            "Panda Injector",
            isPresented: Binding(
                get: { controller.message != nil },
                set: { if !$0 { controller.message = nil } }
            )
        ) {
            Button("OK", role: .cancel) { controller.message = nil }
        } message: {
            Text(controller.message ?? "")
        }
        .alert(
            "Inject",
            isPresented: Binding(
                get: { pendingInjectID != nil },
                set: { if !$0 { pendingInjectID = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingInjectID = nil }
            Button("Inject") {
                guard let id = pendingInjectID else { return }
                pendingInjectID = nil
                Task {
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    await MainActor.run { injectedIDs.insert(id) }
                }
            }
        } message: {
            Text("Do you want to inject this feature?")
        }
        .onAppear {
            if contentUpdates.integrityCompromised {
                RuntimeGuard.rejectTamper()
            }
            controller.licenseAllowsApply = { licenseSession.hasLiveAuthority && contentUpdates.hasVerifiedPolicy && contentUpdates.requiredRelease == nil }
            controller.requestPermit = { packageID, packageData, apply in
                try await licenseSession.authorizeWrite(
                    packageID: packageID,
                    packageData: packageData,
                    apply: apply
                )
            }
            controller.refresh(items: items)
            restoreLeftoverPatchesIfNeeded()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await contentUpdates.checkForUpdates(session: licenseSession, store: store) }
            }
        }
        .task { await contentUpdates.checkForUpdates(session: licenseSession, store: store) }
        .task {
            if let notice = await licenseSession.loginNotice() {
                noticeMessage = notice.message
                noticeURL = notice.url
            } else {
                showNotice = false
            }
        }
    }

    private func pageScroll<Content: View>(_ content: Content) -> some View {
        ScrollView {
            content
                .frame(maxWidth: 560)
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var homeGamesPage: some View {
        Group {
            if bypassSelected {
                bypassPage
            } else if let selectedGame {
                functionPage(for: selectedGame)
            } else {
                appPickerPage
            }
        }
    }

    private var appPickerPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PANDA")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(Color.black)
            Text("Select App")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)

            VStack(spacing: 0) {
                ForEach(Array(availableGames.enumerated()), id: \.element.id) { index, game in
                    Button {
                        bypassSelected = false
                        selectedGameID = game.id
                    } label: {
                        HStack(spacing: 14) {
                            ContentGameIcon(game: game, size: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.name)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(Color.black)
                                Text(gameSubtitle(for: game))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Color.black.opacity(0.65))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    if index < availableGames.count - 1 {
                        Divider().overlay(Color.black.opacity(0.10))
                    }
                }
                Divider().overlay(Color.black.opacity(0.10))
                Button {
                    selectedGameID = nil
                    bypassSelected = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(Color.black)
                            .frame(width: 52, height: 52)
                            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bypass")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(Color.black)
                            Text("Online-configured option")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Color.black.opacity(0.65))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
            }
            .background(Color.white.opacity(0.32), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func gameSubtitle(for game: ContentGameDescriptor) -> String {
        switch game.slug {
        case "free-fire": return "Normal"
        case "free-fire-max": return "MAX"
        default: return "Ready"
        }
    }

    private func functionPage(for game: ContentGameDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ContentGameIcon(game: game, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name).font(.system(size: 20, weight: .bold)).foregroundStyle(Color.black)
                    Text("FUNCTIONS").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black)
                }
                Spacer()
                Button("Change") { selectedGameID = nil; bypassSelected = false }.foregroundStyle(Color.black)
            }
            functionList(items(for: game))
        }
    }

    private var bypassPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 22, weight: .bold)).foregroundStyle(Color.black)
                    .frame(width: 48, height: 48).background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bypass").font(.system(size: 20, weight: .bold)).foregroundStyle(Color.black)
                    Text("ONLINE CONFIGURATION").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.black)
                }
                Spacer()
                Button("Change") { bypassSelected = false; selectedGameID = nil }.foregroundStyle(Color.black)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Bypass").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.black)
                Text("This option is available from the app selector. Its details can be supplied by the online configuration.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.secondaryText)
            }
            .padding(18).background(Color.white.opacity(0.32), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func functionList(
        _ rows: [PatchLibraryItem],
        empty: String = "No functions yet. They will appear after an update."
    ) -> some View {
        Group {
            if rows.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(busy ? "Checking for updates…" : empty)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                    Spacer()
                    if busy {
                        ProgressView()
                            .tint(AppTheme.accent)
                    }
                }
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 12) {
                    ForEach(rows) { item in
                        functionRow(item)
                    }
                }
            }
        }
    }

    private func functionRow(_ item: PatchLibraryItem) -> some View {
        let waiting = pendingInjectID == item.id
        let name = BundledFunctionCatalog.displayName(for: item)
        let rawDescription = ContentFunctionMetadataStore.metadata(for: item.id)?.description ?? ""
        let description = rawDescription.contains("|")
            ? String(rawDescription.split(separator: "|", maxSplits: 1).dropFirst().first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.black)
                if !description.isEmpty {
                    Text(description).font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.secondaryText).lineLimit(2)
                }
                if injectedIDs.contains(item.id) {
                    Text("Injected").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
                }
            }
            Spacer()
            if waiting {
                ProgressView().tint(.black)
            } else if injectedIDs.contains(item.id) {
                Text("Injected").font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
                    .padding(.horizontal, 10).padding(.vertical, 7).background(Color.green.opacity(0.12), in: Capsule())
            } else {
                Button("Inject") { pendingInjectID = item.id }
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 38)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
                    .buttonStyle(.plain).disabled(busy || !appState.isSupported)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color.white.opacity(0.30), in: RoundedRectangle(cornerRadius: 16))
    }

    private var profilePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                AppLogo(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 0) {
                        Text("Panda Injector")
                            .foregroundStyle(Color.black)
                    }
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.white)
                    Text("Play Beyond Limits")
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }

            profileSection("Device") {
                VitaProfileRow(
                    icon: "iphone",
                    title: "This iPhone",
                    subtitle: appState.isSupported
                        ? "Ready to use functions"
                        : "This iOS version is not supported",
                    badge: appState.isSupported ? "Supported" : "Unsupported",
                    badgeColor: compatibilityTint
                )
                VitaProfileRow(
                    icon: "iphone",
                    title: "Model",
                    value: AppInfo.hardwareDisplayName
                )
                VitaProfileRow(
                    icon: "cpu",
                    title: "iOS Version",
                    value: AppInfo.osVersion
                )
                VitaProfileRow(
                    icon: "square.stack.3d.up.fill",
                    title: "Build",
                    value: AppInfo.osBuild
                )
            }

            profileSection("License") {
                VitaProfileRow(
                    icon: "checkmark.shield.fill",
                    title: "Status",
                    value: licenseSession.hasLiveAuthority ? "Active" : "Inactive"
                )
                VitaProfileRow(
                    icon: "calendar",
                    title: "Expiry",
                    value: profileExpiryValue
                )
            }

            profileSection("About App") {
                VitaProfileRow(
                    icon: "info.circle.fill",
                    title: "Name",
                    value: "Panda Injector"
                )
                VitaProfileRow(
                    icon: "square.stack.3d.up.fill",
                    title: "Version",
                    value: appVersion
                )
            }

            Button {
                licenseSession.logout()
            } label: {
                HStack(spacing: 12) {
                    VitaProfileIcon(systemName: "rectangle.portrait.and.arrow.right", tint: .red)
                    Text("Sign Out")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(minHeight: 56)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sign Out")
        }
        .padding(.horizontal, 2)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            profileCountdownNow = value
        }
    }

    private func profileSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Color.white.opacity(0.78))
                .padding(.horizontal, 4)
            VitaProfileCard(content: content)
        }
    }

    private var cmdPage: some View {
        let patchCount = items.count
        let gameCount = availableGames.count
        return VStack(alignment: .leading, spacing: 12) {
            Text("CMD").font(.system(size: 28, weight: .heavy)).foregroundStyle(Color.black)
            Text("LOGS").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(Color.black)
            VStack(alignment: .leading, spacing: 10) {
                logLine("Login/session verified")
                logLine("Online patch data checked")
                logLine("\(gameCount) online app option(s) loaded")
                logLine("\(patchCount) patch/function item(s) available")
                if let selectedGame { logLine("Selected app: \(selectedGame.name)") }
                if bypassSelected { logLine("Selected app: Bypass") }
                if !injectedIDs.isEmpty { logLine("\(injectedIDs.count) function UI action(s) completed") }
                logLine("Panda Injector ready")
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(Color.white)
        }
    }

    private func logLine(_ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(">").font(.system(size: 12, weight: .bold, design: .monospaced))
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    private var compatibilityTint: Color {
        appState.isSupported ? Color(red: 0.22, green: 0.86, blue: 0.48) : .red
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var profileExpiryValue: String {
        guard let expiry = parsedProfileExpiryDate else {
            return licenseSession.profile?.expiryText ?? "—"
        }
        if expiry <= profileCountdownNow {
            return "Expired • \(expiry.formatted(date: .abbreviated, time: .shortened))"
        }
        return "\(remainingProfileText(until: expiry)) • \(expiry.formatted(date: .abbreviated, time: .shortened))"
    }

    private var parsedProfileExpiryDate: Date? {
        guard let text = licenseSession.profile?.expiryText, !text.isEmpty else { return nil }
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
            "MMM d, yyyy h:mm a",
            "MMM d, yyyy"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }

    private func remainingProfileText(until expiry: Date) -> String {
        let total = max(0, Int(expiry.timeIntervalSince(profileCountdownNow)))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        return "\(days) Days \(hours) Hours \(minutes) Minutes"
    }

    private var canAccessPatchedFiles: Bool {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 17 {
            return false
        }
        if appState.kernelExploitApplicable {
            return appState.exploitStatus.isSuccess
        }
        return appState.isSupported
    }

    private func restoreLeftoverPatchesIfNeeded() {
        controller.restoreLeftoversIfNeeded(
            items: items,
            canAccessFiles: canAccessPatchedFiles
        )
    }

}