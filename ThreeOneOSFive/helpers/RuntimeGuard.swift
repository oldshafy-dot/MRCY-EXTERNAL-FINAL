import CryptoKit
import Darwin
import Foundation
import MachO
import UIKit

enum CatalogTrust {
    static func reconcileLocalCatalog(fileManager: FileManager = .default) {
        // Until a signed release catalog is on disk, leave local packages alone.
        // Wiping them and sealing used to quit the app on launch (seen on iOS 16.7.x).
        guard let allowed = installedDigests(fileManager: fileManager) else { return }
        guard let root = try? PatchProjectLibrary.packageRootURL(fileManager: fileManager),
              let urls = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else {
            return
        }
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if Self.isRejectedExtension(ext) {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard let data = try? PatchProjectLibrary.readPackage(at: url) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            let digest = sha256Hex(data)
            if !allowed.contains(digest) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    static func contains(_ data: Data, fileManager: FileManager = .default) -> Bool {
        guard let allowed = installedDigests(fileManager: fileManager) else { return false }
        return allowed.contains(sha256Hex(data))
    }

    static func isOpaqueCatalogName(_ fileName: String) -> Bool {
        guard fileName == (fileName as NSString).lastPathComponent,
              fileName.utf8.count <= 72,
              !fileName.contains("/"),
              !fileName.contains("\\") else {
            return false
        }
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        guard (16...40).contains(stem.utf8.count),
              stem.unicodeScalars.allSatisfy(isHex) else {
            return false
        }
        return ext.isEmpty || ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func installedDigests(fileManager: FileManager) -> Set<String>? {
        guard let directory = try? releasesDirectory(fileManager: fileManager),
              let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ),
              !urls.isEmpty else {
            return nil
        }
        var digests = Set<String>()
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(
                    ContentReleaseManifest.self,
                    from: data
                  ) else {
                continue
            }
            for package in manifest.packages {
                digests.insert(package.sha256.lowercased())
            }
        }
        return digests.isEmpty ? nil : digests
    }

    private static func releasesDirectory(fileManager: FileManager) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("VitaMods", isDirectory: true)
            .appendingPathComponent("ContentReleases", isDirectory: true)
    }

    private static func isRejectedExtension(_ ext: String) -> Bool {
        guard !ext.isEmpty else { return false }
        return ext == String(bytes: [0x69, 0x6b, 0x6a, 0x6f].map { $0 ^ 0x5A }, encoding: .utf8)!
            || ext == String(bytes: [0x2c, 0x33, 0x2e, 0x3b].map { $0 ^ 0x5A }, encoding: .utf8)!
            || ext == String(bytes: [0x3d, 0x22, 0x3c].map { $0 ^ 0x5A }, encoding: .utf8)!
    }

    private static func isHex(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...70).contains(scalar.value)
            || (97...102).contains(scalar.value)
    }
}

enum RuntimeGuard {
    private static let lock = NSLock()
    private static var sealed = false

    static func inspectLaunch() {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 17,
           isHostileEnvironment() {
            seal()
            return
        }
        CatalogTrust.reconcileLocalCatalog()
    }

    static func rejectImport() {
        seal()
    }

    static func rejectTamper() {
        seal()
    }

    static func requireLiveSession(licensed: Bool, policy: Bool) {
        if isHostileEnvironment() || !licensed || !policy {
            seal()
        }
    }

    static func seal() {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 17 {
            log("guard: seal ignored on iOS 16 so the app can stay open")
            return
        }
        lock.lock()
        if sealed {
            lock.unlock()
            return
        }
        sealed = true
        lock.unlock()
        RuntimePermit.clear()
        _exit(0)
    }

    private static func isHostileEnvironment() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return isBeingTraced() || hasHostileImages()
        #endif
    }

    private static func isBeingTraced() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let status = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard status == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    private static func hasHostileImages() -> Bool {
        let needles = ["frida", "cycript", "sslkillswitch"]
        let count = _dyld_image_count()
        for index in 0..<count {
            guard let cName = _dyld_get_image_name(index) else { continue }
            let name = String(cString: cName).lowercased()
            if needles.contains(where: { name.contains($0) }) {
                return true
            }
        }
        return false
    }
}
