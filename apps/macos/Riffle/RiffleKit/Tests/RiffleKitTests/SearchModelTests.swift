import Foundation
import Testing
@testable import RiffleKit

@MainActor
@Suite struct SearchModelTests {
    private func makeModel(
        _ service: FakeSearchService = FakeSearchService(),
        store: MemoryConnectionStore = MemoryConnectionStore(.sample),
        clock: FakeClock = FakeClock()
    ) -> SearchModel {
        SearchModel(store: store, makeService: { _ in service }, now: { clock.now })
    }

    // MARK: Search

    @Test func textSearchStoresFiltersSourceAndResults() async {
        let service = FakeSearchService()
        let model = makeModel(service)
        model.text = "  acme renewal  "
        await model.submitText()

        #expect(await service.requests == [.text("acme renewal")])
        #expect(model.filters == SearchFilters(text: "renewal", sort: .relevance))
        #expect(model.source == .claude)
        #expect(model.results.map(\.id) == ["a"])
        #expect(model.phase == .done)
    }

    @Test func emptyTextDoesNotSearch() async {
        let service = FakeSearchService()
        let model = makeModel(service)
        model.text = "   "
        await model.submitText()
        #expect(await service.requests.isEmpty)
        #expect(model.phase == .idle)
    }

    @Test func emptyTextClearsTheResults() async {
        let service = FakeSearchService()
        let model = makeModel(service)
        model.text = "acme renewal"
        await model.submitText()

        model.text = "  "
        await model.submitText()

        #expect(await service.requests.count == 1)
        expectCleared(model)
    }

    @Test func clearCancelsTheRunningSearch() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let service = FakeSearchService { _ in
            for await _ in gate {}
            return .sample(["late"])
        }
        let model = makeModel(service)

        model.text = "acme renewal"
        let search = Task { await model.submitText() }
        await service.waitForRequests(1)
        model.clear()
        open.finish()
        await search.value

        expectCleared(model)
    }

    private func expectCleared(_ model: SearchModel) {
        #expect(model.text == "")
        #expect(model.filters == nil)
        #expect(model.source == nil)
        #expect(model.results.isEmpty)
        #expect(model.phase == .idle)
        #expect(model.editor == nil)
    }

    @Test func exampleSetsTextAndSearches() async {
        let service = FakeSearchService()
        let model = makeModel(service)
        await model.runExample(SearchModel.examples[0])
        #expect(model.text == "receipts from amazon last month")
        #expect(await service.requests == [.text("receipts from amazon last month")])
    }

    @Test func filterChangeSendsFilters() async {
        let service = FakeSearchService { request in
            guard case .filters(let filters) = request else { return .sample() }
            return .sample(["b"], filters: filters, source: .filters)
        }
        let model = makeModel(service)
        let filters = SearchFilters(from: ["acme"])
        await model.setFilters(filters)

        #expect(await service.requests == [.filters(filters)])
        #expect(model.filters == filters)
        #expect(model.source == .filters)
        #expect(model.results.map(\.id) == ["b"])
    }

    @Test func removeSendsFiltersWithoutTheFieldAndClosesTheEditor() async {
        let service = FakeSearchService { request in
            guard case .filters(let filters) = request else { return .sample(filters: SearchFilters(text: "tax", from: ["irs"])) }
            return .sample(filters: filters, source: .filters)
        }
        let model = makeModel(service)
        model.text = "tax from irs"
        await model.submitText()
        model.editor = .field(.from)
        await model.remove(.from)

        #expect(await service.requests.last == .filters(SearchFilters(text: "tax")))
        #expect(model.editor == nil)
    }

    @Test func newSearchCancelsTheRunningSearch() async {
        let (gate, open) = AsyncStream<Void>.makeStream()
        let service = FakeSearchService { request in
            if request == .text("first") {
                for await _ in gate {}
                return .sample(["old"])
            }
            return .sample(["new"])
        }
        let model = makeModel(service)

        model.text = "first"
        let first = Task { await model.submitText() }
        await service.waitForRequests(1)
        #expect(model.phase == .reading)

        model.text = "second"
        await model.submitText()
        open.finish()
        await first.value

        #expect(model.results.map(\.id) == ["new"])
        #expect(model.phase == .done)
    }

    @Test func errorKeepsOldResults() async {
        let service = FakeSearchService { request in
            if request == .text("broken") { throw SearchError.server }
            return .sample()
        }
        let model = makeModel(service)
        model.text = "fine"
        await model.submitText()
        model.text = "broken"
        await model.submitText()

        #expect(model.phase == .failed(.server))
        #expect(model.results.map(\.id) == ["a"])
    }

    @Test func returnRepeatsAFailedFilterSearch() async {
        let service = FakeSearchService { request in
            if case .filters = request { throw SearchError.timeout }
            return .sample()
        }
        let model = makeModel(service)
        model.text = "renewal"
        await model.submitText()
        let filters = SearchFilters(text: "renewal", sort: .oldest)
        await model.setFilters(filters)
        #expect(model.phase == .failed(.timeout))

        await model.submitText()
        #expect(await service.requests == [.text("renewal"), .filters(filters), .filters(filters)])
    }

    @Test func noConnectionNeedsSetupAndDoesNotSearch() async {
        let service = FakeSearchService()
        let model = makeModel(service, store: MemoryConnectionStore())
        #expect(model.needsSetup)
        model.text = "tax"
        await model.submitText()
        #expect(await service.requests.isEmpty)
    }

    // MARK: Editor

    @Test func escapeClosesTheEditorFirst() {
        let model = makeModel()
        model.editor = .add
        #expect(model.escape())
        #expect(model.editor == nil)
        #expect(!model.escape())
    }

    @Test func escapeClosesTheEditorThenClearsTheSearch() async {
        let model = makeModel()
        model.text = "acme renewal"
        await model.submitText()
        model.editor = .add

        #expect(model.escape())
        #expect(model.editor == nil)
        #expect(model.results.map(\.id) == ["a"])

        #expect(model.escape())
        expectCleared(model)

        #expect(!model.escape())
    }

    @Test func escapeClearsTextThatWasNotSearched() {
        let model = makeModel()
        model.text = "acme"
        #expect(model.escape())
        #expect(model.text == "")
        #expect(!model.escape())
    }

    // MARK: Labels

    @Test func loadsLabelsOnceWithoutSpam() async {
        let service = FakeSearchService()
        let model = makeModel(service)
        await model.loadLabels()
        await model.loadLabels()

        #expect(model.labels == .loaded([LabelInfo(name: "Receipts", type: "user")]))
        #expect(await service.labelCalls == 1)
    }

    // MARK: Warm-up

    @Test func warmsUpAtMostOnceInTenMinutes() async {
        let service = FakeSearchService()
        let clock = FakeClock()
        let model = makeModel(service, clock: clock)

        await model.warmUp()
        clock.now += 9 * 60
        await model.warmUp()
        #expect(await service.healthCalls == 1)

        clock.now += 60
        await model.warmUp()
        #expect(await service.healthCalls == 2)
    }

    @Test func warmUpStoresTheNewestMessageDate() async {
        let newest = Date(timeIntervalSince1970: 1_792_766_520)
        let model = makeModel(FakeSearchService(newestMessageAt: newest))
        #expect(model.newestMessageAt == nil)

        await model.warmUp()
        #expect(model.newestMessageAt == newest)
    }

    // MARK: Setup

    @Test func setupSavesOnSuccess() async throws {
        let store = MemoryConnectionStore()
        let model = makeModel(store: store)
        try await model.testAndSave(url: " https://new.example.com/ ", token: " new-token ")

        #expect(store.saved == Connection(url: URL(string: "https://new.example.com/")!, token: "new-token"))
        #expect(!model.needsSetup)
    }

    @Test func emptyTokenKeepsTheSavedToken() async throws {
        let store = MemoryConnectionStore(.sample)
        let model = makeModel(store: store)
        model.showingSetup = true
        try await model.testAndSave(url: "https://other.example.com/", token: "")

        #expect(store.saved?.token == "saved-token")
        #expect(store.saved?.url.absoluteString == "https://other.example.com/")
        #expect(!model.showingSetup)
    }

    @Test func setupRejectsAWrongToken() async {
        let store = MemoryConnectionStore()
        let model = makeModel(FakeSearchService(healthError: .unauthorized), store: store)
        await #expect(throws: SearchModel.SetupError.unauthorized) {
            try await model.testAndSave(url: "https://new.example.com/", token: "wrong")
        }
        #expect(store.saved == nil)
        #expect(model.needsSetup)
    }

    @Test func setupReportsAnUnreachableURL() async {
        let model = makeModel(FakeSearchService(healthError: .network), store: MemoryConnectionStore())
        await #expect(throws: SearchModel.SetupError.unreachable) {
            try await model.testAndSave(url: "https://new.example.com/", token: "token")
        }
    }

    @Test(arguments: ["", "search.example.com", "http://search.example.com/", "https://"])
    func setupRejectsABadURL(_ url: String) async {
        let model = makeModel(store: MemoryConnectionStore())
        await #expect(throws: SearchModel.SetupError.invalidURL) {
            try await model.testAndSave(url: url, token: "token")
        }
    }

    @Test func setupNeedsATokenTheFirstTime() async {
        let model = makeModel(store: MemoryConnectionStore())
        await #expect(throws: SearchModel.SetupError.missingToken) {
            try await model.testAndSave(url: "https://new.example.com/", token: " ")
        }
    }
}
