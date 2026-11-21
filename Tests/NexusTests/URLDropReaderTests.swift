import AppKit
import Foundation
import Testing
@testable import Nexus

@Suite("URL drop reader")
struct URLDropReaderTests {
    @Test("Reads file URLs from pasteboard objects")
    func readsFileURLObjects() {
        let pasteboard = makePasteboard()
        let firstURL = URL(fileURLWithPath: "/tmp/Nexus Test/A.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/Nexus Test/B.txt")
        guard pasteboard.writeObjects([firstURL as NSURL, secondURL as NSURL]) else {
            #expect(URLDropReader.fileURLs(fromRawValues: [firstURL.absoluteString, secondURL.absoluteString]) == [firstURL, secondURL])
            return
        }

        let inspection = URLDropReader.inspection(of: pasteboard)

        #expect(inspection.canAccept)
        #expect(inspection.urls.map(\.path) == [
            "/tmp/Nexus Test/A.txt",
            "/tmp/Nexus Test/B.txt",
        ])
    }

    @Test("Reads file URL data")
    func readsFileURLData() {
        let pasteboard = makePasteboard()
        let fileURLType = NSPasteboard.PasteboardType("public.file-url")
        pasteboard.declareTypes([fileURLType], owner: nil)
        let didWrite = pasteboard.setData(
            Data("file:///tmp/Nexus%20Test/A.txt".utf8),
            forType: fileURLType
        )

        guard didWrite else {
            #expect(URLDropReader.fileURLs(fromRawValues: ["file:///tmp/Nexus%20Test/A.txt"]).map(\.path) == ["/tmp/Nexus Test/A.txt"])
            return
        }

        let inspection = URLDropReader.inspection(of: pasteboard)

        #expect(inspection.canAccept)
        #expect(inspection.urls.map(\.path) == ["/tmp/Nexus Test/A.txt"])
    }

    @Test("Deduplicates standardized file paths")
    func deduplicatesStandardizedPaths() {
        let pasteboard = makePasteboard()
        let fileURLType = NSPasteboard.PasteboardType("public.file-url")
        pasteboard.declareTypes([fileURLType], owner: nil)
        pasteboard.setString("file:///tmp/Nexus%20Test/../Nexus%20Test/A.txt", forType: fileURLType)

        let item = NSPasteboardItem()
        item.setString("/tmp/Nexus Test/A.txt", forType: fileURLType)
        guard pasteboard.writeObjects([item]) else {
            #expect(URLDropReader.fileURLs(fromRawValues: ["file:///tmp/Nexus%20Test/../Nexus%20Test/A.txt", "/tmp/Nexus Test/A.txt"]).map(\.path) == ["/tmp/Nexus Test/A.txt"])
            return
        }

        let inspection = URLDropReader.inspection(of: pasteboard)

        #expect(inspection.canAccept)
        #expect(inspection.urls.map(\.path) == ["/tmp/Nexus Test/A.txt"])
    }

    @Test("Rejects non-file pasteboard data")
    func rejectsNonFilePasteboardData() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("https://example.com/not-a-file", forType: .string)

        let inspection = URLDropReader.inspection(of: pasteboard)

        #expect(!inspection.canAccept)
        #expect(inspection.urls.isEmpty)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboardName = NSPasteboard.Name("com.qssedalto.nexus.tests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()
        return pasteboard
    }
}
