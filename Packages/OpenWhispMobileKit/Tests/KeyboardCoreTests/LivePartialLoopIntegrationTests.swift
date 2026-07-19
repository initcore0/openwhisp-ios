import XCTest
@testable import KeyboardCore
import MobileCore

/// Integration-style coverage for the WP10c live-partial rendering LOOP, wiring the
/// same pieces the keyboard shell's `pumpLivePartial` wires: read the newest
/// `LivePartial` from a `LivePartialStore`, decide with `LivePartialRenderModel`,
/// and drive a `KeyboardTextSink`. This proves the render decision actually reaches
/// the sink (the wiring-review lesson: exercise reachability, not just the model),
/// and that the secure-field gate suppresses BEFORE any sink mutation.
final class LivePartialLoopIntegrationTests: XCTestCase {

    /// A sink that maintains a real field string, applying delete-suffix + insert
    /// exactly like `UITextDocumentProxy`.
    private final class FieldSink: KeyboardTextSink {
        var field = ""
        var isSecureField = false
        var returnKeyLabel: ReturnKeyLabel = .return
        var hasFullAccess = true
        var autocapType: KeyboardAutocapType = .sentences
        var contextBeforeCaret: String? { field }

        func insert(_ text: String) { field += text }
        func deleteBackward(_ count: Int) {
            var chars = Array(field)
            chars.removeLast(min(count, chars.count))
            field = String(chars)
        }
    }

    /// Mirror of the shell's `pumpLivePartial`: read newest partial, decide, apply.
    private func pump(_ store: LivePartialStore, _ model: inout LivePartialRenderModel, _ sink: FieldSink) {
        guard let partial = (try? store.read()).flatMap({ $0 }) else { return }
        switch model.apply(partial, isSecureField: sink.isSecureField) {
        case .ignore:
            break
        case let .edit(deleteBackward, insert):
            if deleteBackward > 0 { sink.deleteBackward(deleteBackward) }
            if !insert.isEmpty { sink.insert(insert) }
        }
    }

    private func partial(_ cid: UUID, _ seq: Int, _ text: String, final: Bool = false) -> LivePartial {
        LivePartial(captureID: cid, seq: seq, text: text, isFinal: final, updatedAt: Date())
    }

    // MARK: - A whole capture streams and finalizes into the field

    func testCaptureStreamsThenFinalizes() throws {
        let store = InMemoryLivePartialStore()
        var model = LivePartialRenderModel()
        let sink = FieldSink()
        let cap = UUID()

        // The store is last-writer-wins: each write, then the loop drains it.
        try store.write(partial(cap, 0, "hello"));              pump(store, &model, sink)
        try store.write(partial(cap, 1, "hello wor"));          pump(store, &model, sink)
        try store.write(partial(cap, 2, "hello world"));        pump(store, &model, sink)
        XCTAssertEqual(sink.field, "hello world")

        // Final swaps in the cleaned text.
        try store.write(partial(cap, 3, "Hello, world.", final: true)); pump(store, &model, sink)
        XCTAssertEqual(sink.field, "Hello, world.")
        // Tracking cleared for the next capture.
        XCTAssertNil(model.captureID)
    }

    // MARK: - Missed polls (store coalesces) still converge

    func testCoalescedPollsConverge() throws {
        let store = InMemoryLivePartialStore()
        var model = LivePartialRenderModel()
        let sink = FieldSink()
        let cap = UUID()

        // Host wrote three times; the keyboard polled only once (last-writer-wins).
        try store.write(partial(cap, 0, "a"))
        try store.write(partial(cap, 1, "ab"))
        try store.write(partial(cap, 2, "abc"))
        pump(store, &model, sink)
        XCTAssertEqual(sink.field, "abc", "a coalesced poll renders the newest text in one edit")
    }

    // MARK: - Secure field: nothing ever reaches the sink

    func testSecureFieldNeverTouchesSink() throws {
        let store = InMemoryLivePartialStore()
        var model = LivePartialRenderModel()
        let sink = FieldSink()
        sink.isSecureField = true
        let cap = UUID()

        try store.write(partial(cap, 0, "secret")); pump(store, &model, sink)
        try store.write(partial(cap, 1, "Secret.", final: true)); pump(store, &model, sink)
        XCTAssertEqual(sink.field, "", "a session capture must NEVER render into a secure field")
        XCTAssertNil(model.captureID)
    }
}
