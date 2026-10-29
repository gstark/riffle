import Foundation
import Testing
@testable import RiffleKit

@MainActor
@Suite struct ProofRunnerTests {
    private let receipts = ["a:0", "b:0", "c:0"].map { PendingReceipt.sample($0) }

    private func runner(_ service: FakeProofsService, _ loader: FakePageLoader) -> ProofRunner {
        ProofRunner(service: service, loader: loader, sleep: { _ in })
    }

    @Test func makesEachProofInOrder() async {
        let service = FakeProofsService()
        let loader = FakePageLoader(pages: receiptPages(receipts))
        var progress: [Int] = []

        let outcome = await runner(service, loader).run(receipts) { progress.append($0) }

        #expect(outcome == .done(made: 3, skipped: 0))
        #expect(progress == [1, 2, 3])
        #expect(loader.loaded == receipts.map(\.printUrl))
        #expect(loader.printed == 3)
        #expect(await service.calls == [
            .ticket("a:0"), .upload("a:0"), .record("a:0"),
            .ticket("b:0"), .upload("b:0"), .record("b:0"),
            .ticket("c:0"), .upload("c:0"), .record("c:0"),
        ])
    }

    @Test func sendsWhatThePageShowed() async throws {
        let service = FakeProofsService()
        let receipt = receipts[0]
        let page = LoadedPage(finalUrl: URL(string: "https://riders.uber.com/trips/a")!, status: nil, hasPasswordField: false, text: "Total")

        _ = await runner(service, FakePageLoader(pages: [receipt.printUrl: page])).run([receipt])

        #expect(await service.results == [
            PageResult(id: "a:0", finalUrl: "https://riders.uber.com/trips/a", status: nil, hasPasswordField: false, text: "Total"),
        ])
    }

    @Test func stopsAtASignInPageBeforeItPrints() async {
        let service = FakeProofsService()
        var pages = receiptPages(receipts)
        pages[receipts[1].printUrl] = .signIn
        let loader = FakePageLoader(pages: pages)

        let outcome = await runner(service, loader).run(receipts)

        #expect(outcome == .needsSignIn)
        #expect(loader.loaded == [receipts[0].printUrl, receipts[1].printUrl])
        #expect(loader.printed == 1)
    }

    @Test func stopsWhenTheServerSeesASignInPage() async {
        let service = FakeProofsService(fidelity: "blocked")

        let outcome = await runner(service, FakePageLoader(pages: receiptPages(receipts))).run(receipts)

        #expect(outcome == .needsSignIn)
        #expect(await service.calls.count == 3)
    }

    @Test func skipsAFailedReceiptAndGoesOn() async {
        let service = FakeProofsService(failingUploads: ["b:0"])
        var pages = receiptPages(receipts)
        pages[receipts[0].printUrl] = nil

        let outcome = await runner(service, FakePageLoader(pages: pages)).run(receipts)

        #expect(outcome == .done(made: 1, skipped: 2))
        #expect(await service.calls.last == .record("c:0"))
    }

    @Test func stopsAfterThreeFailuresInSequence() async {
        let more = receipts + [PendingReceipt.sample("d:0")]
        let loader = FakePageLoader(pages: [more[3].printUrl: .receipt(more[3].printUrl)])

        let outcome = await runner(FakeProofsService(), loader).run(more)

        guard case .failed = outcome else { Issue.record("Expected failed, got \(outcome)"); return }
        #expect(loader.loaded.count == 3)
    }

    @Test func stopsWhenTheTokenIsNotAccepted() async {
        let loader = FakePageLoader(pages: receiptPages(receipts))

        #expect(await ProofRunner(service: UnauthorizedService(), loader: loader, sleep: { _ in }).run(receipts) == .unauthorized)
        #expect(loader.loaded.count == 1)
    }

    @Test func waitsBetweenPages() async {
        let waits = WaitLog()
        let runner = ProofRunner(
            service: FakeProofsService(), loader: FakePageLoader(pages: receiptPages(receipts)),
            pause: .seconds(2), sleep: { await waits.add($0) }
        )

        _ = await runner.run(receipts)

        #expect(await waits.durations == [.seconds(2), .seconds(2)])
    }
}

private actor WaitLog {
    private(set) var durations: [Duration] = []
    func add(_ duration: Duration) { durations.append(duration) }
}

private struct UnauthorizedService: ProofsService {
    func pending() async throws -> [PendingSite] { throw SearchError.unauthorized }
    func uploadTicket(id: String, sha256: String) async throws -> UploadTicket { throw SearchError.unauthorized }
    func upload(_ pdf: Data, to ticket: UploadTicket, sha256: String) async throws { throw SearchError.unauthorized }
    func record(_ result: PageResult) async throws -> ProofFidelity { throw SearchError.unauthorized }
}
