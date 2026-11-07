import SwiftUI
import UIKit

@main
struct RoboIOSApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var patchStore = PatchProjectStore()
    @StateObject private var licenseSession = LicenseSessionController()
    @StateObject private var contentUpdates = ContentUpdateController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        setupLogCapture()
        let iosMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if iosMajor >= 17 {
            gx_harden_process()
        }
        do {
            _ = try RuntimeMaterial.reveal()
        } catch {
            log("app: runtime material unavailable — continuing on iOS \(AppInfo.osVersion)")
            if iosMajor >= 17 {
                RuntimeGuard.seal()
            }
        }
        if iosMajor >= 17 {
            BundledFunctionCatalog.removeFactorySeedIfNeeded()
            RuntimeGuard.inspectLaunch()
        }
        log("app: MRCY iOS launching")
    }

    var body: some Scene {
        WindowGroup {
            LicenseGateView()
                .environmentObject(appState)
                .environmentObject(patchStore)
                .environmentObject(licenseSession)
                .environmentObject(contentUpdates)
                .onAppear { patchStore.reload() }
                .environment(\.appLanguage, AppLanguage.english)
                .environment(\.locale, AppLanguage.english.locale)
                .onChange(of: licenseSession.state) { state in
                    if state == .authenticated, licenseSession.hasLiveAuthority {
                        appState.detectSupport()
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        Task {
                            await licenseSession.sceneBecameActive()
                            if licenseSession.state == .authenticated,
                               licenseSession.hasLiveAuthority {
                                appState.detectSupport()
                            }
                        }
                    }
                }
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}
