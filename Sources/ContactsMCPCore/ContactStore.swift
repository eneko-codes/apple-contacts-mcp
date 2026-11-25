import Foundation

/// Mirrors `CNAuthorizationStatus`, minus the iOS-only `.limited` case: on macOS
/// Contacts access is all or nothing, so there is no partial state to represent.
public enum ContactsAuthorization: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized

    public var isUsable: Bool { self == .authorized }
}

/// The seam between the tool layer and Contacts.framework.
///
/// Everything above this protocol is exercised by the tests against an in-memory
/// double; everything below it can only be verified against a real address book.
/// Keeping the boundary this thin is what makes the untested surface small enough to
/// check by hand.
public protocol ContactStore: Sendable {
    func authorization() -> ContactsAuthorization

    /// Prompts on first use. Returns the status after the user answers.
    @discardableResult
    func requestAccess() async -> ContactsAuthorization

    /// Whether this process may drive Contacts.app, which governs the note field and
    /// nothing else. Reported by `contacts_status`, because somebody who has already
    /// granted Contacts access and still cannot see a note is looking at the wrong
    /// pane in System Settings.
    func automationConsent() -> AutomationConsent

    /// Whether Contacts.app holds changes it has not saved. While it does, nothing is read
    /// or written through it: its `save` was measured returning without saving, and what
    /// it reads back then is its own unsaved model rather than the address book. False
    /// when Contacts.app is not running, since asking would launch it.
    func contactsAppHasUnsavedChanges() -> Bool

    /// Every contact that matches, in no particular order. Ordering and paging are the
    /// tool layer's, done in one place so the fake and the real store cannot drift apart
    /// on them: Contacts has no cursor of its own, and an address book is small enough to
    /// hold one line per contact in memory.
    func search(query: String) async throws -> ContactMatches

    /// Every contact, or every contact in one list, in no particular order.
    ///
    /// `list` accepts an identifier or an exact name: the identifier is what
    /// `lists()` returns, the name is what a person reads off the screen, and
    /// refusing the second would make the tool unusable from a conversation.
    func all(list: String?) async throws -> [ContactSummary]

    func fetch(id: String) async throws -> ContactDetail?

    /// The lists and the accounts holding them, in one call: a list name on its own is
    /// ambiguous, because two accounts may each have a "Family" and they are not the
    /// same list.
    func lists() async throws -> AddressBookLists

    /// The contact's photo, as stored. Separate from `fetch` so a record can report
    /// that a photo exists without every read dragging the image along with it. The tool
    /// layer reduces it (`ContactPhoto`) before it goes into a result.
    func photo(id: String) async throws -> Data?

    func create(_ draft: ContactDraft) async throws -> ContactDetail
    func update(id: String, changes: ContactChanges) async throws -> ContactUpdateResult

    /// Both membership calls return the contact as it stands afterwards, so the caller
    /// can print the resulting membership rather than assert what it should now be.
    /// `list` accepts an identifier or an exact name, as in `all`.
    func addToList(id: String, list: String) async throws -> ContactDetail
    func removeFromList(id: String, list: String) async throws -> ContactDetail

    /// Returns the contact as it was immediately before removal, so the caller can
    /// describe precisely what disappeared.
    func delete(id: String) async throws -> ContactDetail
}

/// What the address book is organised into: the lists themselves, and the accounts
/// those lists live in.
public struct AddressBookLists: Sendable, Equatable {
    public let lists: [ContactList]
    public let accounts: [ContactAccount]

    public init(lists: [ContactList], accounts: [ContactAccount]) {
        self.lists = lists
        self.accounts = accounts
    }
}

/// Both sides of an update, so a caller can say what actually changed rather than only
/// what the record now holds. `before` is what `id` held immediately prior to applying
/// `changes` — needed because value lists replace wholesale: a `relations` argument
/// carrying one entry silently discards the other three, and `after` alone cannot tell
/// that apart from an add.
public struct ContactUpdateResult: Sendable, Equatable {
    public let before: ContactDetail
    public let after: ContactDetail

    public init(before: ContactDetail, after: ContactDetail) {
        self.before = before
        self.after = after
    }
}

public struct ContactMatches: Sendable, Equatable {
    public let contacts: [ContactSummary]
    /// Set when the search had to walk the whole address book and ran out of time: how
    /// many contacts it had looked at. The ones it never reached may match too, so the
    /// result has to say so instead of reading as the whole answer.
    public let scanStoppedAfter: Int?

    public init(contacts: [ContactSummary], scanStoppedAfter: Int? = nil) {
        self.contacts = contacts
        self.scanStoppedAfter = scanStoppedAfter
    }
}
