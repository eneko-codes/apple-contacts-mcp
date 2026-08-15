import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// This type never touches Contacts.framework directly — it goes through
/// `ContactStore` — which is what lets the tests drive every branch below against an
/// in-memory double, with no address book and no consent dialog.
public struct ContactTools: Sendable {
    private let store: any ContactStore
    private let configuration: Configuration

    public init(store: any ContactStore, configuration: Configuration = Configuration()) {
        self.store = store
        self.configuration = configuration
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            return .init(content: try await run(parameters), isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ],
                isError: true)
        }
    }

    /// Returns content blocks rather than a string because one tool has something other
    /// than text to hand back: `contacts_get(include_photo:)` returns the photo itself.
    private func run(_ parameters: CallTool.Parameters) async throws -> [Tool.Content] {
        let arguments = Arguments(parameters.arguments)

        // Reports the permission state instead of failing on it: this is the tool you
        // reach for precisely when the others are refusing to work.
        if parameters.name == ToolCatalog.statusName {
            return [
                text(
                    Format.status(
                        store.authorization(), automation: store.automationConsent(),
                        binaryPath: Self.binaryPath))
            ]
        }

        try await requireAccess()

        switch parameters.name {
        case ToolCatalog.searchName:
            let query = try arguments.requiredString("query")
            let limit = try arguments.int(
                "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)
            let offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)
            let page = try await store.search(query: query, limit: limit, offset: offset)
            return [text(Format.searchResults(page, query: query, offset: offset))]

        case ToolCatalog.allName:
            let list = arguments.optionalString("list").flatMap { $0.isEmpty ? nil : $0 }
            let limit = try arguments.int(
                "limit", default: Configuration.searchLimit, in: Configuration.listLimitRange)
            let offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)
            let page = try await store.all(list: list, limit: limit, offset: offset)
            return [
                text(
                    Format.everyone(
                        page, list: list, offset: offset, compact: arguments.bool("compact")))
            ]

        case ToolCatalog.listsName:
            return [text(Format.lists(try await store.lists()))]

        case ToolCatalog.getName:
            let id = try arguments.requiredString("id")
            guard let contact = try await store.fetch(id: id) else {
                throw ToolError.notFound(id: id)
            }
            var content = [text(Format.detail(contact))]
            if arguments.bool("include_photo") {
                content.append(contentsOf: try await photo(of: contact))
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
            guard arguments.bool("confirm") else {
                throw ToolError.confirmationRequired(action: "Deleting a contact")
            }
            return [text(Format.deleted(try await store.delete(id: id)))]

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    private func text(_ value: String) -> Tool.Content {
        .text(text: value, annotations: nil, _meta: nil)
    }

    /// The photo as an image block, or a line explaining its absence.
    ///
    /// A contact whose photo cannot be fetched still returned a full record above, so
    /// this never throws: saying "there is no photo" is a better answer than turning
    /// the whole read into an error.
    private func photo(of contact: ContactDetail) async throws -> [Tool.Content] {
        guard contact.photo != nil, let data = try await store.photo(id: contact.id) else {
            return [text("\nNo photo is stored for this contact.")]
        }
        return [
            .image(
                data: data.base64EncodedString(), mimeType: Self.imageType(of: data),
                annotations: nil, _meta: nil)
        ]
    }

    /// Contacts stores whatever was dropped on it and records no media type, so the
    /// type is read back off the first bytes. JPEG covers almost everything a camera
    /// or a sync produces; PNG is the other one worth recognising.
    private static func imageType(of data: Data) -> String {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        return data.starts(with: png) ? "image/png" : "image/jpeg"
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
        draft.namePrefix = arguments.optionalString("name_prefix") ?? ""
        draft.givenName = arguments.optionalString("given_name") ?? ""
        draft.middleName = arguments.optionalString("middle_name") ?? ""
        draft.familyName = arguments.optionalString("family_name") ?? ""
        draft.previousFamilyName = arguments.optionalString("previous_family_name") ?? ""
        draft.nameSuffix = arguments.optionalString("name_suffix") ?? ""
        draft.nickname = arguments.optionalString("nickname") ?? ""
        draft.phoneticGivenName = arguments.optionalString("phonetic_given_name") ?? ""
        draft.phoneticMiddleName = arguments.optionalString("phonetic_middle_name") ?? ""
        draft.phoneticFamilyName = arguments.optionalString("phonetic_family_name") ?? ""
        draft.phoneticOrganizationName =
            arguments.optionalString("phonetic_organization_name") ?? ""
        draft.organization = arguments.optionalString("organization") ?? ""
        draft.jobTitle = arguments.optionalString("job_title") ?? ""
        draft.department = arguments.optionalString("department") ?? ""
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
        if let photoPath = arguments.optionalString("photo_path"), !photoPath.isEmpty {
            guard !configuration.disablePhotoWrites else { throw ToolError.photoWritesDisabled }
            draft.photoPath = photoPath
        }
        draft.note = arguments.optionalString("note") ?? ""
        draft.lists = try arguments.labelledValues("lists")?.map(\.value) ?? []

        guard !draft.isEmpty else { throw ToolError.emptyContact }
        return draft
    }

    private func changes(from arguments: Arguments) throws -> ContactChanges {
        var changes = ContactChanges()
        changes.kind = try arguments.kindEdit("contact_type")
        changes.namePrefix = arguments.stringEdit("name_prefix")
        changes.givenName = arguments.stringEdit("given_name")
        changes.middleName = arguments.stringEdit("middle_name")
        changes.familyName = arguments.stringEdit("family_name")
        changes.previousFamilyName = arguments.stringEdit("previous_family_name")
        changes.nameSuffix = arguments.stringEdit("name_suffix")
        changes.nickname = arguments.stringEdit("nickname")
        changes.phoneticGivenName = arguments.stringEdit("phonetic_given_name")
        changes.phoneticMiddleName = arguments.stringEdit("phonetic_middle_name")
        changes.phoneticFamilyName = arguments.stringEdit("phonetic_family_name")
        changes.phoneticOrganizationName = arguments.stringEdit("phonetic_organization_name")
        changes.organization = arguments.stringEdit("organization")
        changes.jobTitle = arguments.stringEdit("job_title")
        changes.department = arguments.stringEdit("department")
        changes.note = arguments.stringEdit("note")
        let photoPathEdit = arguments.stringEdit("photo_path")
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

        var contact: ContactDetail?
        for list in remove { contact = try await store.removeFromList(id: id, list: list) }
        for list in add { contact = try await store.addToList(id: id, list: list) }

        guard let contact else { throw ToolError.notFound(id: id) }
        return Format.listsChanged(contact, added: add, removed: remove)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        } ?? "(unknown)"
    }
}
