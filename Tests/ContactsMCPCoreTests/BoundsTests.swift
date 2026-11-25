import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ContactsMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, and the texts
/// the model reads. Every person, list, account and note in here is invented.
@Suite("Bounds")
struct BoundsTests {

    private struct ToolResult {
        var text: String
        var isError: Bool
        var content: [ToolOutput.Block]
    }

    private static func call(
        _ tool: String, _ arguments: [String: Value] = [:], store: FakeContactStore,
        timeout: Duration = ContactTools.defaultTimeout
    ) async -> ToolResult {
        let result = await ContactTools(store: store, timeout: timeout)
            .handle(ToolCall(name: tool, arguments: arguments))
        return ToolResult(text: result.text, isError: result.isError, content: result.content)
    }

    // MARK: An invented address book with as many rows as a test asks for

    private static func padded(_ index: Int) -> String {
        String(format: "%04d", index)
    }

    /// The shape of the identifier Contacts gives a card, which is the widest part of a row
    /// that cannot be shortened.
    private static func contactID(_ index: Int) -> String {
        "00000000-0000-4000-8000-00000000\(padded(index)):ABPerson"
    }

    private static func listID(_ index: Int) -> String {
        "00000000-0000-4000-8000-00000000\(padded(index)):ABGroup"
    }

    /// A person whose every value is about as wide as an ordinary one gets: a 40-character
    /// name, an international phone number, a 40-character address and a 30-character
    /// company. `widePageShrinks` covers the rows that are wider still.
    private static func person(_ index: Int) -> ContactDetail {
        Fixtures.detail(
            id: contactID(index), displayName: "Invented Person \(padded(index)) Of Nowhere At All",
            organization: "Fictitious Holdings Number \(padded(index))",
            phones: [LabelledValue(label: "mobile", value: "+34 600 00\(padded(index).prefix(1)) \(padded(index).suffix(3))")],
            emails: [LabelledValue(label: "work", value: "person.\(padded(index))@a-long-invented-name.invalid")])
    }

    private static func people(_ count: Int) -> FakeContactStore {
        FakeContactStore(contacts: (0..<count).map(person))
    }

    /// One listing tool, and an address book that gives it `count` rows of the widest
    /// ordinary width, in the order the tool lists them. `row` is text found in row
    /// `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var name: String
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var arguments: [String: Value] = [:]
        var store: @Sendable (Int) -> FakeContactStore
        var row: @Sendable (Int) -> String

        var testDescription: String { name }

        func call(_ count: Int, _ extra: [String: Value] = [:]) async -> ToolResult {
            await BoundsTests.call(tool, arguments.merging(extra) { _, new in new }, store: store(count))
        }

        /// The rows of an address book with `count` of them that `text` shows, in order.
        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }
    }

    private static let search = Listing(
        name: "contacts_search", tool: ToolCatalog.searchName, things: "contacts",
        limits: ToolCatalog.contactLimitRange, defaultLimit: ToolCatalog.defaultContactLimit,
        arguments: ["query": "Invented"], store: { people($0) }, row: { "id=\(contactID($0))" })

    private static let everyone = Listing(
        name: "contacts_all", tool: ToolCatalog.allName, things: "contacts",
        limits: ToolCatalog.contactLimitRange, defaultLimit: ToolCatalog.defaultContactLimit,
        store: { people($0) }, row: { "id=\(contactID($0))" })

    private static let everyoneCompact = Listing(
        name: "contacts_all compact", tool: ToolCatalog.allName, things: "contacts",
        limits: ToolCatalog.contactLimitRange, defaultLimit: ToolCatalog.defaultContactLimit,
        arguments: ["compact": true], store: { people($0) }, row: { "id=\(contactID($0))" })

    private static let lists = Listing(
        name: "contacts_lists", tool: ToolCatalog.listsName, things: "lists",
        limits: ToolCatalog.listLimitRange, defaultLimit: ToolCatalog.defaultListLimit,
        store: { count in
            FakeContactStore(
                // Out of order, as the store hands them over.
                lists: (0..<count).reversed().map {
                    ContactList(
                        id: listID($0), name: "Invented List Number \(padded($0))",
                        accountName: "Invented Account", memberCount: 0)
                },
                accounts: [
                    ContactAccount(id: "account-0", name: "Invented Account", kind: .cardDAV, isDefault: true)
                ])
        },
        row: { "id=\(listID($0))" })

    private static let listings = [search, everyone, everyoneCompact, lists]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(listing.defaultLimit) of \(total) \(listing.things). Pass offset=\(listing.defaultLimit) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(listing.defaultLimit)
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
        #expect(!result.text.contains("is clipped"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                """
                limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.
                Showing 1–\(maximum) of \(total) \(listing.things). Pass offset=\(maximum) for the next page.


                """))
        #expect(listing.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of \(total) "))
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix("Showing 1–3 of 7 \(listing.things). Pass offset=3 for the next page.\n\n"))
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix("Showing 4–6 of 7 \(listing.things). Pass offset=6 for the next page.\n"))
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n"))
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n"))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)
        #expect(past.text.contains("(nothing at this offset)"))

        let lastRow = await listing.call(7, ["offset": .int(6)])
        #expect(listing.rows(in: lastRow.text, of: 7) == [6])

        let negative = await listing.call(7, ["offset": .int(-1)])
        let range = ToolCatalog.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))
    }

    @Test("An empty listing says that nothing exists, not that an offset skipped it", arguments: listings)
    private func emptyListing(_ listing: Listing) async {
        let none = await listing.call(0)
        #expect(!none.isError)
        #expect(!none.text.contains("(nothing at this offset)"))
        #expect(!none.text.contains("Showing"))
    }

    @Test("A listing states its order")
    func orderIsStated() async {
        #expect(await Self.search.call(1).text.contains("ordered by name, then id"))
        #expect(await Self.everyone.call(1).text.contains("ordered by name, then id"))
        #expect(await Self.lists.call(1).text.contains("ordered by name, then account and id"))
        #expect(await Self.lists.call(1).text.contains("Accounts: 1, ordered by name, then id"))
    }

    @Test("Two contacts of the same name never tie: the id decides, the same on every call")
    func namesakesAreOrderedByID() async {
        let store = FakeContactStore(contacts: ["id-c", "id-a", "id-b"].map {
            Fixtures.detail(id: $0, displayName: "Twin Notreal")
        })
        var seen: [String] = []
        for offset in 0..<3 {
            let result = await Self.call(
                ToolCatalog.allName, ["limit": 1, "offset": .int(offset)], store: store)
            seen += ["id-a", "id-b", "id-c"].filter { result.text.contains("id=\($0)") }
        }
        #expect(seen == ["id-a", "id-b", "id-c"])
    }

    @Test("Lists and accounts are paged by the same window, each with its own sentence")
    func listsAndAccountsPageTogether() async {
        let store = FakeContactStore(
            lists: (0..<5).map {
                ContactList(id: Self.listID($0), name: "Invented List \($0)", accountName: "Account 0", memberCount: 0)
            },
            accounts: (0..<3).reversed().map {
                ContactAccount(id: "account-\($0)", name: "Account \($0)", kind: .local, isDefault: $0 == 0)
            })
        let first = await Self.call(ToolCatalog.listsName, ["limit": 2], store: store)
        #expect(
            first.text.hasPrefix(
                """
                Showing 1–2 of 5 lists. Pass offset=2 for the next page.
                Showing 1–2 of 3 accounts. Pass offset=2 for the next page.


                """))
        #expect(first.text.contains("  Account 0  local  (new contacts go here)\n  Account 1  local"))
        #expect(!first.text.contains("Account 2  local"))

        let second = await Self.call(ToolCatalog.listsName, ["limit": 2, "offset": 2], store: store)
        #expect(
            second.text.hasPrefix(
                """
                Showing 3–4 of 5 lists. Pass offset=4 for the next page.
                Showing 3–3 of 3 accounts. That is all.


                """))
        #expect(second.text.contains("Account 2  local"))

        let third = await Self.call(ToolCatalog.listsName, ["limit": 2, "offset": 4], store: store)
        #expect(
            third.text.hasPrefix(
                """
                Showing 5–5 of 5 lists. That is all.
                Showing 0 of 3 accounts: offset=4 is past the end. That is all.


                """))
    }

    // MARK: Values wider than a row allows

    @Test("A long value is shortened in its row, and the result says so before the rows")
    func longValuesAreClipped() async {
        let long = String(repeating: "x", count: ToolCatalog.cellWidth + 1)
        let exact = String(repeating: "y", count: ToolCatalog.cellWidth)
        let store = FakeContactStore(contacts: [
            Fixtures.detail(id: "id-long", displayName: "Long \(long)", organization: exact),
            Fixtures.detail(id: "id-short", displayName: "Short Notreal"),
        ])
        let result = await Self.call(ToolCatalog.allName, store: store)
        #expect(
            result.text.hasPrefix(
                "A long value is clipped to \(ToolCatalog.cellWidth) characters in each row. Read one in full with contacts_get.\n\n2 contacts"))
        #expect(!result.text.contains(long))
        #expect(result.text.contains("Long " + String(repeating: "x", count: ToolCatalog.cellWidth - 6) + "…  "))
        // A value exactly as wide as a row allows is left alone.
        #expect(result.text.contains("[\(exact)]"))

        let short = await Self.call(ToolCatalog.allName, ["offset": 1], store: store)
        #expect(!short.text.contains("is clipped"))
    }

    @Test("A name holding a line break still takes one row")
    func namesStayOnOneLine() async {
        let store = FakeContactStore(contacts: [
            Fixtures.detail(id: "id-two", displayName: "Two\nLines Notreal")
        ])
        let result = await Self.call(ToolCatalog.allName, ["compact": true], store: store)
        #expect(result.text.contains("Two Lines Notreal  id=id-two"))
    }

    @Test("A full page fits a result even when every value of every row is as wide as a row allows")
    func fullPageAtTheCapFits() async {
        let wide = String(repeating: "w", count: 1000)
        let maximum = ToolCatalog.contactLimitRange.upperBound
        let contacts = (0..<maximum + 5).map {
            Fixtures.detail(
                id: Self.contactID($0), displayName: "Row \(Self.padded($0)) \(wide)", organization: wide,
                phones: [LabelledValue(label: nil, value: wide)],
                emails: [LabelledValue(label: nil, value: wide)])
        }
        let people = await Self.call(
            ToolCatalog.allName, ["limit": .int(maximum)], store: FakeContactStore(contacts: contacts))
        #expect(
            people.text.hasPrefix(
                "Showing 1–\(maximum) of \(maximum + 5) contacts. Pass offset=\(maximum) for the next page.\nA long value is clipped"))
        #expect(people.text.utf16.count <= ToolStandard.longestResult)

        let most = ToolCatalog.listLimitRange.upperBound
        let store = FakeContactStore(
            lists: (0..<most + 5).map {
                ContactList(
                    id: Self.listID($0), name: "List \(Self.padded($0)) \(wide)", accountName: wide,
                    memberCount: 123_456)
            },
            accounts: (0..<most + 5).map {
                ContactAccount(id: "account-\($0)", name: "Account \(Self.padded($0)) \(wide)", kind: .exchange, isDefault: true)
            })
        let lists = await Self.call(ToolCatalog.listsName, ["limit": .int(most)], store: store)
        #expect(
            lists.text.hasPrefix(
                """
                Showing 1–\(most) of \(most + 5) lists. Pass offset=\(most) for the next page.
                Showing 1–\(most) of \(most + 5) accounts. Pass offset=\(most) for the next page.
                A long value is clipped
                """))
        #expect(lists.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        // Eight UTF-16 units to the character: a row of values at their widest is then
        // several times longer than its count of characters says.
        let wide = String(repeating: "👩‍👩‍👧", count: 100)
        let maximum = ToolCatalog.contactLimitRange.upperBound
        let contacts = (0..<maximum).map {
            Fixtures.detail(
                id: Self.contactID($0), displayName: "Row \(Self.padded($0)) \(wide)", organization: wide,
                phones: [LabelledValue(label: nil, value: wide)],
                emails: [LabelledValue(label: nil, value: wide)])
        }
        var offset = 0
        var seen: [Int] = []
        while offset < contacts.count {
            let result = await Self.call(
                ToolCatalog.allName, ["limit": .int(maximum), "offset": .int(offset)],
                store: FakeContactStore(contacts: contacts))
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = (0..<contacts.count).filter { result.text.contains("id=\(Self.contactID($0))") }
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < maximum)
            let next = last + 1 < contacts.count ? "Pass offset=\(last + 1) for the next page." : "That is all."
            #expect(result.text.hasPrefix("Showing \(offset + 1)–\(last + 1) of \(maximum) contacts. \(next)\nA long value is clipped"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<contacts.count))
    }

    // MARK: The window on one contact's record

    private static func noted(_ note: String) -> FakeContactStore {
        FakeContactStore(contacts: [
            Fixtures.detail(
                id: "id-noted", displayName: "Noted Notreal", givenName: "Noted",
                familyName: "Notreal", phones: [LabelledValue(label: "mobile", value: "+34 600 000 003")],
                note: note)
        ])
    }

    private static let longNote = (0..<900).map { "Invented line \(padded($0)) of a note about nobody." }
        .joined(separator: "\n")

    /// The record `contacts_get` windows, as the store hands the contact over.
    private static func wholeRecord(_ store: FakeContactStore, id: String = "id-noted") async throws -> String {
        Format.record(try #require(try await store.fetch(id: id)))
    }

    private func record(_ extra: [String: Value] = [:], note: String = longNote) async -> ToolResult {
        await Self.call(
            ToolCatalog.getName, ["id": "id-noted"].merging(extra) { _, new in new }, store: Self.noted(note))
    }

    /// What follows the notices: the window itself.
    private func window(_ text: String) -> String {
        guard text.hasPrefix("Record: characters") || text.contains(" is outside "),
            let gap = text.range(of: "\n\n")
        else { return text }
        return String(text[gap.upperBound...])
    }

    @Test("A long record comes as one default window, announced before the data, with the id in it")
    func defaultWindow() async throws {
        let whole = try await Self.wholeRecord(Self.noted(Self.longNote))
        let size = ToolCatalog.defaultMaxCharacters
        #expect(whole.count > size)
        let result = await record()
        #expect(
            result.text.hasPrefix(
                "Record: characters 1–\(size) of \(whole.count). Pass character_offset=\(size) for the rest.\n\nNoted Notreal\n"))
        #expect(window(result.text) == String(whole.prefix(size)))
        // Everything but the note comes before the note, so the first window holds it.
        #expect(result.text.contains("id     id-noted\n"))
        #expect(result.text.contains("+34 600 000 003 (mobile)"))
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole record")
    func windowsChain() async throws {
        let whole = try await Self.wholeRecord(Self.noted(Self.longNote))
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await record(["character_offset": .int(offset), "max_characters": 7000])
            let part = window(result.text)
            let last = offset + part.count
            let next = last < whole.count ? "Pass character_offset=\(last) for the rest." : "That is all."
            #expect(result.text.hasPrefix("Record: characters \(offset + 1)–\(last) of \(whole.count). \(next)\n\n"))
            #expect(part.count == min(7000, whole.count - offset))
            joined += part
            offset = last
        }
        #expect(joined == whole)
    }

    @Test("A record that fits one window carries no notice")
    func shortRecordHasNoNotice() async throws {
        let result = await record(note: "Invented note")
        #expect(!result.text.contains("Record: characters"))
        #expect(result.text == (try await Self.wholeRecord(Self.noted("Invented note"))))
        #expect(result.text.hasSuffix("note   Invented note"))
    }

    @Test("max_characters at its maximum is used as asked; one past either end is moved and reported")
    func windowSizeBounds() async throws {
        let whole = try await Self.wholeRecord(Self.noted(Self.longNote))
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        #expect(whole.count > maximum)

        let atMaximum = await record(["max_characters": .int(maximum)])
        #expect(!atMaximum.text.contains("is outside"))
        #expect(window(atMaximum.text).count == maximum)
        #expect(atMaximum.text.utf16.count <= ToolStandard.longestResult)

        let over = await record(["max_characters": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nRecord: characters 1–\(maximum) of "))
        #expect(window(over.text).count == maximum)

        let under = await record(["max_characters": 0])
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(maximum); 1 was used.\nRecord: characters 1–1 of "))
        #expect(window(under.text) == "N")
    }

    @Test("character_offset past the end returns no text and says so; a negative one is moved to zero")
    func windowOffsetEdges() async throws {
        let whole = try await Self.wholeRecord(Self.noted(Self.longNote))
        let past = await record(["character_offset": .int(whole.count + 50)])
        #expect(
            past.text
                == "Record: characters 0 of \(whole.count): character_offset=\(whole.count + 50) is past the end. That is all.\n\n")

        let negative = await record(["character_offset": -3])
        let range = ToolCatalog.offsetRange
        #expect(
            negative.text.hasPrefix(
                "character_offset=-3 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\nRecord: characters 1–"))
    }

    @Test("A window of characters that take several UTF-16 units each still fits a result, and still chains")
    func windowOfWideCharacters() async throws {
        // Eight UTF-16 units to the character: a full window would be four results long.
        let note = String(repeating: "👩‍👩‍👧", count: 30_000)
        let whole = try await Self.wholeRecord(Self.noted(note))
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await record(
                ["character_offset": .int(offset), "max_characters": .int(maximum)], note: note)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let part = window(result.text)
            #expect(!part.isEmpty && part.count < maximum)
            let last = offset + part.count
            #expect(result.text.hasPrefix("Record: characters \(offset + 1)–\(last) of \(whole.count). "))
            joined += part
            offset = last
        }
        #expect(joined == whole)
    }

    // MARK: The photo

    private static func dimensions(of data: Data) throws -> (width: Int, height: Int, type: String) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            try #require(properties[kCGImagePropertyPixelWidth] as? Int),
            try #require(properties[kCGImagePropertyPixelHeight] as? Int),
            try #require(CGImageSourceGetType(source) as String?)
        )
    }

    @Test("A photo larger than a result may carry is reduced, and a small one is not enlarged")
    func photoIsReduced() throws {
        let large = try #require(ContactPhoto.reduced(try Fixtures.picture(width: 3000, height: 2000)))
        let reduced = try Self.dimensions(of: large)
        #expect(reduced.width == ContactPhoto.longestSide && reduced.height < ContactPhoto.longestSide)
        #expect(reduced.type == UTType.jpeg.identifier)
        #expect(large.count <= ContactPhoto.longestBytes)

        let small = try #require(ContactPhoto.reduced(try Fixtures.picture(width: 40, height: 30)))
        let kept = try Self.dimensions(of: small)
        #expect(kept.width == 40 && kept.height == 30)
    }

    @Test("Bytes that are not an image are not passed on as one")
    func photoThatIsNotAnImage() async {
        #expect(ContactPhoto.reduced(Data("not an image".utf8)) == nil)
        #expect(ContactPhoto.reduced(Data()) == nil)

        let store = FakeContactStore(contacts: [
            Fixtures.detail(id: "id-pic", displayName: "Pixel Imaginary", photo: PhotoInfo(thumbnailByteCount: 12))
        ])
        store.photos["id-pic"] = Data("not an image".utf8)
        let result = await Self.call(ToolCatalog.getName, ["id": "id-pic", "include_photo": true], store: store)
        #expect(!result.isError)
        #expect(result.content.count == 1)
        // What was asked for and is not there is said before the record, not after it.
        #expect(result.text.hasPrefix("The stored photo (12 bytes) is not returned: "))

        let none = await Self.call(
            ToolCatalog.getName, ["id": "id-noted", "include_photo": true], store: Self.noted("Invented note"))
        #expect(none.text.hasPrefix("No photo is stored for this contact.\n\nNoted Notreal\n"))
    }

    @Test("include_photo adds one image inside the bounds, whatever window of the record is asked for")
    func photoComesWithAnyWindow() async throws {
        let store = Self.noted(Self.longNote)
        store.contacts[0] = Fixtures.detail(
            id: "id-noted", displayName: "Noted Notreal", photo: PhotoInfo(thumbnailByteCount: 2048),
            note: Self.longNote)
        store.photos["id-noted"] = try Fixtures.picture(width: 2400, height: 3200, type: .jpeg)
        let result = await Self.call(
            ToolCatalog.getName, ["id": "id-noted", "include_photo": true, "character_offset": 500],
            store: store)
        #expect(result.text.hasPrefix("Record: characters 501–"))
        let images = result.content.compactMap { block -> Data? in
            guard case .image(let data, let mimeType) = block, mimeType == "image/jpeg" else { return nil }
            return Data(base64Encoded: data)
        }
        #expect(images.count == ToolCatalog.photosPerCall)
        #expect(result.content.count == 2)
        let size = try Self.dimensions(of: try #require(images.first))
        #expect(size.height == ContactPhoto.longestSide)
        #expect(try #require(images.first).count <= ContactPhoto.longestBytes)
    }

    // MARK: What a write shows of what it wrote

    private static let receiptNotice = """
        character_offset is an argument of contacts_get: pass it there, with this id, to \
        read the rest of the record.
        """

    @Test("A write shows the start of a long record, and contacts_get resumes exactly where it stopped")
    func receiptsStopWhereContactsGetResumes() async throws {
        let store = FakeContactStore()
        let created = await Self.call(
            ToolCatalog.createName, ["given_name": "Wordy", "note": .string(Self.longNote)], store: store)
        let id = try #require(store.contacts.first?.id)
        let whole = try await Self.wholeRecord(store, id: id)
        let size = ToolCatalog.receiptCharacters
        #expect(whole.count > size)
        let heading =
            "Record: characters 1–\(size) of \(whole.count). Pass character_offset=\(size) for the rest.\n\(Self.receiptNotice)\n\nCreated contact 'Wordy' (id=\(id)).\n\n"
        #expect(created.text.hasPrefix(heading))
        #expect(created.text.utf16.count <= ToolStandard.longestResult)
        let shown = String(created.text.dropFirst(heading.count).prefix(size))
        #expect(shown == String(whole.prefix(size)))

        let rest = await Self.call(
            ToolCatalog.getName,
            ["id": .string(id), "character_offset": .int(size), "max_characters": .int(ToolCatalog.maxCharactersRange.upperBound)],
            store: store)
        #expect(shown + window(rest.text) == String(whole.prefix(size + ToolCatalog.maxCharactersRange.upperBound)))

        let updated = await Self.call(
            ToolCatalog.updateName, ["id": .string(id), "organization": "Fictitious Ltd"], store: store)
        #expect(updated.text.hasPrefix("Record: characters 1–\(size) of "))
        #expect(updated.text.contains("\n\(Self.receiptNotice)\n\nUpdated contact 'Wordy' (id=\(id)). Fields changed: organization.\n\n"))
        #expect(updated.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("A write of a short record shows all of it and carries no notice")
    func shortReceiptsHaveNoNotice() async {
        let store = FakeContactStore()
        let created = await Self.call(
            ToolCatalog.createName, ["given_name": "Brief", "note": "Invented note"], store: store)
        #expect(created.text.hasPrefix("Created contact 'Brief' (id=new-1).\n\nBrief\n"))
        #expect(created.text.hasSuffix("note Invented note\n\n  lists   (none — pass lists: [...] to add it to one)"))
        #expect(!created.text.contains("character_offset"))
    }

    @Test("A delete shows as much of the record as a result holds, and says first when that is not all of it")
    func deleteReceiptIsBounded() async throws {
        let note = String(repeating: "Invented line of a note about nobody.\n", count: 2000)
        let store = Self.noted(note)
        let whole = try await Self.wholeRecord(store)
        let size = ToolCatalog.deleteReceiptCharacters
        #expect(whole.count > size)
        let result = await Self.call(ToolCatalog.deleteName, ["id": "id-noted", "confirm": true], store: store)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "The record was \(whole.count) characters long and only the first \(size) are below. The rest was deleted with the contact and cannot be read again.\n\nDeleted contact 'Noted Notreal'.\n\n"))
        #expect(result.text.contains(String(whole.prefix(size))))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        // The call that would recreate it would repeat the note, so it is not spelled out.
        #expect(!result.text.contains("create_contact("))
        #expect(result.text.contains("To recreate it, pass the fields above to create_contact"))

        let short = Self.noted("Invented note")
        let all = await Self.call(ToolCatalog.deleteName, ["id": "id-noted", "confirm": true], store: short)
        #expect(all.text.hasPrefix("Deleted contact 'Noted Notreal'.\n\nNoted Notreal\n"))
        #expect(all.text.contains("create_contact(given_name=\"Noted\", family_name=\"Notreal\", phones=[\"+34 600 000 003\"], note=\"Invented note\")"))
    }

    @Test("A membership receipt names a few lists and counts the others")
    func membershipReceiptIsBounded() async {
        let count = ToolCatalog.fewNames + 5
        let lists = (0..<count).map {
            ContactList(id: "list-\($0)", name: "Invented List \(Self.padded($0))", accountName: nil, memberCount: 0)
        }
        let store = FakeContactStore(
            contacts: [Fixtures.detail(id: "id-joiner", displayName: "Joiner Notreal")], lists: lists)
        let result = await Self.call(
            ToolCatalog.updateListsName,
            ["id": "id-joiner", "add": .array(lists.map { .string($0.name) })], store: store)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(ToolCatalog.fewNames) of \(count) lists. contacts_get shows every list the contact is in.\n\n'Joiner Notreal' added to "))
        #expect(result.text.contains("Invented List \(Self.padded(ToolCatalog.fewNames - 1)) and 5 more"))
        #expect(!result.text.contains("Invented List \(Self.padded(ToolCatalog.fewNames))"))

        let few = await Self.call(
            ToolCatalog.updateListsName, ["id": "id-joiner", "remove": [.string(lists[0].name)]],
            store: FakeContactStore(
                contacts: [Fixtures.detail(id: "id-joiner", displayName: "Joiner Notreal")], lists: lists))
        #expect(few.text.hasPrefix("'Joiner Notreal' removed from Invented List 0000."))

        let wide = ContactList(
            id: "list-wide", name: "Invented " + String(repeating: "w", count: 100), accountName: nil,
            memberCount: 0)
        let clipped = await Self.call(
            ToolCatalog.updateListsName, ["id": "id-joiner", "add": ["list-wide"]],
            store: FakeContactStore(
                contacts: [Fixtures.detail(id: "id-joiner", displayName: "Joiner Notreal")], lists: [wide]))
        #expect(
            clipped.text.hasPrefix(
                "A long name is clipped to \(ToolCatalog.cellWidth) characters in each row. Read one in full with contacts_get.\n\n'Joiner Notreal' added to list-wide."))
        #expect(!clipped.text.contains(wide.name))

        let long = String(repeating: "n", count: 5000)
        let refused = await Self.call(
            ToolCatalog.updateListsName, ["id": "id-joiner", "add": [.string(long)]], store: store)
        #expect(refused.isError)
        #expect(refused.text.count < 400)
    }

    // MARK: A search that ran out of time

    @Test("A search whose scan ran out of time says so first, and how to ask without one")
    func partialSearchIsAnnounced() async {
        let store = Self.people(3)
        store.scanStoppedAfter = 1200
        let found = await Self.call(ToolCatalog.searchName, ["query": "Invented"], store: store)
        #expect(
            found.text.hasPrefix(
                "Partial: the time limit was reached after 1200 contacts. Narrow by query: a name, an email address or a phone number is found without the scan.\n\n3 contacts matching"))

        let none = await Self.call(ToolCatalog.searchName, ["query": "Absent"], store: store)
        #expect(none.text.hasPrefix("Partial: the time limit was reached after 1200 contacts."))
        #expect(none.text.hasSuffix("No contacts match 'Absent' among those looked at."))
    }

    // MARK: Numbers moved, values refused

    @Test("A wrong type is refused with the form expected")
    func wrongTypesAreRefused() async {
        let cases: [(tool: String, arguments: [String: Value], expected: String)] = [
            (ToolCatalog.searchName, ["query": "x", "limit": "ten"], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["query": "x", "limit": 2.5], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["query": "x", "offset": true], "Argument 'offset' is not valid: a whole number was expected"),
            (ToolCatalog.searchName, ["query": 5], "Argument 'query' is not valid: text was expected"),
            (ToolCatalog.allName, ["list": ["Family"]], "Argument 'list' is not valid: text was expected"),
            (ToolCatalog.allName, ["compact": "yes"], "Argument 'compact' is not valid: true or false was expected"),
            (ToolCatalog.listsName, ["limit": [1]], "Argument 'limit' is not valid"),
            (ToolCatalog.getName, ["id": 7], "Argument 'id' is not valid: text was expected"),
            (ToolCatalog.getName, ["id": "id-aurora", "include_photo": 1], "true or false was expected"),
            (ToolCatalog.getName, ["id": "id-aurora", "max_characters": "all"], "Argument 'max_characters' is not valid"),
            (ToolCatalog.getName, ["id": "id-aurora", "character_offset": "start"], "Argument 'character_offset' is not valid"),
            (ToolCatalog.createName, ["given_name": 3], "Argument 'given_name' is not valid: text was expected"),
            (ToolCatalog.createName, ["given_name": "A", "phones": "600"], "Argument 'phones' is not valid: an array was expected"),
            (ToolCatalog.createName, ["given_name": "A", "phones": [["value": 600]]], "\"value\" must be text in every item"),
            (ToolCatalog.createName, ["given_name": "A", "phones": [["value": "600", "label": 1]]], "\"label\" must be text in every item"),
            (ToolCatalog.createName, ["given_name": "A", "addresses": [["city": 5]]], "\"city\" must be text in every item"),
            (ToolCatalog.updateName, ["id": "id-aurora", "job_title": 5], "Argument 'job_title' is not valid: text was expected"),
            (ToolCatalog.updateName, ["id": "id-aurora", "birthday": 19900314], "Argument 'birthday' is not valid: text was expected"),
            (ToolCatalog.deleteName, ["id": "id-aurora", "confirm": "true"], "Argument 'confirm' is not valid: true or false was expected"),
        ]
        for (tool, arguments, expected) in cases {
            let store = Fixtures.populated()
            let result = await Self.call(tool, arguments, store: store)
            #expect(result.isError, "\(tool) \(arguments)")
            #expect(result.text.contains(expected), "\(tool) \(arguments): \(result.text)")
            // A refused call changes nothing.
            #expect(store.contacts == Fixtures.sample, "\(tool) \(arguments)")
        }
    }

    @Test("A whole number sent as 20.0 is taken as 20, and a null as not given")
    func lenientForms() async {
        let result = await Self.everyone.call(30, ["limit": 20.0, "offset": .null, "list": .null, "compact": .null])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Showing 1–20 of 30 contacts."))
    }

    @Test("A date that does not exist is refused with the form expected")
    func impossibleDatesAreRefused() async {
        for date in ["2023-02-29", "2024-02-30", "2023-04-31", "2023-13-01", "2023-00-10", "--02-30", "--04-31", "--13-01", "0000-01-01"] {
            let store = FakeContactStore()
            let result = await Self.call(
                ToolCatalog.createName, ["given_name": "Datum", "birthday": .string(date)], store: store)
            #expect(result.isError, "\(date)")
            #expect(result.text.contains("Argument 'birthday' is not valid: expected "), "\(date)")
            #expect(store.contacts.isEmpty, "\(date)")
        }
        for date in ["2024-02-29", "--02-29", "1990-03-14", "--12-31"] {
            let result = await Self.call(
                ToolCatalog.createName, ["given_name": "Datum", "dates": [.string(date)]], store: FakeContactStore())
            #expect(!result.isError, "\(date)")
        }
    }

    // MARK: Errors and time

    @Test("An error repeats at most a short piece of what the caller sent")
    func errorsClipWhatTheyEcho() async {
        let long = String(repeating: "n", count: 5000)
        let clipped = String(repeating: "n", count: ToolStandard.echoWidth) + "…"
        let cases: [(tool: String, arguments: [String: Value])] = [
            (long, [:]),
            (ToolCatalog.getName, ["id": .string(long)]),
            (ToolCatalog.updateName, ["id": .string(long), "nickname": "Nobody"]),
            (ToolCatalog.deleteName, ["id": .string(long), "confirm": true]),
            (ToolCatalog.allName, ["list": .string(long)]),
            (ToolCatalog.createName, ["given_name": "A", "lists": [.string(long)]]),
        ]
        for (tool, arguments) in cases {
            let result = await Self.call(tool, arguments, store: Fixtures.populated())
            #expect(result.isError, "\(tool.prefix(20))")
            #expect(result.text.contains(clipped), "\(tool.prefix(20)): \(result.text.prefix(200))")
            #expect(!result.text.contains(long), "\(tool.prefix(20))")
            #expect(result.text.count < ToolStandard.echoWidth + 400, "\(tool.prefix(20))")
        }
        // A search that finds nothing repeats the query in a result, not an error: clipped too.
        let none = await Self.call(ToolCatalog.searchName, ["query": .string(long)], store: Fixtures.populated())
        #expect(none.text == "No contacts match '\(clipped)'.")
    }

    @Test("Every error this server words is inside the longest error, whatever Contacts said")
    func errorsAreBounded() {
        let long = String(repeating: "e", count: 50_000)
        let wide = String(repeating: "👩‍👩‍👧", count: 20_000)
        let errors: [ToolError] = [
            .notAuthorized(.denied), .notAuthorized(.notDetermined), .notAuthorized(.restricted),
            .missingArgument("id"), .badArgument(name: "limit", reason: "a whole number was expected"),
            .unknownTool(long), .notFound(id: long), .listNotFound(long),
            .confirmationRequired(action: "Deleting a contact"), .emptyContact, .nothingToUpdate,
            .emptyListChange, .storeFailure(long), .storeFailure(wide), .noteFailure(long),
            .noteFailure(wide), .contactsAppUnsaved, .contactsAppSaveFailed, .photoWritesDisabled,
            .timedOut(seconds: 180, wrote: true), .timedOut(seconds: 180, wrote: false),
        ]
        for error in errors {
            #expect(error.message.utf16.count <= ToolStandard.longestError, "\(Diagnostics.kind(of: error))")
        }
        #expect(ToolError.storeFailure(long).message.hasSuffix("… (\(50_000 - ToolError.detailLimit) more characters not shown)"))
        #expect(ToolError.clipped("short") == "short")
        #expect(ToolError.clipped(wide, to: 20).unicodeScalars.first == "👩")
        #expect(ToolError.diagnosticLimit * 2 < ToolError.detailLimit)
    }

    @Test("An error names only a few custom services, and counts the others")
    func unsupportedServicesAreCounted() {
        var changes = ContactChanges()
        changes.instantMessages = .set((0..<12).map {
            InstantMessage(label: nil, service: "Invented Service \($0)", username: "nobody")
        })
        let unsupported = ContactsAppScripting.unsupportedFields(in: changes)
        #expect(unsupported.count == 1)
        #expect(unsupported.first?.hasSuffix("Invented Service 4 and 7 more)") == true)
    }

    @Test("The deadline of a call, and the scan inside it, are within the standard's time limit")
    func deadlineIsWithinTheTimeLimit() {
        #expect(ContactTools.defaultTimeout < ToolStandard.timeLimit)
        #expect(ToolCatalog.scanTimeLimit < ContactTools.defaultTimeout)
    }

    @Test("A read that does not finish in time is abandoned and answered with an error that says so")
    func slowReadIsAbandoned() async {
        let store = Fixtures.populated()
        store.readDelay = .seconds(30)
        let result = await Self.call(ToolCatalog.allName, store: store, timeout: .milliseconds(50))
        #expect(result.isError)
        #expect(result.text.contains("did not finish within 0 seconds and was abandoned. Nothing was changed."))
    }

    @Test("A write that passes its deadline says its outcome is unknown, and makes no further change")
    func slowWriteStopsAtTheDeadline() async throws {
        let store = Fixtures.populated()
        store.membershipDelay = .milliseconds(400)
        let result = await Self.call(
            ToolCatalog.updateListsName,
            ["id": "id-cecilia", "add": ["Invented Kin", "Imaginary Work"]], store: store,
            timeout: .milliseconds(100))
        #expect(result.isError)
        #expect(result.text.contains("so its outcome is not known"))
        #expect(result.text.contains("contacts_get"))

        // The change that was already with the store lands; the one after it never starts.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(store.members["list-kin"]?.contains("id-cecilia") == true)
        #expect(store.members["list-work"]?.contains("id-cecilia") == false)
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsAreWithinTheLimit() {
        #expect(
            ToolStandard.overlongTexts(instructions: ContactsMCPServer.instructions, catalog: ToolCatalog.all())
                .isEmpty)
        #expect(!ContactsMCPServer.instructions.isEmpty)
    }

    @Test("The instructions state the deadline the code enforces")
    func instructionsStateTheDeadline() {
        #expect(
            ContactsMCPServer.instructions.contains(
                "after \(ContactTools.defaultTimeout.components.seconds) seconds"))
    }

    private func properties(of tool: Tool) -> [String: [String: Value]] {
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [:] }
        return properties.compactMapValues(\.objectValue)
    }

    @Test("Every listing's schema states the range and default of limit and offset that the code enforces", arguments: listings)
    private func schemaStatesThePage(_ listing: Listing) throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == listing.tool })
        let limit = try #require(properties(of: tool)["limit"])
        #expect(limit["minimum"]?.intValue == listing.limits.lowerBound)
        #expect(limit["maximum"]?.intValue == listing.limits.upperBound)
        #expect(limit["default"]?.intValue == listing.defaultLimit)
        let offset = try #require(properties(of: tool)["offset"])
        #expect(offset["minimum"]?.intValue == ToolCatalog.offsetRange.lowerBound)
        #expect(offset["maximum"]?.intValue == ToolCatalog.offsetRange.upperBound)
        #expect(offset["default"]?.intValue == 0)
        // The description states the same maximum, taken from the same constant.
        #expect(tool.description?.contains("limit (up to \(listing.limits.upperBound))") == true)
        #expect(tool.description?.contains("\(listing.defaultLimit)") == true)
    }

    @Test("The window's schema and description state the range and default the code enforces")
    func schemaStatesTheWindow() throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.getName })
        let size = try #require(properties(of: tool)["max_characters"])
        #expect(size["minimum"]?.intValue == ToolCatalog.maxCharactersRange.lowerBound)
        #expect(size["maximum"]?.intValue == ToolCatalog.maxCharactersRange.upperBound)
        #expect(size["default"]?.intValue == ToolCatalog.defaultMaxCharacters)
        #expect(ToolCatalog.defaultMaxCharacters == ToolStandard.usualPage)
        let offset = try #require(properties(of: tool)["character_offset"])
        #expect(offset["minimum"]?.intValue == 0 && offset["default"]?.intValue == 0)
        #expect(tool.description?.contains("more than \(ToolCatalog.defaultMaxCharacters) characters") == true)
        #expect(tool.description?.contains("max_characters (up to \(ToolCatalog.maxCharactersRange.upperBound))") == true)
        #expect(tool.description?.contains("at most \(ContactPhoto.longestSide) pixels") == true)
    }

    @Test("The write tools state the size of the receipt the code returns")
    func descriptionsStateTheReceipts() throws {
        func description(_ name: String) throws -> String {
            try #require(ToolCatalog.all().first { $0.name == name }?.description)
        }
        #expect(try description(ToolCatalog.createName).contains("up to \(ToolCatalog.receiptCharacters) characters"))
        #expect(try description(ToolCatalog.updateName).contains("up to \(ToolCatalog.receiptCharacters) characters"))
        #expect(try description(ToolCatalog.deleteName).contains("up to \(ToolCatalog.deleteReceiptCharacters) characters"))
        #expect(try description(ToolCatalog.updateListsName).contains("the first \(ToolCatalog.fewNames) by name"))
        #expect(try description(ToolCatalog.searchName).contains("at most \(ToolCatalog.scanTimeLimit.components.seconds) seconds"))
    }

    @Test("Every number in a schema has a range, and every default lies inside it")
    func everyNumberHasARange() {
        for tool in ToolCatalog.all() {
            for (name, property) in properties(of: tool) where property["type"]?.stringValue == "integer" {
                guard let minimum = property["minimum"]?.intValue, let maximum = property["maximum"]?.intValue
                else {
                    Issue.record("\(tool.name).\(name) states no range")
                    continue
                }
                if let value = property["default"]?.intValue {
                    #expect((minimum...maximum).contains(value), "\(tool.name).\(name)")
                }
            }
        }
    }

    @Test("Only the standard names page and window a result")
    func standardArgumentNames() {
        let standard: Set = ["limit", "offset", "character_offset", "max_characters"]
        let lookalikes: Set = [
            "max", "count", "max_results", "page", "page_size", "skip", "start", "from", "to",
            "max_chars", "max_length", "char_offset", "cursor",
        ]
        var used: Set<String> = []
        for tool in ToolCatalog.all() {
            let names = Set(properties(of: tool).keys)
            #expect(names.isDisjoint(with: lookalikes), "\(tool.name)")
            used.formUnion(names.intersection(standard))
        }
        #expect(used == standard)
    }
}
