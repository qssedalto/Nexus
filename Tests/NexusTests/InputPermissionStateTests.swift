import Testing
@testable import Nexus

struct InputPermissionStateTests {
    private final class Permissions: InputPermissionProviding {
        var listening = false
        var accessibility = false

        func canListen() -> Bool { listening }
        func requestListening() -> Bool { listening }
        func canUseAccessibility() -> Bool { accessibility }
        func requestAccessibility() -> Bool { accessibility }
    }

    private final class Listener: InputEventListening {
        var tapState = InputTapState.stopped
        var nextStart = InputTapState.listening
        var receivedEvents = false
        var starts = 0

        func start() {
            starts += 1
            tapState = nextStart
        }

        func stop() {
            tapState = .stopped
            receivedEvents = false
        }
    }

    @Test func permissionGrantAndRevocationAreIndependent() {
        let permissions = Permissions()
        let listener = Listener()
        var state = InputPermissionState()
        permissions.accessibility = true
        state.refresh(permissions: permissions, listener: listener, enabled: true, paused: false, storage: .ready)
        #expect(state.accessibilityGranted)
        #expect(!state.listeningGranted)
        #expect(listener.starts == 0)

        permissions.listening = true
        permissions.accessibility = false
        state.refresh(permissions: permissions, listener: listener, enabled: true, paused: false, storage: .ready)
        #expect(!state.accessibilityGranted)
        #expect(state.listeningGranted)
        #expect(state.tap == .listening)
        #expect(listener.starts == 1)

        permissions.listening = false
        state.refresh(permissions: permissions, listener: listener, enabled: true, paused: false, storage: .ready)
        #expect(!state.listeningGranted)
        #expect(state.tap == .stopped)
    }

    @Test func tapFailureRetriesAndPauseStopsImmediately() {
        let permissions = Permissions()
        permissions.listening = true
        let listener = Listener()
        listener.nextStart = .creationFailed
        var state = InputPermissionState()
        state.refresh(permissions: permissions, listener: listener, enabled: true, paused: false, storage: .ready)
        #expect(state.listeningGranted)
        #expect(state.tap == .creationFailed)

        listener.nextStart = .listening
        state.refresh(permissions: permissions, listener: listener, enabled: true, paused: false, storage: .ready)
        #expect(state.tap == .listening)
        #expect(!state.receivedEvents)

        listener.receivedEvents = true
        state.refresh(permissions: permissions, listener: listener, enabled: true, paused: false, storage: .written)
        #expect(state.receivedEvents)
        #expect(state.storage == .written)
        #expect(listener.starts == 2)

        listener.tapState = .disabled
        state.refresh(permissions: permissions, listener: listener, enabled: true, paused: false, storage: .writeFailed)
        #expect(state.tap == .listening)
        #expect(state.storage == .writeFailed)
        #expect(listener.starts == 3)

        state.refresh(permissions: permissions, listener: listener, enabled: true, paused: true, storage: .written)
        #expect(state.tap == .stopped)
        #expect(!state.receivedEvents)
        state.refresh(permissions: permissions, listener: listener, enabled: false, paused: false, storage: .written)
        #expect(state.tap == .stopped)
        #expect(listener.starts == 3)
    }

    @Test func missingStorageDoesNotMaskSystemPermission() {
        let permissions = Permissions()
        permissions.listening = true
        var state = InputPermissionState()
        state.refresh(permissions: permissions, listener: nil, enabled: true, paused: false, storage: nil)
        #expect(state.listeningGranted)
        #expect(state.tap == .stopped)
        #expect(state.storage == nil)
    }
}
