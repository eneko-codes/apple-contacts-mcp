import Foundation

@testable import ContactsMCPCore

/// In-memory `ContactStore` for the tests.
///
/// Every fixture here is invented. The test suite must never reach a real address
/// book: see the hard rule in CLAUDE.md.
final class FakeContactStore: ContactStore, @unchecked Sendable {
    var status: ContactsAuthorization
    var automation: AutomationConsent
    var contacts: [ContactDetail]
    /// List metadata, and who is in each one keyed by list id — the same shape
    /// Contacts forces on the real store, which has no reverse index either.
    var lists: [ContactList]
    var members: [String: Set<String>]
    var accounts: [ContactAccount]
    var photos: [String: Data] = [:]
    private(set) var deletedIDs: [String] = []
    private(set) var accessRequests = 0
    /// The `limit` dispatch actually resolved, so a test can pin that an omitted
    /// argument falls back to `Configuration.searchLimit` without needing enough
    /// fixtures to observe truncation.
    private(set) var lastSearchLimit: Int?

    init(
        status: ContactsAuthorization = .authorized,
        automation: AutomationConsent = .granted,
        contacts: [ContactDetail] = [],
        lists: [ContactList] = [],
        members: [String: Set<String>] = [:],
        accounts: [ContactAccount] = []
    ) {
        self.status = status
        self.automation = automation
        self.contacts = contacts
        self.lists = lists
        self.members = members
        self.accounts = accounts
    }

    func authorization() -> ContactsAuthorization { status }

    func automationConsent() -> AutomationConsent { automation }

    @discardableResult
    func requestAccess() async -> ContactsAuthorization {
        accessRequests += 1
        if status == .notDetermined { status = .authorized }
        return status
    }

    func search(query: String, limit: Int, offset: Int) async throws -> ContactSearchPage {
        lastSearchLimit = limit
        let matches = contacts.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.organization.localizedCaseInsensitiveContains(query)
        }
        return page(matches, limit: limit, offset: offset)
    }

    func all(list: String?, limit: Int, offset: Int) async throws -> ContactSearchPage {
        var matches = contacts
        if let list {
            let resolved = try resolve(list)
            let ids = members[resolved.id] ?? []
            matches = matches.filter { ids.contains($0.id) }
        }
        return page(matches, limit: limit, offset: offset)
    }

    private func page(_ matches: [ContactDetail], limit: Int, offset: Int) -> ContactSearchPage {
        let ordered = matches.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let window = ordered.dropFirst(offset).prefix(limit).map {
            ContactSummary(
                id: $0.id, displayName: $0.displayName,
                organization: $0.organization.isEmpty ? nil : $0.organization,
                phone: $0.phones.first?.value, email: $0.emails.first?.value)
        }
        return ContactSearchPage(results: Array(window), total: ordered.count)
    }

    func fetch(id: String) async throws -> ContactDetail? {
        guard var contact = contacts.first(where: { $0.id == id }) else { return nil }
        contact.lists = listNames(of: id)
        return contact
    }

    func lists() async throws -> AddressBookLists {
        AddressBookLists(
            lists: lists.map {
                ContactList(
                    id: $0.id, name: $0.name, accountName: $0.accountName,
                    memberCount: members[$0.id]?.count ?? 0)
            },
            accounts: accounts)
    }

    func photo(id: String) async throws -> Data? { photos[id] }

    func create(_ draft: ContactDraft) async throws -> ContactDetail {
        // Resolved before anything is created, matching the real store: a bad list name
        // must fail loudly rather than leave a contact behind with no way to say which
        // list it never joined.
        let resolvedLists = try draft.lists.map { try resolve($0) }

        var created = Fixtures.detail(
            id: "new-\(contacts.count + 1)",
            displayName: [draft.givenName, draft.familyName].filter { !$0.isEmpty }
                .joined(separator: " "),
            givenName: draft.givenName, familyName: draft.familyName,
            organization: draft.organization,
            phones: draft.phones, emails: draft.emails,
            addresses: draft.addresses, socialProfiles: draft.socialProfiles,
            instantMessages: draft.instantMessages, relations: draft.relations,
            dates: draft.dates,
            note: draft.note.isEmpty ? nil : draft.note)
        contacts.append(created)
        for list in resolvedLists { members[list.id, default: []].insert(created.id) }
        created.lists = listNames(of: created.id)
        return created
    }

    func update(id: String, changes: ContactChanges) async throws -> ContactUpdateResult {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else {
            throw ToolError.notFound(id: id)
        }
        let current = contacts[index]
        let updated = Fixtures.detail(
            id: current.id,
            displayName: current.displayName,
            givenName: changes.givenName.applied(to: current.givenName),
            familyName: changes.familyName.applied(to: current.familyName),
            organization: changes.organization.applied(to: current.organization),
            phones: changes.phones.applied(to: current.phones, empty: []),
            emails: current.emails,
            addresses: changes.addresses.applied(to: current.addresses, empty: []),
            socialProfiles: changes.socialProfiles.applied(to: current.socialProfiles, empty: []),
            instantMessages: changes.instantMessages.applied(
                to: current.instantMessages, empty: []),
            relations: changes.relations.applied(to: current.relations, empty: []),
            dates: changes.dates.applied(to: current.dates, empty: []),
            note: changes.note == .unchanged ? current.note : changes.note.applied(to: ""))
        contacts[index] = updated
        return ContactUpdateResult(before: current, after: updated)
    }

    func addToList(id: String, list: String) async throws -> ContactDetail {
        try setMembership(id: id, list: list, member: true)
    }

    func removeFromList(id: String, list: String) async throws -> ContactDetail {
        try setMembership(id: id, list: list, member: false)
    }

    private func setMembership(id: String, list: String, member: Bool) throws -> ContactDetail {
        guard var contact = contacts.first(where: { $0.id == id }) else {
            throw ToolError.notFound(id: id)
        }
        let resolved = try resolve(list)
        if member {
            members[resolved.id, default: []].insert(id)
        } else {
            members[resolved.id]?.remove(id)
        }
        contact.lists = listNames(of: id)
        return contact
    }

    /// Accepts an id or an exact name, as the real store does.
    private func resolve(_ reference: String) throws -> ContactList {
        if let hit = lists.first(where: { $0.id == reference }) { return hit }
        if let hit = lists.first(where: {
            $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame
        }) { return hit }
        throw ToolError.listNotFound(reference)
    }

    private func listNames(of id: String) -> [String] {
        lists.filter { members[$0.id]?.contains(id) == true }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func delete(id: String) async throws -> ContactDetail {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else {
            throw ToolError.notFound(id: id)
        }
        deletedIDs.append(id)
        var removed = contacts.remove(at: index)
        removed.lists = listNames(of: id)
        return removed
    }
}

enum Fixtures {
    static func detail(
        id: String,
        displayName: String,
        kind: ContactKind = .person,
        namePrefix: String = "",
        givenName: String = "",
        familyName: String = "",
        nameSuffix: String = "",
        nickname: String = "",
        phoneticGivenName: String = "",
        organization: String = "",
        jobTitle: String = "",
        phones: [LabelledValue] = [],
        emails: [LabelledValue] = [],
        urls: [LabelledValue] = [],
        addresses: [PostalAddress] = [],
        socialProfiles: [SocialProfile] = [],
        instantMessages: [InstantMessage] = [],
        relations: [LabelledValue] = [],
        birthday: DateComponents? = nil,
        dates: [LabelledDate] = [],
        photo: PhotoInfo? = nil,
        note: String? = nil
    ) -> ContactDetail {
        ContactDetail(
            id: id, displayName: displayName, kind: kind, namePrefix: namePrefix,
            givenName: givenName, middleName: "", familyName: familyName,
            previousFamilyName: "", nameSuffix: nameSuffix, nickname: nickname,
            phoneticGivenName: phoneticGivenName, phoneticMiddleName: "",
            phoneticFamilyName: "", phoneticOrganizationName: "",
            organization: organization, jobTitle: jobTitle, department: "",
            phones: phones, emails: emails, urls: urls, addresses: addresses,
            socialProfiles: socialProfiles, instantMessages: instantMessages,
            relations: relations, birthday: birthday, nonGregorianBirthday: nil,
            dates: dates, photo: photo, lists: [], note: note)
    }

    /// Three invented people. Names are deliberately absurd so a fixture can never be
    /// mistaken for a real record. See the hard rule in CLAUDE.md.
    static let sample: [ContactDetail] = [
        detail(
            id: "id-aurora", displayName: "Aurora Fakeperson", givenName: "Aurora",
            familyName: "Fakeperson", organization: "Fictitious Ltd", jobTitle: "Engineer",
            phones: [LabelledValue(label: "mobile", value: "+34 600 000 001")],
            emails: [LabelledValue(label: "work", value: "aurora@fictitious.invalid")],
            birthday: DateComponents(year: 1990, month: 3, day: 14)),
        detail(
            id: "id-basilio", displayName: "Basil Sampleton", givenName: "Basil",
            familyName: "Sampleton", organization: "Fictitious Ltd",
            phones: [LabelledValue(label: nil, value: "+34 600 000 002")]),
        detail(
            id: "id-cecilia", displayName: "Cecily Madeup", givenName: "Cecily",
            familyName: "Madeup",
            emails: [LabelledValue(label: "home", value: "cecily@madeup.invalid")]),
    ]

    /// Two invented lists in one invented account.
    static let sampleLists: [ContactList] = [
        ContactList(id: "list-kin", name: "Invented Kin", accountName: "Nowhere", memberCount: 0),
        ContactList(
            id: "list-work", name: "Imaginary Work", accountName: "Nowhere", memberCount: 0),
    ]

    static let sampleAccounts: [ContactAccount] = [
        ContactAccount(id: "account-nowhere", name: "Nowhere", kind: .local, isDefault: true)
    ]

    /// Aurora is in both lists, Basil in one, Cecily in none.
    static let sampleMembers: [String: Set<String>] = [
        "list-kin": ["id-aurora"],
        "list-work": ["id-aurora", "id-basilio"],
    ]

    static func populated() -> FakeContactStore {
        FakeContactStore(
            contacts: sample, lists: sampleLists, members: sampleMembers,
            accounts: sampleAccounts)
    }
}
