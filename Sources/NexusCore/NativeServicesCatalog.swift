import Foundation

/// Declared (not necessarily enabled) Apple Services registrations. macOS does
/// not provide a stable public API for querying each service's effective
/// enabled state or context-menu nesting, so those remain explicitly unknown.
public struct NativeServiceDefinition: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let application: String
    public let bundleID: String?
    public let category: String?
    public let fileTypes: [String]
    public let pasteboardTypes: [String]
    public let defaultShortcut: String?
    public let bundlePath: String

    public var inputTypes: [String] {
        fileTypes + pasteboardTypes
    }
}

/// Filesystem catalog, intentionally read-only. This does not inspect
/// LaunchServices' private databases or change third-party bundles.
public enum NativeServicesCatalog {
    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
            URL(fileURLWithPath: "/Library/Services", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            home.appendingPathComponent("Library/Services", isDirectory: true)
        ]
    }

    /// Apps nested in vendor folders (e.g. Adobe/...) are inspected without
    /// traversing their resource payloads. Symlink loops are not followed.
    /// The entry limit prevents scanning unrelated volumes indefinitely.
    public static func scan(roots: [URL] = defaultRoots(), maxEntries: Int = 20_000) -> [NativeServiceDefinition] {
        let fm = FileManager.default
        var visited = 0
        var seen = Set<String>()
        var records: [NativeServiceDefinition] = []
        for root in roots {
            guard let walker = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }
            while let url = walker.nextObject() as? URL {
                visited += 1
                if visited > maxEntries { return sort(records) }
                if walker.level > 5 { walker.skipDescendants(); continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let ext = url.pathExtension.lowercased()
                guard ext == "app" || ext == "workflow" else { continue }
                walker.skipDescendants()
                let canonical = url.standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }
                records.append(contentsOf: definitions(at: url))
            }
        }
        return sort(records)
    }

    /// This can be independently unit-tested with synthetic app bundles.
    public static func definitions(at bundleURL: URL) -> [NativeServiceDefinition] {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let info: [String: Any]
        if let bundle = Bundle(url: bundleURL), let dictionary = bundle.infoDictionary {
            info = dictionary
        } else if let data = try? Data(contentsOf: infoURL),
                  let dictionary = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil
                  ) as? [String: Any] {
            info = dictionary
        } else { return [] }
        guard let declarations = info["NSServices"] as? [[String: Any]],
              !declarations.isEmpty else { return [] }
        let application = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let id = info["CFBundleIdentifier"] as? String
        return declarations.enumerated().map { index, service in
            let menu = service["NSMenuItem"] as? [String: String] ?? [:]
            let name = menu["default"] ?? "Unknown service"
            return NativeServiceDefinition(
                id: "\(bundleURL.standardizedFileURL.path)#\(index)",
                name: name, application: application,
                bundleID: id, category: service["NSServiceCategory"] as? String,
                fileTypes: service["NSSendFileTypes"] as? [String] ?? [],
                pasteboardTypes: service["NSSendTypes"] as? [String] ?? [],
                defaultShortcut: (service["NSKeyEquivalent"] as? [String: String])?["default"],
                bundlePath: bundleURL.standardizedFileURL.path
            )
        }
    }

    private static func sort(_ records: [NativeServiceDefinition]) -> [NativeServiceDefinition] {
        records.sorted {
            let relation = $0.name.localizedCaseInsensitiveCompare($1.name)
            return relation == .orderedSame ? $0.id < $1.id : relation == .orderedAscending
        }
    }
}
