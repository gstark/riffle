import Foundation
import Testing
@testable import RiffleKit

@MainActor
@Suite struct ProofsModelTests {
    private let uber = PendingSite(site: "uber.com", merchant: "Uber", receipts: [.sample("u:0")])
    private let heroku = PendingSite(site: "heroku.com", merchant: "Heroku", receipts: [.sample("h:0", site: "heroku.com")])

    private func model(
        _ service: FakeProofsService,
        loader: FakePageLoader,
        defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!,
        connected: Bool = true
    ) -> ProofsModel {
        ProofsModel(
            store: MemoryConnectionStore(connected ? .sample : nil),
            makeService: { _ in service },
            makeRunner: { ProofRunner(service: $0, loader: loader, sleep: { _ in }) },
            defaults: defaults
        )
    }

    @Test func loadsThePendingSites() async {
        let model = model(FakeProofsService(sites: [uber, heroku]), loader: FakePageLoader())

        await model.refresh()

        #expect(model.load == .loaded)
        #expect(model.sites.map(\.site) == ["uber.com", "heroku.com"])
        #expect(model.pendingCount == 2)
        #expect(model.status(of: "uber.com") == .needsSignIn)
    }

    @Test func showsALoadError() async {
        let model = model(FakeProofsService(pendingError: .network), loader: FakePageLoader())

        await model.refresh()

        #expect(model.load == .failed(.network))
    }

    @Test func doesNothingWithoutAConnection() async {
        let service = FakeProofsService(sites: [uber])
        let model = model(service, loader: FakePageLoader(), connected: false)

        await model.refresh()

        #expect(model.load == .notLoaded)
        #expect(await service.calls.isEmpty)
    }

    @Test func aSuccessfulRunMarksTheSiteReadyForTheTimer() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = model(FakeProofsService(sites: [uber]), loader: FakePageLoader(pages: receiptPages(uber.receipts)), defaults: defaults)
        await model.refresh()

        await model.makePDFs(site: "uber.com")

        #expect(model.status(of: "uber.com") == .done(made: 1, wrong: 0, skipped: 0))
        #expect(model.results["u:0"] == .stored)
        #expect(!model.isRunning)
        #expect(defaults.stringArray(forKey: "signedInSites") == ["uber.com"])
    }

    @Test func theTimerRunsOnlySignedInSites() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(["uber.com"], forKey: "signedInSites")
        let loader = FakePageLoader(pages: receiptPages(uber.receipts + heroku.receipts))
        let model = model(FakeProofsService(sites: [uber, heroku]), loader: loader, defaults: defaults)

        await model.runInBackground()

        #expect(loader.loaded == uber.receipts.map(\.printUrl))
        #expect(model.status(of: "uber.com") == .done(made: 1, wrong: 0, skipped: 0))
        #expect(model.status(of: "heroku.com") == .needsSignIn)
        #expect(!model.needsAttention)
    }

    @Test func anEndedSessionShowsTheBadgeUntilASuccessfulRun() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(["uber.com"], forKey: "signedInSites")
        let loader = FakePageLoader(pages: [uber.receipts[0].printUrl: .signIn])
        let model = model(FakeProofsService(sites: [uber]), loader: loader, defaults: defaults)

        await model.runInBackground()
        #expect(model.needsAttention)
        #expect(model.status(of: "uber.com") == .needsSignIn)

        // The timer does not try the ended session again.
        await model.runInBackground()
        #expect(loader.loaded.count == 1)

        // You sign in and click the button.
        loader.pages = receiptPages(uber.receipts)
        await model.makePDFs(site: "uber.com")
        #expect(!model.needsAttention)
        #expect(defaults.stringArray(forKey: "expiredSites") == [])
    }

    @Test func aSiteWithoutASessionDoesNotShowTheBadge() async {
        let loader = FakePageLoader(pages: [uber.receipts[0].printUrl: .signIn])
        let model = model(FakeProofsService(sites: [uber]), loader: loader)
        await model.refresh()

        await model.makePDFs(site: "uber.com")

        #expect(model.status(of: "uber.com") == .needsSignIn)
        #expect(!model.needsAttention)
    }

    @Test func aSecondSiteWaitsInTheQueue() async {
        let loader = FakePageLoader(pages: receiptPages(uber.receipts + heroku.receipts))
        let model = model(FakeProofsService(sites: [uber, heroku]), loader: loader)
        await model.refresh()

        let first = Task { await model.makePDFs(site: "uber.com") }
        while !model.isRunning { await Task.yield() }
        await model.makePDFs(site: "heroku.com")

        #expect(model.status(of: "heroku.com") == .queued)
        #expect(model.queue.map(\.site) == ["heroku.com"])
        #expect(model.progress?.total == 2)

        await first.value
        #expect(loader.loaded == (uber.receipts + heroku.receipts).map(\.printUrl))
        #expect(model.status(of: "heroku.com") == .done(made: 1, wrong: 0, skipped: 0))
        #expect(model.progress == nil)
        #expect(model.queue.isEmpty)
    }

    @Test func stopEmptiesTheQueue() async {
        let loader = FakePageLoader(pages: receiptPages(uber.receipts + heroku.receipts))
        let model = model(FakeProofsService(sites: [uber, heroku]), loader: loader)
        await model.refresh()

        let first = Task { await model.makePDFs(site: "uber.com") }
        while !model.isRunning { await Task.yield() }
        await model.makePDFs(site: "heroku.com")
        model.cancel()
        await first.value

        #expect(!loader.loaded.contains(heroku.receipts[0].printUrl))
        #expect(model.status(of: "heroku.com") == .needsSignIn)
        #expect(model.queue.isEmpty)
    }

    @Test func progressTimeLeft() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(ProofsModel.Progress(done: 2, total: 10, startedAt: start).timeLeft(now: start.addingTimeInterval(20)) == nil)
        #expect(ProofsModel.Progress(done: 5, total: 10, startedAt: start).timeLeft(now: start.addingTimeInterval(50)) == 50)
    }

    @Test func statusText() {
        #expect(ProofsModel.SiteStatus.working(done: 12, total: 37).text == "Working 12 of 37")
        #expect(ProofsModel.SiteStatus.done(made: 3, wrong: 0, skipped: 0).text == "Done: 3 PDFs")
        #expect(ProofsModel.SiteStatus.done(made: 3, wrong: 0, skipped: 1).text == "Done: 3 PDFs, 1 failed")
        #expect(ProofsModel.SiteStatus.done(made: 3, wrong: 7, skipped: 1).text == "Done: 3 PDFs, 7 not receipts, 1 failed")
    }
}
