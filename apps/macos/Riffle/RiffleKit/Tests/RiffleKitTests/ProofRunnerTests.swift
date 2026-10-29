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
        var reports: [String] = []

        let outcome = await runner(service, loader).run(receipts) { id, result in
            if result == .stored { reports.append(id) }
        }

        #expect(outcome == .done(made: 3, wrong: 0, skipped: 0))
        #expect(reports == ["a:0", "b:0", "c:0"])
        #expect(loader.loaded == receipts.map(\.printUrl))
        #expect(loader.printed == 3)
        #expect(await service.calls == [.record("a:0"), .record("b:0"), .record("c:0")])
    }

    @Test func sendsWhatThePageShowed() async throws {
        let service = FakeProofsService()
        let receipt = receipts[0]
        let page = LoadedPage(finalUrl: URL(string: "https://riders.uber.com/trips/a")!, status: nil, hasPasswordField: false, text: "Total $23.45")

        _ = await runner(service, FakePageLoader(pages: [receipt.printUrl: page])).run([receipt])

        #expect(await service.results == [
            PageResult(
                id: "a:0", finalUrl: "https://riders.uber.com/trips/a", status: nil, hasPasswordField: false, text: "Total $23.45",
                pdf: Data("%PDF-1.4".utf8)
            ),
        ])
    }

    @Test func doesNotPrintAPageWithoutTheReceipt() async {
        let service = FakeProofsService(fidelity: "wrong_page")
        let receipt = receipts[0]
        let page = LoadedPage(finalUrl: receipt.printUrl, status: 200, hasPasswordField: false, text: "Billing and payments")
        let loader = FakePageLoader(pages: [receipt.printUrl: page])

        let outcome = await runner(service, loader).run([receipt])

        #expect(outcome == .done(made: 0, wrong: 1, skipped: 0))
        #expect(loader.printed == 0)
        #expect(await service.results.map(\.pdf) == [nil])
    }

    @Test func skipsASignInPageWithoutPrintingAndGoesOn() async {
        let service = FakeProofsService()
        var pages = receiptPages(receipts)
        pages[receipts[1].printUrl] = .signIn
        let loader = FakePageLoader(pages: pages)

        let outcome = await runner(service, loader).run(receipts)

        #expect(outcome == .done(made: 2, wrong: 0, skipped: 1))
        #expect(loader.loaded == receipts.map(\.printUrl))
        #expect(loader.printed == 2)
    }

    @Test func stopsAfterThreeSignInPagesInSequence() async {
        let more = receipts + [PendingReceipt.sample("d:0")]
        let loader = FakePageLoader(pages: Dictionary(uniqueKeysWithValues: more.map { ($0.printUrl, LoadedPage.signIn) }))

        let outcome = await runner(FakeProofsService(), loader).run(more)

        #expect(outcome == .needsSignIn)
        #expect(loader.loaded.count == 3)
    }

    @Test func needsSignInWhenNoPageLoadsWithTheSession() async {
        let loader = FakePageLoader(pages: [receipts[0].printUrl: .signIn])

        #expect(await runner(FakeProofsService(), loader).run([receipts[0]]) == .needsSignIn)
    }

    @Test func stopsWhenTheServerSeesSignInPages() async {
        let service = FakeProofsService(fidelity: "blocked")

        let outcome = await runner(service, FakePageLoader(pages: receiptPages(receipts))).run(receipts)

        #expect(outcome == .needsSignIn)
        #expect(await service.calls.count == 3)
    }

    @Test func countsPagesThatAreNotReceipts() async {
        let service = FakeProofsService(fidelity: "wrong_page")

        let outcome = await runner(service, FakePageLoader(pages: receiptPages(receipts))).run(receipts)

        #expect(outcome == .done(made: 0, wrong: 3, skipped: 0))
    }

    @Test func leavesAnErrorPagePending() async {
        let service = FakeProofsService(fidelity: "link_failed")

        let outcome = await runner(service, FakePageLoader(pages: receiptPages(receipts))).run(receipts)

        #expect(outcome == .done(made: 0, wrong: 0, skipped: 3))
    }

    @Test func skipsAFailedReceiptAndGoesOn() async {
        let service = FakeProofsService(failingRecords: ["b:0"])
        var pages = receiptPages(receipts)
        pages[receipts[0].printUrl] = nil

        let outcome = await runner(service, FakePageLoader(pages: pages)).run(receipts)

        #expect(outcome == .done(made: 1, wrong: 0, skipped: 2))
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

    @Test func reportsTheResultOfEachReceipt() async {
        let service = FakeProofsService(failingRecords: ["b:0"])
        var pages = receiptPages(receipts)
        pages[receipts[2].printUrl] = .signIn
        var reports: [String: ReceiptResult] = [:]

        _ = await runner(service, FakePageLoader(pages: pages)).run(receipts) { reports[$0] = $1 }

        #expect(reports["a:0"] == .stored)
        #expect(reports["b:0"] == .failed("The search service failed."))
        #expect(reports["c:0"] == .needsSignIn)
    }

    @Test(arguments: [("wrong_page", ReceiptResult.wrongPage), ("link_failed", .failed("The link gave an error page."))])
    func reportsWhatTheServerSaw(fidelity: String, expected: ReceiptResult) async {
        var reports: [ReceiptResult] = []

        _ = await runner(FakeProofsService(fidelity: fidelity), FakePageLoader(pages: receiptPages(receipts))).run([receipts[0]]) {
            reports.append($1)
        }

        #expect(reports == [expected])
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
    func record(_ result: PageResult) async throws -> ProofFidelity { throw SearchError.unauthorized }
}
