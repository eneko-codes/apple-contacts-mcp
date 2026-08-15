import Foundation
import MCP
import Testing

@testable import ContactsMCPCore

/// Covers what the address book gained: enumeration, Lists, and the Contacts fields
/// that were previously fetched by nothing. Same rule as the rest of the suite — every
/// name here is invented and no test reaches a real address book.
@Suite("Lists and fields")
struct ListsAndFieldsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeContactStore = Fixtures.populated()
    ) async -> (text: String, isError: Bool) {
        let result = await ContactTools(store: store)
            .handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    private func content(
        _ name: String, _ arguments: [String: Value] = [:], store: FakeContactStore
    ) async -> [Tool.Content] {
        await ContactTools(store: store).handle(.init(name: name, arguments: arguments)).content
    }

    // MARK: contacts_all

    @Test("Listing everyone needs no search term and reports the total")
    func listsTheWholeAddressBook() async {
        let answer = await call(ToolCatalog.allName)
        #expect(!answer.isError)
        #expect(answer.text.hasPrefix("3 contacts"))
        for name in ["Aurora Fakeperson", "Basil Sampleton", "Cecily Madeup"] {
            #expect(answer.text.contains(name))
        }
    }

    @Test("Listing is filtered to one list by name")
    func filtersByListName() async {
        let answer = await call(ToolCatalog.allName, ["list": .string("Imaginary Work")])
        #expect(answer.text.hasPrefix("2 contacts in 'Imaginary Work'"))
        #expect(answer.text.contains("Aurora Fakeperson"))
        #expect(answer.text.contains("Basil Sampleton"))
        #expect(!answer.text.contains("Cecily Madeup"))
    }

    @Test("Listing is filtered to one list by id")
    func filtersByListIdentifier() async {
        let answer = await call(ToolCatalog.allName, ["list": .string("list-kin")])
        #expect(answer.text.contains("Aurora Fakeperson"))
        #expect(!answer.text.contains("Basil Sampleton"))
    }

    @Test("An unknown list is refused with a pointer to contacts_lists")
    func unknownListIsRefused() async {
        let answer = await call(ToolCatalog.allName, ["list": .string("Nonexistent")])
        #expect(answer.isError)
        #expect(answer.text.contains("contacts_lists"))
    }

    /// The whole point of compact mode is that a large page stays affordable.
    @Test("Compact mode prints names and ids and nothing else")
    func compactModeDropsTheDetailColumns() async {
        let answer = await call(ToolCatalog.allName, ["compact": .bool(true)])
        #expect(answer.text.contains("Aurora Fakeperson"))
        #expect(answer.text.contains("id=id-aurora"))
        #expect(!answer.text.contains("+34 600 000 001"))
        #expect(!answer.text.contains("Fictitious Ltd"))
    }

    @Test("A truncated listing announces what it withheld")
    func truncatedListingSaysSo() async {
        let answer = await call(ToolCatalog.allName, ["limit": .int(2)])
        #expect(answer.text.contains("1 more"))
        #expect(answer.text.contains("offset=2"))
    }

    @Test("An empty address book says so rather than printing a bare heading")
    func emptyAddressBookSaysSo() async {
        let answer = await call(ToolCatalog.allName, store: FakeContactStore())
        #expect(answer.text == "The address book is empty.")
    }

    // MARK: contacts_lists

    @Test("Lists are reported with their member counts and accounts")
    func listsAreReported() async {
        let answer = await call(ToolCatalog.listsName)
        #expect(answer.text.hasPrefix("2 lists"))
        #expect(answer.text.contains("Invented Kin"))
        #expect(answer.text.contains("1 person"))
        #expect(answer.text.contains("2 people"))
        #expect(answer.text.contains("[Nowhere]"))
        #expect(answer.text.contains("new contacts go here"))
    }

    /// The fixture deliberately holds them the other way round: ordering is the
    /// formatter's job, so the fake and the real store cannot disagree about it.
    @Test("Lists are ordered by name regardless of the order the store returned them")
    func listsAreOrdered() async throws {
        let answer = await call(ToolCatalog.listsName)
        let work = try #require(answer.text.range(of: "Imaginary Work"))
        let kin = try #require(answer.text.range(of: "Invented Kin"))
        #expect(work.lowerBound < kin.lowerBound)
    }

    @Test("An address book with no lists says so")
    func noListsSaysSo() async {
        let answer = await call(ToolCatalog.listsName, store: FakeContactStore())
        #expect(answer.text.contains("No lists"))
    }

    // MARK: update_contact_lists

    @Test("Adding to a list reports the membership that resulted")
    func addingToAListReportsMembership() async {
        let store = Fixtures.populated()
        let answer = await call(
            ToolCatalog.updateListsName,
            ["id": .string("id-cecilia"), "add": .array([.string("Invented Kin")])],
            store: store)
        #expect(!answer.isError)
        #expect(answer.text.contains("added to Invented Kin"))
        #expect(answer.text.contains("Invented Kin"))
        #expect(store.members["list-kin"]?.contains("id-cecilia") == true)
    }

    /// removeMember drops the membership and nothing else. Saying so in the output is
    /// what stops the tool reading like a deletion.
    @Test("Removing from a list says the contact itself was not changed")
    func removingFromAListKeepsTheContact() async {
        let store = Fixtures.populated()
        let answer = await call(
            ToolCatalog.updateListsName,
            ["id": .string("id-aurora"), "remove": .array([.string("Invented Kin")])],
            store: store)
        #expect(answer.text.contains("removed from Invented Kin"))
        #expect(answer.text.contains("The contact itself was not changed."))
        #expect(store.members["list-kin"]?.contains("id-aurora") == false)
        #expect(store.contacts.contains { $0.id == "id-aurora" })
    }

    @Test("Adding and removing in one call does both")
    func addAndRemoveTogether() async {
        let store = Fixtures.populated()
        _ = await call(
            ToolCatalog.updateListsName,
            [
                "id": .string("id-aurora"),
                "add": .array([.string("list-kin")]),
                "remove": .array([.string("Imaginary Work")]),
            ], store: store)
        #expect(store.members["list-work"]?.contains("id-aurora") == false)
        #expect(store.members["list-kin"]?.contains("id-aurora") == true)
    }

    @Test("Naming neither an addition nor a removal is refused")
    func emptyListChangeIsRefused() async {
        let answer = await call(ToolCatalog.updateListsName, ["id": .string("id-aurora")])
        #expect(answer.isError)
        #expect(answer.text.contains("contacts_lists"))
    }

    @Test("Changing lists on an unknown contact explains that ids go stale")
    func unknownContactIsRefused() async {
        let answer = await call(
            ToolCatalog.updateListsName,
            ["id": .string("id-nobody"), "add": .array([.string("Invented Kin")])])
        #expect(answer.isError)
        #expect(answer.text.contains("resynchronised"))
    }

    // MARK: create_contact with lists

    /// A contact created without a List is easy to lose track of, especially when the
    /// tool that would fix it afterwards has its own defects: this is the regression
    /// guard for a real session where every follow-up `update_contact_lists` call
    /// failed, leaving ten newly-created contacts with no visible sign anything was
    /// missing.
    @Test("create_contact adds the new contact to a List in the same call")
    func createAddsToListsImmediately() async {
        let store = Fixtures.populated()
        let answer = await call(
            ToolCatalog.createName,
            ["given_name": .string("Newcomer"), "lists": .array([.string("Invented Kin")])],
            store: store)
        #expect(!answer.isError)
        #expect(answer.text.contains("Invented Kin"))
        let created = store.contacts.last
        #expect(created?.givenName == "Newcomer")
        #expect(created.map { store.members["list-kin"]?.contains($0.id) } == true)
    }

    /// The whole point of BUG 3: a caller must be able to tell "created into no List"
    /// from "the lists argument was silently dropped". Omitting the row, which is what
    /// every other empty field does, reads as the second one.
    @Test("create_contact says explicitly when the new contact joins no List")
    func createStatesEmptyListsExplicitly() async {
        let answer = await call(
            ToolCatalog.createName, ["given_name": .string("Loner")], store: FakeContactStore())
        #expect(!answer.isError)
        #expect(answer.text.contains("none"))
    }

    @Test("create_contact with an unknown list is refused, and creates nothing")
    func createWithUnknownListIsRefused() async {
        let store = FakeContactStore()
        let answer = await call(
            ToolCatalog.createName,
            ["given_name": .string("Ghost"), "lists": .array([.string("Nonexistent")])],
            store: store)
        #expect(answer.isError)
        #expect(store.contacts.isEmpty, "a bad list name must not leave an orphaned contact")
    }

    // MARK: contacts_get

    @Test("A contact reports which lists it belongs to")
    func detailShowsListMembership() async {
        let answer = await call(ToolCatalog.getName, ["id": .string("id-aurora")])
        #expect(answer.text.contains("lists"))
        #expect(answer.text.contains("Imaginary Work"))
        #expect(answer.text.contains("Invented Kin"))
    }

    @Test("Every newly exposed field reaches the output")
    func detailShowsTheNewFields() async {
        let store = FakeContactStore(contacts: [
            Fixtures.detail(
                id: "id-zed", displayName: "Zenobia Notreal", kind: .organization,
                namePrefix: "Dra.", givenName: "Zenobia", familyName: "Notreal",
                nameSuffix: "PhD", phoneticGivenName: "Zeh-NOH-bee-ah",
                addresses: [
                    PostalAddress(
                        label: "home", street: "Calle Inventada 1", subLocality: "Gros",
                        city: "Donostia", subAdministrativeArea: "Gipuzkoa",
                        state: "Euskadi", postalCode: "20001", country: "Spain",
                        isoCountryCode: "ES")
                ],
                socialProfiles: [
                    SocialProfile(label: nil, service: "LinkedIn", username: "znotreal")
                ],
                instantMessages: [
                    InstantMessage(label: nil, service: "Skype", username: "zed.notreal")
                ],
                relations: [LabelledValue(label: "sister", value: "Aurora Fakeperson")],
                dates: [
                    LabelledDate(
                        label: "anniversary", components: DateComponents(month: 6, day: 1))
                ],
                photo: PhotoInfo(thumbnailByteCount: 2048),
                note: "Invented note")
        ])
        let answer = await call(ToolCatalog.getName, ["id": .string("id-zed")], store: store)

        #expect(answer.text.contains("organization"))
        #expect(answer.text.contains("Dra."))
        #expect(answer.text.contains("PhD"))
        #expect(answer.text.contains("Zeh-NOH-bee-ah"))
        #expect(answer.text.contains("Gros"))
        #expect(answer.text.contains("Gipuzkoa"))
        #expect(answer.text.contains("LinkedIn: znotreal"))
        #expect(answer.text.contains("Skype: zed.notreal"))
        #expect(answer.text.contains("Aurora Fakeperson (sister)"))
        #expect(answer.text.contains("01 Jun (anniversary)"))
        #expect(answer.text.contains("2 KB"))
        #expect(answer.text.contains("Invented note"))
    }

    /// A missing note is a permission story. Reading it as "this person has no note"
    /// is the failure this footnote exists to prevent.
    @Test("An unreadable note explains the permission rather than reading as absent")
    func missingNoteExplainsItself() async {
        let answer = await call(ToolCatalog.getName, ["id": .string("id-aurora")])
        #expect(answer.text.contains("Automation"))
        #expect(answer.text.contains("contacts_status"))
    }

    @Test("The photo comes back as an image only when asked for")
    func photoIsOptIn() async {
        let store = FakeContactStore(contacts: [
            Fixtures.detail(
                id: "id-pic", displayName: "Pixel Imaginary",
                photo: PhotoInfo(thumbnailByteCount: 12))
        ])
        store.photos["id-pic"] = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])

        let without = await content(ToolCatalog.getName, ["id": .string("id-pic")], store: store)
        #expect(without.count == 1)

        let with = await content(
            ToolCatalog.getName, ["id": .string("id-pic"), "include_photo": .bool(true)],
            store: store)
        guard case .image(let data, let mimeType, _, _) = with.last else {
            Issue.record("expected an image block")
            return
        }
        #expect(mimeType == "image/png")
        #expect(Data(base64Encoded: data) == store.photos["id-pic"])
    }

    @Test("Asking for a photo that does not exist says so instead of failing")
    func missingPhotoIsNotAnError() async {
        let answer = await call(
            ToolCatalog.getName, ["id": .string("id-cecilia"), "include_photo": .bool(true)])
        #expect(!answer.isError)
    }

    // MARK: New field parsing

    @Test("Dates accept a bare string or a labelled object, with or without a year")
    func datesParseBothShapes() async {
        let store = FakeContactStore()
        let answer = await call(
            ToolCatalog.createName,
            [
                "given_name": .string("Datum"),
                "dates": .array([
                    .string("2015-06-01"),
                    .object(["label": .string("anniversary"), "value": .string("--12-25")]),
                ]),
            ], store: store)
        #expect(!answer.isError)
        #expect(store.contacts.last?.dates.count == 2)
        #expect(store.contacts.last?.dates.first?.components.year == 2015)
        #expect(store.contacts.last?.dates.last?.components.year == nil)
        #expect(store.contacts.last?.dates.last?.label == "anniversary")
    }

    @Test("A date that is neither YYYY-MM-DD nor --MM-DD is refused by name")
    func malformedDateIsRefused() async {
        let answer = await call(
            ToolCatalog.createName,
            ["given_name": .string("Datum"), "dates": .array([.string("01/06/2015")])],
            store: FakeContactStore())
        #expect(answer.isError)
        #expect(answer.text.contains("dates"))
    }

    /// A custom service is the whole point of the service field being free-form text:
    /// `CNSocialProfile.service` and `CNInstantMessageAddress.service` are plain strings,
    /// and the owner's own address book carries GitHub, Revolut, Duolingo and Signal
    /// alongside the services Apple ships constants for. A validation rule that only
    /// admitted the known set would silently drop them.
    @Test("A service Apple has no constant for is carried through, not rejected")
    func customServicesSurvive() async {
        let store = FakeContactStore()
        let result = await call(
            ToolCatalog.createName,
            [
                "given_name": .string("Sociable"),
                "social_profiles": .array([
                    .object(["service": .string("GitHub"), "username": .string("someone")])
                ]),
                "instant_messages": .array([
                    .object(["service": .string("Signal"), "username": .string("someone")])
                ]),
            ], store: store)

        #expect(!result.isError)
        #expect(result.text.contains("GitHub"))
        #expect(result.text.contains("Signal"))
    }

    @Test("A social profile needs a service and something to identify the account")
    func socialProfileNeedsServiceAndHandle() async {
        let missingService = await call(
            ToolCatalog.createName,
            [
                "given_name": .string("Sociable"),
                "social_profiles": .array([.object(["username": .string("nobody")])]),
            ], store: FakeContactStore())
        #expect(missingService.isError)
        #expect(missingService.text.contains("service"))

        let missingHandle = await call(
            ToolCatalog.createName,
            [
                "given_name": .string("Sociable"),
                "social_profiles": .array([.object(["service": .string("LinkedIn")])]),
            ], store: FakeContactStore())
        #expect(missingHandle.isError)
        #expect(missingHandle.text.contains("username"))
    }

    @Test("An instant message handle needs both a service and a username")
    func instantMessageNeedsBoth() async {
        let answer = await call(
            ToolCatalog.createName,
            [
                "given_name": .string("Chatty"),
                "instant_messages": .array([.object(["service": .string("Skype")])]),
            ], store: FakeContactStore())
        #expect(answer.isError)
        #expect(answer.text.contains("username"))
    }

    @Test("An address needs at least one component")
    func addressNeedsSomething() async {
        let answer = await call(
            ToolCatalog.createName,
            [
                "given_name": .string("Homeless"),
                "addresses": .array([.object(["label": .string("home")])]),
            ], store: FakeContactStore())
        #expect(answer.isError)
        #expect(answer.text.contains("addresses"))
    }

    @Test("A postal address round-trips every component it was given")
    func addressKeepsEveryComponent() async {
        let store = FakeContactStore()
        _ = await call(
            ToolCatalog.createName,
            [
                "given_name": .string("Postal"),
                "addresses": .array([
                    .object([
                        "street": .string("Calle Inventada 2"),
                        "sub_locality": .string("Antiguo"),
                        "city": .string("Donostia"),
                        "sub_administrative_area": .string("Gipuzkoa"),
                        "state": .string("Euskadi"),
                        "postal_code": .string("20008"),
                        "country": .string("Spain"),
                        "iso_country_code": .string("ES"),
                        "label": .string("home"),
                    ])
                ]),
            ], store: store)
        let address = store.contacts.last?.addresses.first
        #expect(address?.subLocality == "Antiguo")
        #expect(address?.subAdministrativeArea == "Gipuzkoa")
        #expect(address?.isoCountryCode == "ES")
        #expect(address?.oneLine.contains("Antiguo") == true)
    }

    /// Which of the three states an edit is in, so one assertion shape covers parsers
    /// whose element types have nothing in common.
    private func state<T>(_ edit: FieldEdit<T>) -> String {
        switch edit {
        case .unchanged: return "unchanged"
        case .cleared: return "cleared"
        case .set: return "set"
        }
    }

    /// The distinction `FieldEdit` exists for, applied to every list that was added.
    /// Collapsing absent into empty here would make "leave the addresses alone"
    /// impossible to say, and every read-modify-write would erase them.
    @Test("For each new list, omitting it leaves it alone and [] empties it")
    func absentAndEmptyDifferForEveryNewList() throws {
        let absent = Arguments([:])
        #expect(state(try absent.addressEdit("addresses")) == "unchanged")
        #expect(state(try absent.socialProfileEdit("social_profiles")) == "unchanged")
        #expect(state(try absent.instantMessageEdit("instant_messages")) == "unchanged")
        #expect(state(try absent.labelledEdit("relations")) == "unchanged")
        #expect(state(try absent.dateEdit("dates")) == "unchanged")

        func emptied(_ field: String) -> Arguments { Arguments([field: .array([])]) }
        #expect(state(try emptied("addresses").addressEdit("addresses")) == "cleared")
        #expect(
            state(try emptied("social_profiles").socialProfileEdit("social_profiles")) == "cleared")
        #expect(
            state(try emptied("instant_messages").instantMessageEdit("instant_messages"))
                == "cleared")
        #expect(state(try emptied("relations").labelledEdit("relations")) == "cleared")
        #expect(state(try emptied("dates").dateEdit("dates")) == "cleared")
    }

    @Test("contact_type only accepts the two kinds Contacts has")
    func contactTypeIsClosed() async {
        let answer = await call(
            ToolCatalog.createName,
            ["given_name": .string("Ambiguous"), "contact_type": .string("robot")],
            store: FakeContactStore())
        #expect(answer.isError)
        #expect(answer.text.contains("person"))
        #expect(answer.text.contains("organization"))
    }

    // MARK: Status

    @Test("Status reports the Automation permission separately from Contacts")
    func statusReportsAutomation() async {
        let denied = FakeContactStore(automation: .denied, contacts: Fixtures.sample)
        let answer = await call(ToolCatalog.statusName, store: denied)
        #expect(answer.text.contains("Contacts permission: GRANTED"))
        #expect(answer.text.contains("Automation"))
        #expect(answer.text.contains("Notes unavailable"))
    }

    // MARK: AppleScript escaping

    /// The one part of the Contacts.app bridge a test can reach, and the one where a
    /// mistake is a script-injection bug rather than a formatting one.
    @Suite("AppleScript literals")
    struct AppleScriptLiteralTests {

        @Test("A plain string is quoted and otherwise untouched")
        func plainString() {
            #expect(AppleScriptString.literal("hello") == "\"hello\"")
        }

        @Test("A quote cannot end the literal early")
        func quotesAreEscaped() {
            #expect(
                AppleScriptString.literal("say \"hi\"") == "\"say \\\"hi\\\"\"")
        }

        /// Backslash first, or the escaping would escape its own escapes.
        @Test("A backslash is escaped before anything else is")
        func backslashesAreEscaped() {
            #expect(AppleScriptString.literal("a\\b") == "\"a\\\\b\"")
            #expect(AppleScriptString.literal("\\\"") == "\"\\\\\\\"\"")
        }

        @Test("Line breaks become escapes, because a literal cannot span lines")
        func lineBreaksAreEscaped() {
            #expect(AppleScriptString.literal("one\ntwo") == "\"one\\ntwo\"")
            #expect(AppleScriptString.literal("one\r\ntwo") == "\"one\\ntwo\"")
            #expect(AppleScriptString.literal("one\rtwo") == "\"one\\rtwo\"")
            #expect(AppleScriptString.literal("one\ttwo") == "\"one\\ttwo\"")
        }

        @Test("Non-ASCII passes through unharmed")
        func nonASCIISurvives() {
            #expect(AppleScriptString.literal("Aitor ✓ ñ") == "\"Aitor ✓ ñ\"")
        }

        @Test("A script-shaped note stays inside its literal")
        func injectionAttemptStaysData() {
            let hostile = "\" & (do shell script \"whoami\") & \""
            // Every quote the note carried comes back escaped, so none of them can
            // close the literal the note sits inside and the `&` stays plain text.
            #expect(
                AppleScriptString.literal(hostile)
                    == "\"\\\" & (do shell script \\\"whoami\\\") & \\\"\"")
        }
    }
}
