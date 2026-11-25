import Foundation
import Synchronization

/// Returns the first of two outcomes: the work finishing, or the limit passing.
///
/// The timer is a dispatch timer, not a `Task.sleep`, and the work is not a child of a task
/// group. A synchronous call into Contacts that never returns holds its thread and cannot
/// be cancelled, and a task group would wait for it forever; a timer on the cooperative
/// pool could be starved by the same stuck threads. The stuck work is abandoned, not
/// stopped: it is cancelled, which the loops that can notice do notice, and its late
/// result is discarded.
enum Deadline {

    private final class Outcome<Value: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<Value?, Never>?>

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            self.continuation = Mutex(continuation)
        }

        /// Only the first caller resumes; the other finds it empty.
        func resume(returning value: Value?) {
            continuation.withLock { pending in
                pending?.resume(returning: value)
                pending = nil
            }
        }
    }

    /// `nil` when `limit` passed before `work` finished.
    static func run<Value: Sendable>(
        within limit: Duration, _ work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        return await withCheckedContinuation { continuation in
            let outcome = Outcome<Value>(continuation)
            let task = Task {
                outcome.resume(returning: await work())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                outcome.resume(returning: nil)
                task.cancel()
            }
        }
    }
}

/// Routes a `tools/call` to the store and renders the answer.
///
/// This type never touches Contacts.framework directly — it goes through
/// `ContactStore` — which is what lets the tests drive every branch below against an
/// in-memory double, with no address book and no consent dialog.
public struct ContactTools: ToolHandler {
    private let store: any ContactStore
    private let configuration: Configuration
    private let timeout: Duration

    /// A write can run three scripts through Contacts.app one after another, each allowed
    /// a minute because the first may be waiting on a consent dialog that somebody has to
    /// answer. This leaves room for that and still answers inside
    /// `ToolStandard.timeLimit`, so a call that never comes back is reported by this
    /// server, in its own words, and not by the client giving up on it.
    public static let defaultTimeout = Duration.seconds(180)

    public init(
        store: any ContactStore, configuration: Configuration = Configuration(),
        timeout: Duration = ContactTools.defaultTimeout
    ) {
        self.store = store
        self.configuration = configuration
        self.timeout = timeout
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<[ToolOutput.Block], any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let content)?:
            return ToolOutput(content: content, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(
                    seconds: Int(timeout.components.seconds),
                    wrote: ToolCatalog.writes(parameters.name)),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        let known = error as? ToolError ?? .storeFailure(error.localizedDescription)
        return ToolOutput(text: known.message, isError: true)
    }

    /// Returns content blocks rather than a string because one tool has something other
    /// than text to hand back: `contacts_get(include_photo:)` returns the photo itself.
    private func run(_ parameters: ToolCall) async throws -> [ToolOutput.Block] {
        let arguments = Arguments(parameters.arguments)

        // Reports the permission state instead of failing on it: this is the tool you
        // reach for precisely when the others are refusing to work.
        if parameters.name == ToolCatalog.statusName {
            return [
                text(
                    Format.status(
                        store.authorization(), automation: store.automationConsent(),
                        contactsAppUnsaved: store.contactsAppHasUnsavedChanges(),
                        binaryPath: Self.binaryPath))
            ]
        }
        guard ToolCatalog.all().contains(where: { $0.name == parameters.name }) else {
            throw ToolError.unknownTool(parameters.name)
        }

        try await requireAccess()

        switch parameters.name {
        case ToolCatalog.searchName:
            let query = try arguments.requiredString("query")
            let page = try arguments.page(
                defaultLimit: ToolCatalog.defaultContactLimit, limits: ToolCatalog.contactLimitRange)
            let matches = try await store.search(query: query)
            var notices = arguments.notices
            if let scanned = matches.scanStoppedAfter {
                notices.append(
                    Notice.partial(
                        after: scanned, things: "contacts", narrowBy: ToolCatalog.scanNarrowing))
            }
            let rows = matches.contacts.sorted(by: Self.precedes)
            return [
                text(
                    Self.page(of: rows, page, things: "contacts", notices: notices) {
                        Format.contacts(
                            $0, heading: Format.searchHeading(total: rows.count, query: query),
                            none: Format.noMatch(
                                query: query, partial: matches.scanStoppedAfter != nil),
                            total: rows.count, compact: false)
                    })
            ]

        case ToolCatalog.allName:
            let list = try arguments.optionalString("list")
            let compact = try arguments.bool("compact", default: false)
            let page = try arguments.page(
                defaultLimit: ToolCatalog.defaultContactLimit, limits: ToolCatalog.contactLimitRange)
            let rows = try await store.all(list: list).sorted(by: Self.precedes)
            return [
                text(
                    Self.page(of: rows, page, things: "contacts", notices: arguments.notices) {
                        Format.contacts(
                            $0, heading: Format.everyoneHeading(total: rows.count, list: list),
                            none: Format.nobody(list: list), total: rows.count, compact: compact)
                    })
            ]

        case ToolCatalog.listsName:
            let page = try arguments.page(
                defaultLimit: ToolCatalog.defaultListLimit, limits: ToolCatalog.listLimitRange)
            return [text(lists(try await store.lists(), page, notices: arguments.notices))]

        case ToolCatalog.getName:
            let id = try arguments.requiredString("id")
            let includePhoto = try arguments.bool("include_photo", default: false)
            let characterOffset = try arguments.int(
                "character_offset", default: 0, in: ToolCatalog.offsetRange)
            let maxCharacters = try arguments.int(
                "max_characters", default: ToolCatalog.defaultMaxCharacters,
                in: ToolCatalog.maxCharactersRange)
            guard let contact = try await store.fetch(id: id) else {
                throw ToolError.notFound(id: id)
            }
            let photo = includePhoto ? try await photo(of: contact) : .notAsked
            var content = [
                text(
                    Format.recordWindow(
                        contact, characterOffset: characterOffset, maxCharacters: maxCharacters,
                        notices: arguments.notices + photo.notices))
            ]
            if case .image(let data) = photo {
                content.append(.image(data: data.base64EncodedString(), mimeType: "image/jpeg"))
            }
            return content

        case ToolCatalog.createName:
            return [text(Format.created(try await store.create(try draft(from: arguments))))]

        case ToolCatalog.updateName:
            let id = try arguments.requiredString("id")
            let changes = try self.changes(from: arguments)
            guard !changes.isEmpty else { throw ToolError.nothingToUpdate }
            return [
                text(
                    Format.updated(
                        try await store.update(id: id, changes: changes),
                        fields: changes.changedFields))
            ]

        case ToolCatalog.updateListsName:
            return [text(try await changeLists(arguments))]

        case ToolCatalog.deleteName:
            let id = try arguments.requiredString("id")
            guard try arguments.bool("confirm", default: false) else {
                throw ToolError.confirmationRequired(action: "Deleting a contact")
            }
            return [text(Format.deleted(try await store.delete(id: id)))]

        default:
            throw ToolError.unknownTool(parameters.name)
        }
    }

    private func text(_ value: String) -> ToolOutput.Block {
        .text(value)
    }

    // MARK: Pages

    /// By name the way a person reads a list, then by id, so that two contacts of the same
    /// name never tie and a page boundary falls in the same place on the next call.
    static func precedes(_ lhs: ContactSummary, _ rhs: ContactSummary) -> Bool {
        let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    /// One page of `rows`, which are every matching row already in the order the tool
    /// states: the notices, where the page sits in the whole, whether a value in it was
    /// shortened, then the rows.
    ///
    /// `ToolStandard.page` with one addition: the sentence about shortened values depends
    /// on the rows the page ends up holding, so it has to be decided after they are
    /// rendered, where that helper takes its notices beforehand.
    static func page<Row>(
        of rows: [Row], _ page: (limit: Int, offset: Int), things: String, notices: [String],
        render: ([Row]) -> Format.Listing
    ) -> String {
        ToolStandard.fitting(page.limit) { size in
            let shown = Array(rows.dropFirst(page.offset).prefix(size))
            let listing = render(shown)
            var notices = notices
            if let position = Notice.page(
                offset: page.offset, count: shown.count, total: rows.count, things: things)
            {
                notices.append(position)
            }
            if listing.clipped { notices.append(Self.clippedNotice) }
            return ToolStandard.withNotices(notices, listing.text)
        }
    }

    static let clippedNotice = Notice.clipped(
        field: "A long value", width: ToolCatalog.cellWidth, tool: ToolCatalog.getName)

    /// Lists and accounts are two listings in one result, so one `limit` and one `offset`
    /// page both: the same window of each, each with its own sentence when the window is
    /// not all of it. There are rarely more accounts than a page holds, and then the
    /// accounts simply all sit on the first page.
    private func lists(_ book: AddressBookLists, _ page: (limit: Int, offset: Int), notices: [String])
        -> String
    {
        func byName(_ lhs: String, _ rhs: String) -> ComparisonResult {
            lhs.localizedCaseInsensitiveCompare(rhs)
        }
        // Down to the id, because two accounts can each hold a list of the same name.
        let lists = book.lists.sorted {
            let name = byName($0.name, $1.name)
            if name != .orderedSame { return name == .orderedAscending }
            let account = byName($0.accountName ?? "", $1.accountName ?? "")
            return account == .orderedSame ? $0.id < $1.id : account == .orderedAscending
        }
        let accounts = book.accounts.sorted {
            let name = byName($0.name, $1.name)
            return name == .orderedSame ? $0.id < $1.id : name == .orderedAscending
        }
        return ToolStandard.fitting(page.limit) { size in
            let shownLists = Array(lists.dropFirst(page.offset).prefix(size))
            let shownAccounts = Array(accounts.dropFirst(page.offset).prefix(size))
            let listing = Format.lists(
                shownLists, totalLists: lists.count, accounts: shownAccounts,
                totalAccounts: accounts.count)
            var notices = notices
            notices += [
                Notice.page(
                    offset: page.offset, count: shownLists.count, total: lists.count,
                    things: "lists"),
                Notice.page(
                    offset: page.offset, count: shownAccounts.count, total: accounts.count,
                    things: "accounts"),
            ].compactMap { $0 }
            if listing.clipped { notices.append(Self.clippedNotice) }
            return ToolStandard.withNotices(notices, listing.text)
        }
    }

    // MARK: Photo

    /// What `include_photo` adds to a record.
    private enum Photo {
        case notAsked
        case image(Data)
        case unavailable(String)

        /// The sentence that stands in for a photo that was asked for and is not
        /// returned. It goes before the record, like everything a result does not hold.
        var notices: [String] {
            if case .unavailable(let reason) = self { return [reason] }
            return []
        }
    }

    /// The photo, reduced to what a result may carry, or a line explaining its absence.
    ///
    /// A contact whose photo cannot be returned still has a full record, so this never
    /// fails the call: saying "there is no photo" is a better answer than turning the
    /// whole read into an error. One contact has one photo, so a result never holds more
    /// than `ToolCatalog.photosPerCall` images.
    private func photo(of contact: ContactDetail) async throws -> Photo {
        guard contact.photo != nil, let data = try await store.photo(id: contact.id) else {
            return .unavailable("No photo is stored for this contact.")
        }
        guard let reduced = ContactPhoto.reduced(data) else {
            return .unavailable(
                """
                The stored photo (\(Format.size(data.count))) is not returned: it could not \
                be read as an image and reduced to \(ContactPhoto.longestSide) pixels and \
                \(Format.size(ContactPhoto.longestBytes)). Open the card in Contacts to see it.
                """)
        }
        return .image(reduced)
    }

    /// Asks once when macOS has not yet prompted, so the first real call surfaces the
    /// consent dialog rather than a permission error the reader has to act on twice.
    private func requireAccess() async throws {
        var authorization = store.authorization()
        if authorization == .notDetermined {
            authorization = await store.requestAccess()
        }
        guard authorization.isUsable else { throw ToolError.notAuthorized(authorization) }
    }

    // MARK: Argument assembly

    private func draft(from arguments: Arguments) throws -> ContactDraft {
        var draft = ContactDraft()
        if case .set(let kind) = try arguments.kindEdit("contact_type") { draft.kind = kind }
        draft.namePrefix = try arguments.optionalString("name_prefix") ?? ""
        draft.givenName = try arguments.optionalString("given_name") ?? ""
        draft.middleName = try arguments.optionalString("middle_name") ?? ""
        draft.familyName = try arguments.optionalString("family_name") ?? ""
        draft.previousFamilyName = try arguments.optionalString("previous_family_name") ?? ""
        draft.nameSuffix = try arguments.optionalString("name_suffix") ?? ""
        draft.nickname = try arguments.optionalString("nickname") ?? ""
        draft.phoneticGivenName = try arguments.optionalString("phonetic_given_name") ?? ""
        draft.phoneticMiddleName = try arguments.optionalString("phonetic_middle_name") ?? ""
        draft.phoneticFamilyName = try arguments.optionalString("phonetic_family_name") ?? ""
        draft.phoneticOrganizationName =
            try arguments.optionalString("phonetic_organization_name") ?? ""
        draft.organization = try arguments.optionalString("organization") ?? ""
        draft.jobTitle = try arguments.optionalString("job_title") ?? ""
        draft.department = try arguments.optionalString("department") ?? ""
        draft.phones = try arguments.labelledValues("phones") ?? []
        draft.emails = try arguments.labelledValues("emails") ?? []
        draft.urls = try arguments.labelledValues("urls") ?? []
        draft.relations = try arguments.labelledValues("relations") ?? []
        draft.addresses = try arguments.postalAddresses("addresses") ?? []
        draft.socialProfiles = try arguments.socialProfiles("social_profiles") ?? []
        draft.instantMessages = try arguments.instantMessages("instant_messages") ?? []
        draft.dates = try arguments.labelledDates("dates") ?? []
        draft.birthday = try arguments.birthday("birthday")
        // Checked here, before the store is ever called, rather than only skipping the
        // assignment: silently dropping the argument would let the rest of the contact
        // through with no sign that photo_path was refused rather than merely absent.
        if let photoPath = try arguments.optionalString("photo_path") {
            guard !configuration.disablePhotoWrites else { throw ToolError.photoWritesDisabled }
            draft.photoPath = photoPath
        }
        draft.note = try arguments.optionalString("note") ?? ""
        draft.lists = try arguments.labelledValues("lists")?.map(\.value) ?? []

        guard !draft.isEmpty else { throw ToolError.emptyContact }
        return draft
    }

    private func changes(from arguments: Arguments) throws -> ContactChanges {
        var changes = ContactChanges()
        changes.kind = try arguments.kindEdit("contact_type")
        changes.namePrefix = try arguments.stringEdit("name_prefix")
        changes.givenName = try arguments.stringEdit("given_name")
        changes.middleName = try arguments.stringEdit("middle_name")
        changes.familyName = try arguments.stringEdit("family_name")
        changes.previousFamilyName = try arguments.stringEdit("previous_family_name")
        changes.nameSuffix = try arguments.stringEdit("name_suffix")
        changes.nickname = try arguments.stringEdit("nickname")
        changes.phoneticGivenName = try arguments.stringEdit("phonetic_given_name")
        changes.phoneticMiddleName = try arguments.stringEdit("phonetic_middle_name")
        changes.phoneticFamilyName = try arguments.stringEdit("phonetic_family_name")
        changes.phoneticOrganizationName = try arguments.stringEdit("phonetic_organization_name")
        changes.organization = try arguments.stringEdit("organization")
        changes.jobTitle = try arguments.stringEdit("job_title")
        changes.department = try arguments.stringEdit("department")
        changes.note = try arguments.stringEdit("note")
        let photoPathEdit = try arguments.stringEdit("photo_path")
        if photoPathEdit != .unchanged {
            guard !configuration.disablePhotoWrites else { throw ToolError.photoWritesDisabled }
        }
        changes.photoPath = photoPathEdit
        changes.birthday = try arguments.birthdayEdit("birthday")
        changes.phones = try arguments.labelledEdit("phones")
        changes.emails = try arguments.labelledEdit("emails")
        changes.urls = try arguments.labelledEdit("urls")
        changes.relations = try arguments.labelledEdit("relations")
        changes.addresses = try arguments.addressEdit("addresses")
        changes.socialProfiles = try arguments.socialProfileEdit("social_profiles")
        changes.instantMessages = try arguments.instantMessageEdit("instant_messages")
        changes.dates = try arguments.dateEdit("dates")
        return changes
    }

    /// Applies the removals before the additions.
    ///
    /// Order only matters when the same list appears in both, which is a contradictory
    /// request; doing removals first means the addition wins, which is the reading that
    /// leaves the person in a list rather than quietly out of one.
    private func changeLists(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredString("id")
        let add = try arguments.labelledValues("add")?.map(\.value) ?? []
        let remove = try arguments.labelledValues("remove")?.map(\.value) ?? []
        guard !add.isEmpty || !remove.isEmpty else { throw ToolError.emptyListChange }

        // Each change is its own save. A call that passed its deadline has already been
        // answered, so it stops before the next one instead of going on changing the
        // address book behind an answer that said the outcome was unknown.
        var contact: ContactDetail?
        for list in remove {
            try Task.checkCancellation()
            contact = try await store.removeFromList(id: id, list: list)
        }
        for list in add {
            try Task.checkCancellation()
            contact = try await store.addToList(id: id, list: list)
        }

        guard let contact else { throw ToolError.notFound(id: id) }
        return Format.listsChanged(contact, added: add, removed: remove)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        } ?? "(unknown)"
    }
}
