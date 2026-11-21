import Foundation

struct InstalledFinderExtension: Identifiable, Sendable {
    enum Election: Sendable {
        case enabled, disabled, systemDefault
    }

    let id: String
    let name: String
    let url: URL
    let election: Election
}

enum FinderExtensionRegistry {
    private static let extensionPoint = "com.apple.FinderSync"

    static func installedExtensions() throws -> [InstalledFinderExtension] {
        let output = try run(["-m", "-v", "-p", extensionPoint])
        return parseMatches(output)
    }

    static func setEnabled(_ enabled: Bool, for id: String) throws -> [InstalledFinderExtension] {
        _ = try run(["-e", enabled ? "use" : "ignore", "-p", extensionPoint, "-i", id])
        let extensions = try installedExtensions()
        guard extensions.first(where: { $0.id == id })?.election == (enabled ? .enabled : .disabled) else {
            throw RegistryError.electionNotApplied
        }
        return extensions
    }

    static func registerEmbeddedExtensionIfNeeded(at url: URL) throws {
        let path = url.resolvingSymlinksInPath().path
        let registered = try installedExtensions().contains {
            $0.url.resolvingSymlinksInPath().path == path
        }
        if !registered {
            _ = try run(["-a", url.path])
        }
    }

    static func parseMatches(_ output: String) -> [InstalledFinderExtension] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            // Verbose output has four tab-separated fields. The first can include host flags.
            let columns = line.split(separator: "\t", maxSplits: 3)
            guard columns.count == 4, columns[3].hasPrefix("/"),
                  let identifierAndVersion = columns[0].split(whereSeparator: \.isWhitespace).last,
                  let versionStart = identifierAndVersion.firstIndex(of: "(") else {
                return nil
            }
            let id = String(identifierAndVersion[..<versionStart])
            guard !id.isEmpty, !id.hasPrefix("-"),
                  id.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
                return nil
            }

            let url = URL(fileURLWithPath: String(columns[3]), isDirectory: true)
            let bundle = Bundle(url: url)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            let election: InstalledFinderExtension.Election = switch line.first {
            case "+": .enabled
            case "-": .disabled
            default: .systemDefault
            }
            return InstalledFinderExtension(id: id, name: name, url: url, election: election)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RegistryError.commandFailed
        }
        return String(decoding: data, as: UTF8.self)
    }

    private enum RegistryError: Error {
        case commandFailed
        case electionNotApplied
    }
}
