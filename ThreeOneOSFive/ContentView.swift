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
    @State private var tab: VitaTab = .home
    @State private var selectedGameID: String?
    @State private var pendingPatchID: UUID?
    @State private var pendingOpen: Bool?
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
        ZStack {
            MercyBackgroundVideo()
                .ignoresSafeArea()

            pageScroll(homeGamesPage)
                .opacity(tab == .home ? 1 : 0)
                .allowsHitTesting(tab == .home)
                .accessibilityHidden(tab != .home)
                .transaction { $0.animation = nil }

            pageScroll(profilePage)
                .opacity(tab == .info ? 1 : 0)
                .allowsHitTesting(tab == .info)
                .accessibilityHidden(tab != .info)

            if tab == .home && showNotice {
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
        .preferredColorScheme(.light)
        .alert(
            "MRCY iOS External",
            isPresented: Binding(
                get: { controller.message != nil },
                set: { if !$0 { controller.message = nil } }
            )
        ) {
            Button("OK", role: .cancel) { controller.message = nil }
        } message: {
            Text(controller.message ?? "")
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
        .onChange(of: store.isBusy) { value in
            if !value {
                controller.refresh(items: items)
                restoreLeftoverPatchesIfNeeded()
            }
        }
        .onChange(of: appState.exploitStatus) { handlePreparationChange($0) }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await contentUpdates.checkForUpdates(session: licenseSession, store: store) }
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
            if let selectedGame {
                functionPage(for: selectedGame)
            } else {
                appPickerPage
            }
        }
    }

    private var appPickerPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                ForEach(availableGames) { game in
                    Button {
                        selectedGameID = game.id
                    } label: {
                        HStack(spacing: 14) {
                            ContentGameIcon(game: game, size: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.name)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(AppTheme.primaryText)
                                    .lineLimit(1)
                                Text(gameSubtitle(for: game))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 14)
                        .background(AppTheme.optionSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                ContentGameIcon(game: game, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AppTheme.primaryText)
                    Text("FUNCTIONS")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(AppTheme.accent)
                }
                Spacer()
                Button("Change") { selectedGameID = nil }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            functionList(items(for: game))
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
        let open = controller.isOpen(item)
        let waiting = pendingPatchID == item.id && pendingOpen != nil
        let name = BundledFunctionCatalog.displayName(for: item)
        let rawDescription = ContentFunctionMetadataStore.metadata(for: item.id)?.description ?? ""
        let description = rawDescription.contains("|")
            ? String(rawDescription.split(separator: "|", maxSplits: 1).dropFirst().first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if waiting {
                ProgressView()
                    .tint(AppTheme.accent)
            }
            patchToggle(item, open: open, waiting: waiting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(open ? "Open" : "Closed")
    }

    private func skinCard(_ item: PatchLibraryItem) -> some View {
        let open = controller.isOpen(item)
        let waiting = pendingPatchID == item.id && pendingOpen != nil
        let name = BundledFunctionCatalog.displayName(for: item)
        let icon = ContentFunctionMetadataStore.metadata(for: item.id)?.icon

        return VStack(spacing: 10) {
            ZStack {
                AppTheme.pageBackground
                if let image = uploadedImage(icon) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .frame(height: 148)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(name)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
            patchToggle(item, open: open, waiting: waiting)
        }
        .padding(12)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(open ? "Open" : "Closed")
    }

    private func patchToggle(_ item: PatchLibraryItem, open: Bool, waiting: Bool) -> some View {
        Toggle("", isOn: Binding(
            get: { open },
            set: { requestOpen($0, item: item) }
        ))
        .labelsHidden()
        .tint(AppTheme.accent)
        .disabled(
            busy
                || item.project == nil
                || !appState.isSupported
                || appState.kernelExploitRunning
                || waiting
        )
    }

    private struct SkinSection {
        let title: String
        let items: [PatchLibraryItem]
    }

    private func skinSections(_ skins: [PatchLibraryItem]) -> [SkinSection] {
        var order: [String] = []
        var grouped: [String: [PatchLibraryItem]] = [:]
        for item in skins {
            let title = categoryName(for: item) ?? "Skin"
            if grouped[title] == nil {
                order.append(title)
                grouped[title] = []
            }
            grouped[title, default: []].append(item)
        }
        return order.map { SkinSection(title: $0, items: grouped[$0] ?? []) }
    }

    private func categoryName(for item: PatchLibraryItem) -> String? {
        let raw = ContentFunctionMetadataStore.metadata(for: item.id)?.description ?? ""
        guard let split = raw.firstIndex(of: "|") else { return nil }
        let name = raw[..<split].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func isSkin(_ item: PatchLibraryItem) -> Bool {
        categoryName(for: item)?.localizedCaseInsensitiveContains("skin") == true
    }

    private func uploadedImage(_ icon: String?) -> UIImage? {
        guard let icon, icon.hasPrefix("data:image"),
              let comma = icon.firstIndex(of: ",") else { return nil }
        let payload = String(icon[icon.index(after: comma)...])
        guard let data = Data(base64Encoded: payload) else { return nil }
        return UIImage(data: data)
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
        let seconds = total % 60
        return "\(days)d \(hours)h \(minutes)m \(seconds)s left"
    }

    private var profilePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                AppLogo(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mercy iOS External")
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
                    icon: "calendar",
                    title: "Expiry",
                    value: profileExpiryValue
                )
            }

            profileSection("App") {
                VitaProfileRow(
                    icon: "info.circle.fill",
                    title: "Name",
                    value: "Mercy iOS External"
                )
                VitaProfileRow(
                    icon: "square.stack.3d.up.fill",
                    title: "Version",
                    value: appVersion
                )
            }

            profileSection("Contact") {
                Button {
                    if let destination = URL(string: "https://chat.whatsapp.com/EGPInvSmpt7KzD5xXTpe7U?s=cl&p=i&mlu=4&ilr=4&iam=2") {
                        openURL(destination)
                    }
                } label: {
                    VitaProfileRow(
                        icon: "paperplane.fill",
                        title: "Mercy Official",
                        value: "Official"
                    )
                }
                .buttonStyle(.plain)
                VitaProfileRow(
                    icon: "person.fill",
                    title: "Shafay Dev",
                    value: "@shafaycheatsff"
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
        .background(Color.black.ignoresSafeArea())
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

    private var infoPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                AppLogo(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mercy iOS External")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppTheme.primaryText)
                    Text("PLAY BEYOND LIMITS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.tertiaryText)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                VitaSectionHeader(title: "Contact")
                VitaProfileCard {
                    infoLinkRow(
                        title: "Telegram",
                        subtitle: "Join our Telegram",
                        icon: "paperplane.fill",
                        url: "https://t.me/VITA_1280"
                    )
                    infoLinkRow(
                        title: "Channel",
                        subtitle: "Latest news & updates",
                        icon: "speaker.wave.2.fill",
                        url: "https://t.me/vitamodvip"
                    )
                    infoLinkRow(
                        title: "Website",
                        subtitle: "Visit our website",
                        icon: "globe",
                        url: "https://vitamods.com"
                    )
                    infoLinkRow(
                        title: "បុកពេជ្យតាម ID",
                        subtitle: "Get your key now",
                        icon: "cart.fill",
                        url: "https://t.me/maslowkhtopup",
                        hiddenURL: "https://maslowkh-topup.com/"
                    )
                    infoLinkRow(
                        title: "ទិញ Mod តាម Bot",
                        subtitle: "Buy mods via Telegram bot",
                        icon: "bubble.left.and.bubble.right.fill",
                        url: "https://t.me/Dns_ff_bot"
                    )
                }
            }
        }
    }

    private func infoLinkRow(
        title: String,
        subtitle: String,
        icon: String,
        url: String,
        hiddenURL: String? = nil
    ) -> some View {
        Button {
            if let destination = URL(string: url) {
                openURL(destination)
            }
        } label: {
            HStack(spacing: 12) {
                VitaProfileIcon(systemName: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onLongPressGesture {
            guard let hiddenURL, let destination = URL(string: hiddenURL) else { return }
            openURL(destination)
        }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private var compatibilityTint: Color {
        appState.isSupported ? Color(red: 0.22, green: 0.86, blue: 0.48) : .red
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return version
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

    private func requestOpen(_ open: Bool, item: PatchLibraryItem) {
        guard licenseSession.hasLiveAuthority && contentUpdates.hasVerifiedPolicy && contentUpdates.requiredRelease == nil else {
            controller.message = "License required."
            return
        }
        if appState.kernelExploitApplicable && !appState.exploitStatus.isSuccess {
            pendingPatchID = item.id
            pendingOpen = open
            appState.runKernelExploitIfNeeded()
            return
        }
        controller.setOpen(open, item: item, items: items)
    }

    private func handlePreparationChange(_ status: ExploitStatus) {
        if status.isSuccess {
            controller.restoreLeftoversIfNeeded(
                items: items,
                canAccessFiles: true
            ) {
                applyPendingOpenIfNeeded()
            }
        } else if status.isFailed, pendingOpen != nil {
            pendingPatchID = nil
            pendingOpen = nil
            controller.message = "Device preparation failed. Restart the app and try again."
        }
    }

    private func applyPendingOpenIfNeeded() {
        guard let pendingOpen,
              let pendingPatchID,
              let item = items.first(where: { $0.id == pendingPatchID }) else { return }
        self.pendingPatchID = nil
        self.pendingOpen = nil
        controller.setOpen(pendingOpen, item: item, items: items)
    }
}
