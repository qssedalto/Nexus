import Testing
@testable import Nexus

struct FinderExtensionRegistryTests {
    @Test func parsesVerboseMatchesWithHostFlagsAndSpaces() {
        let extensions = FinderExtensionRegistry.parseMatches("""
        +  F com.example.enabled(1.2)\tUUID\t2026-01-01 00:00:00 +0000\t/Applications/Example One.app/Contents/PlugIns/Enabled.appex
        -    com.example.disabled(2)\tUUID\t2026-01-01 00:00:00 +0000\t/Applications/Example Two.app/Contents/PlugIns/Disabled.appex
           F com.example.automatic(1)\tUUID\t2026-01-01 00:00:00 +0000\t/Applications/Example Three.app/Contents/PlugIns/Automatic.appex
         (3 plug-ins)
        """)

        #expect(extensions.map(\.name) == ["Automatic", "Disabled", "Enabled"])
        #expect(extensions.map(\.election) == [.systemDefault, .disabled, .enabled])
        #expect(extensions.last?.id == "com.example.enabled")
        #expect(extensions.last?.url.path == "/Applications/Example One.app/Contents/PlugIns/Enabled.appex")
    }

    @Test func parsesNoMatches() {
        #expect(FinderExtensionRegistry.parseMatches("  (no matches)\n").isEmpty)
    }
}
