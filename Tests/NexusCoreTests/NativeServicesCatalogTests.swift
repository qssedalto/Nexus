import Foundation
import XCTest
@testable import SlashgrabCore

final class NativeServicesCatalogTests: XCTestCase {
    func testCatalogFindsNestedAppsAndWorkflowsWithoutGuessingActivation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vendor = root.appendingPathComponent("Vendor Suite")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        let app = vendor.appendingPathComponent("Copy Helper.app")
        try writeBundle(at: app, displayName: "Copy Helper", bundleID: "dev.nexus.test.helper", entries: [
            ["NSMenuItem": ["default": "Copy text"], "NSSendTypes": ["public.utf8-plain-text"], "NSKeyEquivalent": ["default": "c"]],
            ["NSMenuItem": ["default": "Copy paths"], "NSSendFileTypes": ["public.item"]]
        ])

        let workflow = root.appendingPathComponent("Review.workflow")
        try writeBundle(at: workflow, displayName: "Review workflow", bundleID: "dev.nexus.test.review", entries: [
            ["NSMenuItem": ["default": "Review text"], "NSSendTypes": ["public.rtf"]]
        ])

        let seen = NativeServicesCatalog.scan(roots: [root])
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(seen.map(\.name), ["Copy paths", "Copy text", "Review text"])
        XCTAssertEqual(seen.first(where: { $0.name == "Copy paths" })?.fileTypes, ["public.item"])
        XCTAssertEqual(seen.first(where: { $0.name == "Copy text" })?.pasteboardTypes, ["public.utf8-plain-text"])
        XCTAssertEqual(seen.first(where: { $0.name == "Copy text" })?.defaultShortcut, "c")
        XCTAssertEqual(seen.first(where: { $0.name == "Review text" })?.bundleID, "dev.nexus.test.review")
    }

    func testCatalogIsReadOnlyWhenNoRegistrationsExist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(at: root.appendingPathComponent("No Services.app"),
                        displayName: "No Services", bundleID: "test.empty", entries: [])
        XCTAssertTrue(NativeServicesCatalog.scan(roots: [root]).isEmpty)
        XCTAssertTrue(NativeServicesCatalog.scan(roots: [root], maxEntries: 1).isEmpty)
    }

    private func writeBundle(
        at url: URL, displayName: String, bundleID: String,
        entries: [[String: Any]]
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundlePackageType": url.pathExtension == "app" ? "APPL" : "BNDL",
            "CFBundleExecutable": "not-launched",
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleIdentifier": bundleID,
            "CFBundleVersion": "1",
            "NSServices": entries
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
