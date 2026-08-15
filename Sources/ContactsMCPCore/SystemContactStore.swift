import Contacts
import Foundation

/// `ContactStore` backed by the real address book.
public struct SystemContactStore: ContactStore {

    /// One `CNContactStore` for the whole process, shared by every call.
    ///
    /// This is not an optimisation. A `CNContact` handed back by a fetch is a Core Data
    /// object whose unfetched properties are still **faults**, and a fault can only be
    /// resolved against the managed-object context *inside the store that fetched it*.
    /// Contacts resolves faults during `willSave` — it rebuilds the record's search index
    /// there, in `-[CNCDContact _newStringForIndexing]` — so a contact fetched from one
    /// store and saved through another, or through one whose context has since gone away,
    /// throws "Unhandled error (NSCocoaErrorDomain, 134092) occurred during faulting".
    /// That was the opaque error making every `update_contact` and `update_contact_lists`
    /// call fail while `create_contact` kept working: a created contact is a fresh
    /// `CNMutableContact` with no faults to resolve and no context behind it.
    ///
    /// `nonisolated(unsafe)` is justified by Apple's own documentation rather than by
    /// hope: `CNContactStore.h` opens with "The CNContactStore is a thread safe class
    /// that can fetch and save contacts, fetch and save groups, and fetch containers."
    /// Do not go back to building one per call.
    ///
    /// Public so `contacts-live-check` can create and delete its own disposable Lists
    /// through the very same store the fix is about — groups are deliberately not part of
    /// the `ContactStore` seam, since no tool here creates one.
    nonisolated(unsafe) public static let shared = CNContactStore()

    /// Notes cannot come from Contacts.framework at all: see `ContactsAppScripting`.
    private let notes = ContactsAppScripting()

    public init() {}

    // MARK: Authorisation

    /// Sticks once observed `.authorized`, and is never reset by a later disagreeing
    /// read. Exists because `CNContactStore.authorizationStatus(for:)` was observed
    /// reporting `.notDetermined` on a call made *after* a real read and a real write
    /// had both already succeeded earlier in the same process — a genuine reversal is
    /// nowhere in the picture, this server holds no cache of its own to invalidate, and
    /// whatever produces the staleness is inside Apple's own TCC caching, not reachable
    /// from here. Latching the first true answer is the only correction available.
    ///
    /// Tradeoff, stated rather than hidden: if access is genuinely revoked mid-session —
    /// System Settings, not a restart — this keeps reporting `.authorized` until the
    /// next real operation fails with the OS's own permission error. That is a worse
    /// diagnostic than a status tool naming the problem, but it is better than the
    /// alternative this replaces: `contacts_status` sending someone to audit
    /// `codesign` and `NSContactsUsageDescription` for a signing problem that does not
    /// exist, minutes after their own read and write both worked.
    nonisolated(unsafe) private static var hasObservedAuthorization = false

    public func authorization() -> ContactsAuthorization {
        let status: ContactsAuthorization
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: status = .authorized
        case .denied: status = .denied
        case .restricted: status = .restricted
        case .notDetermined: status = .notDetermined
        @unknown default: status = .denied
        }
        if status == .authorized { Self.hasObservedAuthorization = true }
        return Self.hasObservedAuthorization ? .authorized : status
    }

    @discardableResult
    public func requestAccess() async -> ContactsAuthorization {
        _ = try? await Self.shared.requestAccess(for: .contacts)
        return authorization()
    }

    /// Whether Contacts.app can be driven, which is what governs notes and nothing
    /// else. Surfaced by `contacts_status`.
    public func automationConsent() -> AutomationConsent { notes.consent() }

    // MARK: Keys

    // Computed rather than stored: `CNKeyDescriptor` is not Sendable, so a static
    // `let` of these would be shared mutable global state under Swift 6 concurrency
    // checking. Rebuilding an array of string constants per call costs nothing.

    /// Only what a result line prints. Fetching detail keys for a 200-match search
    /// would pull image data and every label for contacts that are never shown.
    private static var summaryKeys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey, CNContactGivenNameKey, CNContactMiddleNameKey,
            CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ].map { $0 as CNKeyDescriptor }
            + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
    }

    /// Every property `CNContact` exposes, with two deliberate omissions.
    ///
    /// `CNContactImageDataKey` is left out because it would put the full original
    /// photo — megabytes, sometimes — into every single read; `photo(id:)` fetches it
    /// on demand instead, and the thumbnail key here is enough to report that a photo
    /// exists. `CNContactNoteKey` is left out because asking for it makes the entire
    /// fetch throw without an entitlement no command-line binary can carry; the note
    /// arrives from Contacts.app afterwards.
    private static var detailKeys: [CNKeyDescriptor] {
        summaryKeys + [
            CNContactTypeKey, CNContactNamePrefixKey, CNContactNameSuffixKey,
            CNContactPreviousFamilyNameKey, CNContactPhoneticGivenNameKey,
            CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey,
            CNContactPhoneticOrganizationNameKey, CNContactJobTitleKey,
            CNContactDepartmentNameKey, CNContactUrlAddressesKey,
            CNContactPostalAddressesKey, CNContactSocialProfilesKey,
            CNContactInstantMessageAddressesKey, CNContactRelationsKey,
            CNContactBirthdayKey, CNContactNonGregorianBirthdayKey, CNContactDatesKey,
            CNContactImageDataAvailableKey, CNContactThumbnailImageDataKey,
        ].map { $0 as CNKeyDescriptor }
    }

    /// The descriptor for a contact that is going to be **saved**, as opposed to read.
    ///
    /// A contact reaches `CNSaveRequest` as a Core Data object with faults standing in for
    /// every property the fetch did not ask for. Contacts rebuilds the record's search
    /// index inside `willSave` (`-[CNCDContact _newStringForIndexing]`), reading attributes
    /// this server never named, and a fault it cannot resolve there aborts the whole save
    /// with "Cocoa error 134092" — naming no field, because by then it is Core Data
    /// failing, not validation. Fetching narrowly is right for a read and wrong for a
    /// write, so the two paths take different descriptors and `fetchForMutation` is the
    /// only one a write may use.
    ///
    /// This is every key in `CNContact.h` bar one. `CNContactNoteKey` is not merely
    /// omitted here, it is **unfetchable** by this binary at all: asking for it throws the
    /// entire fetch without an entitlement Apple grants only to provisioned apps (see the
    /// TCC notes). If a contact that *carries* a note still fails to save, that is the
    /// remaining suspect and there is no route to it from here.
    private static var mutationKeys: [CNKeyDescriptor] {
        detailKeys + [CNContactImageDataKey as CNKeyDescriptor]
    }

    // MARK: Reads

    public func search(query: String, limit: Int, offset: Int) async throws -> ContactSearchPage {
        let store = Self.shared
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var matches = try predicateMatches(for: trimmed, in: store)
        // Contacts offers no predicate for organisation, nickname or job title, and
        // compound predicates are unsupported. Scanning is the only way to answer
        // "who works at Neo", so it runs as a fallback rather than as the fast path.
        if matches.isEmpty {
            matches = try scanMatches(for: trimmed, in: store)
        }
        return page(from: Array(matches.values), limit: limit, offset: offset)
    }

    /// Runs the three predicates Contacts does support and unions them by identifier.
    private func predicateMatches(for query: String, in store: CNContactStore) throws
        -> [String: CNContact]
    {
        var found: [String: CNContact] = [:]
        var predicates: [NSPredicate] = [CNContact.predicateForContacts(matchingName: query)]
        if query.contains("@") {
            predicates.append(CNContact.predicateForContacts(matchingEmailAddress: query))
        }
        if query.contains(where: \.isNumber) {
            let number = CNPhoneNumber(stringValue: query)
            predicates.append(CNContact.predicateForContacts(matching: number))
        }

        for predicate in predicates {
            // A predicate that matches nothing throws on some backends instead of
            // returning an empty array, so a failure here is not fatal to the search.
            let hits =
                (try? store.unifiedContacts(matching: predicate, keysToFetch: Self.summaryKeys))
                ?? []
            for contact in hits { found[contact.identifier] = contact }
        }
        return found
    }

    /// Full enumeration filtered in memory. Only reached when the predicates found
    /// nothing, which keeps the common case off this path.
    private func scanMatches(for query: String, in store: CNContactStore) throws
        -> [String: CNContact]
    {
        guard !query.isEmpty else { return [:] }
        var found: [String: CNContact] = [:]
        let request = CNContactFetchRequest(keysToFetch: Self.summaryKeys)
        try store.enumerateContacts(with: request) { contact, _ in
            let haystack = [
                contact.givenName, contact.middleName, contact.familyName, contact.nickname,
                contact.organizationName,
            ].joined(separator: " ")
            if haystack.localizedCaseInsensitiveContains(query) {
                found[contact.identifier] = contact
            }
        }
        return found
    }

    public func all(list: String?, limit: Int, offset: Int) async throws -> ContactSearchPage {
        let store = Self.shared
        let request = CNContactFetchRequest(keysToFetch: Self.summaryKeys)
        if let list {
            request.predicate = CNContact.predicateForContactsInGroup(
                withIdentifier: try group(matching: list, in: store).identifier)
        }

        var found: [CNContact] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in found.append(contact) }
        } catch {
            throw ToolError.storeFailure(Self.describe(error))
        }
        return page(from: found, limit: limit, offset: offset)
    }

    /// Sorts by display name and cuts the requested window out of the result.
    ///
    /// The display name is formatted once per contact, not twice per comparison:
    /// CNContactFormatter inside a sort predicate is O(n log n) formatter builds, and
    /// an unfiltered enumeration can put the whole address book through it.
    private func page(from contacts: [CNContact], limit: Int, offset: Int) -> ContactSearchPage {
        let ordered = contacts
            .map { (name: displayName($0), contact: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let window = ordered.dropFirst(offset).prefix(limit)
            .map { summary(from: $0.contact, displayName: $0.name) }
        return ContactSearchPage(results: Array(window), total: ordered.count)
    }

    public func fetch(id: String) async throws -> ContactDetail? {
        try record(id: id, in: Self.shared, includingNote: true)
    }

    /// `includingNote` exists because reading a note is not free: it is an Apple event
    /// that launches Contacts.app. A caller that will not print the note should not pay
    /// for it, and should not make Contacts.app appear as a side effect of something
    /// unrelated to notes.
    private func record(id: String, in store: CNContactStore, includingNote: Bool) throws
        -> ContactDetail?
    {
        guard let contact = try fetchContact(id: id, in: store) else { return nil }
        var record = detail(from: contact)
        record.lists = listNames(for: contact, in: store)
        if includingNote { record.note = notes.read(id: contact.identifier) }
        return record
    }

    /// Fetches by the singular identifier API rather than a one-element predicate array.
    ///
    /// `unifiedContacts(matching:keysToFetch:)` is documented as the batch fetch —
    /// `CNContact.predicateForContacts(withIdentifiers:)`'s own header comment calls it
    /// "to fetch a *batch* of contacts by identifiers" — while
    /// `unifiedContact(withIdentifier:keysToFetch:)` is the one built for exactly this
    /// call: one identifier in, one contact out, with a defined error
    /// (`CNErrorCodeRecordDoesNotExist`) when it is missing. Every caller here fetches to
    /// hand the result to `CNSaveRequest` moments later, so using the API shaped for a
    /// single record is the safer match for a single-record save, not merely a style
    /// preference.
    private func fetchContact(id: String, in store: CNContactStore) throws -> CNContact? {
        try fetchContact(id: id, in: store, keys: Self.detailKeys)
    }

    /// The fetch every write path must use. See `mutationKeys` for why a save needs a
    /// wider descriptor than a read: a narrowly-fetched contact saves as "Cocoa error
    /// 134092" once Contacts tries to resolve a fault while reindexing it.
    ///
    /// `changeMembership` uses it too, even though adding someone to a List changes no
    /// field on the contact: the membership save still validates the contact object and
    /// still runs the same `willSave`, so it fails in exactly the same way.
    private func fetchForMutation(id: String, in store: CNContactStore) throws -> CNContact? {
        try fetchContact(id: id, in: store, keys: Self.mutationKeys)
    }

    private func fetchContact(id: String, in store: CNContactStore, keys: [CNKeyDescriptor])
        throws -> CNContact?
    {
        do {
            return try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
        } catch let error as CNError where error.code == .recordDoesNotExist {
            return nil
        } catch {
            throw ToolError.storeFailure(Self.describe(error))
        }
    }

    /// The best available description of a failure.
    ///
    /// A `ToolError` — the shape `ContactsAppScripting` throws when `osascript` itself fails
    /// — already carries its own composed `.message`; using `error.localizedDescription`
    /// on it instead would lose that message entirely, because `ToolError` carries no
    /// `LocalizedError` conformance and bridges to a generic, useless NSError string.
    /// Everything else goes through `diagnostic(for:)` for the full Contacts.framework
    /// expansion.
    private static func describe(_ error: Error) -> String {
        if let toolError = error as? ToolError { return toolError.message }
        return diagnostic(for: error)
    }

    /// Just enough of an error to identify it, for a failure whose cause is already
    /// understood and explained in words. `diagnostic(for:)` is for the other kind.
    private static func shortCode(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    /// Expands an `NSError` into every diagnostic Contacts is willing to give up.
    ///
    /// `localizedDescription` alone was observed to collapse two unrelated failures — a
    /// missing note entitlement, and (reported live) every `update_contact` call — into
    /// the identical, useless "The operation couldn't be completed. (Cocoa error
    /// 134092.)". That string names no field and no cause. Everything below is
    /// `CNSaveRequest`'s own documented channel for saying which record and which
    /// property actually failed, and none of it may be dropped silently again.
    private static func diagnostic(for error: Error) -> String {
        let nsError = error as NSError
        var lines = [
            "\(nsError.localizedDescription) [domain=\(nsError.domain) code=\(nsError.code)]"
        ]

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append(
                "underlying: domain=\(underlying.domain) code=\(underlying.code) "
                    + underlying.localizedDescription)
        }
        if let keyPaths = nsError.userInfo[CNErrorUserInfoKeyPathsKey] as? [String],
            !keyPaths.isEmpty
        {
            lines.append("affected key paths: \(keyPaths.joined(separator: ", "))")
        }
        if let records = nsError.userInfo[CNErrorUserInfoAffectedRecordsKey] as? [AnyObject],
            !records.isEmpty
        {
            lines.append(
                "affected records: \(records.map { String(describing: $0) }.joined(separator: "; "))"
            )
        }
        if let identifiers = nsError.userInfo[CNErrorUserInfoAffectedRecordIdentifiersKey]
            as? [String], !identifiers.isEmpty
        {
            lines.append("affected record identifiers: \(identifiers.joined(separator: ", "))")
        }
        if let validationErrors = nsError.userInfo[CNErrorUserInfoValidationErrorsKey]
            as? [NSError], !validationErrors.isEmpty
        {
            lines.append(
                contentsOf: validationErrors.map {
                    "validation: domain=\($0.domain) code=\($0.code) \($0.localizedDescription)"
                })
        }

        let known: Set<String> = [
            NSUnderlyingErrorKey, CNErrorUserInfoKeyPathsKey, CNErrorUserInfoAffectedRecordsKey,
            CNErrorUserInfoAffectedRecordIdentifiersKey, CNErrorUserInfoValidationErrorsKey,
        ]
        let remainder = nsError.userInfo.filter { !known.contains($0.key) }
        if !remainder.isEmpty {
            lines.append("other userInfo: \(remainder)")
        }

        return lines.joined(separator: " | ")
    }

    public func photo(id: String) async throws -> Data? {
        let store = Self.shared
        let predicate = CNContact.predicateForContacts(withIdentifiers: [id])
        let keys = [CNContactImageDataKey as CNKeyDescriptor]
        guard let contact = try store.unifiedContacts(matching: predicate, keysToFetch: keys).first
        else { throw ToolError.notFound(id: id) }
        return contact.imageData
    }

    // MARK: Lists

    public func lists() async throws -> AddressBookLists {
        let store = Self.shared
        let containers = (try? store.containers(matching: nil)) ?? []
        let defaultIdentifier = store.defaultContainerIdentifier()

        let accounts = containers.map { container in
            ContactAccount(
                id: container.identifier, name: container.name,
                kind: Self.accountKind(container.type),
                isDefault: container.identifier == defaultIdentifier)
        }

        // Walking containers rather than asking each group which container it belongs
        // to: one fetch per account gives the same mapping as one fetch per group, and
        // there are always fewer accounts than lists.
        var lists: [ContactList] = []
        var seen: Set<String> = []
        for container in containers {
            let predicate = CNGroup.predicateForGroupsInContainer(
                withIdentifier: container.identifier)
            for group in (try? store.groups(matching: predicate)) ?? [] {
                seen.insert(group.identifier)
                lists.append(
                    ContactList(
                        id: group.identifier, name: group.name, accountName: container.name,
                        memberCount: memberIdentifiers(ofGroup: group.identifier, in: store).count))
            }
        }
        // A group whose container could not be resolved would otherwise vanish from a
        // listing that claims to be complete.
        for group in (try? store.groups(matching: nil)) ?? [] where !seen.contains(group.identifier)
        {
            lists.append(
                ContactList(
                    id: group.identifier, name: group.name, accountName: nil,
                    memberCount: memberIdentifiers(ofGroup: group.identifier, in: store).count))
        }

        // Unordered on purpose: ordering is presentation, and `Format.lists` does it in
        // one place so the fake and the real store cannot drift apart on it.
        return AddressBookLists(lists: lists, accounts: accounts)
    }

    private static func accountKind(_ type: CNContainerType) -> ContactAccount.Kind {
        switch type {
        case .local: return .local
        case .exchange: return .exchange
        case .cardDAV: return .cardDAV
        case .unassigned: return .unknown
        @unknown default: return .unknown
        }
    }

    /// Resolves what a caller called a list — an identifier or an exact name — to the
    /// group itself.
    private func group(matching reference: String, in store: CNContactStore) throws -> CNGroup {
        let byIdentifier = try? store.groups(
            matching: CNGroup.predicateForGroups(withIdentifiers: [reference]))
        if let hit = byIdentifier?.first { return hit }

        let all = (try? store.groups(matching: nil)) ?? []
        if let hit = all.first(where: {
            $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame
        }) { return hit }

        throw ToolError.listNotFound(reference)
    }

    /// The identifiers of everyone in one list.
    ///
    /// Fetched unified, and with no key but the identifier: this runs once per list on
    /// every `contacts_get`, so it must stay the cheapest fetch Contacts can do.
    private func memberIdentifiers(ofGroup identifier: String, in store: CNContactStore) -> [String]
    {
        let predicate = CNContact.predicateForContactsInGroup(withIdentifier: identifier)
        let members =
            (try? store.unifiedContacts(
                matching: predicate, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]))
            ?? []
        return members.map(\.identifier)
    }

    /// The lists a contact belongs to.
    ///
    /// Contacts keeps no reverse index: `CNContact` has no `groups` property, so the
    /// only route is to ask every list who is in it and invert the answer. Both sides
    /// are fetched unified — mixing unified and individual fetches makes the
    /// identifiers stop comparing equal and every membership silently disappears —
    /// and `isUnifiedWithContactWithIdentifier:` is the documented fallback for when
    /// unification has chosen a different linked record as the primary.
    private func listNames(for contact: CNContact, in store: CNContactStore) -> [String] {
        let groups = (try? store.groups(matching: nil)) ?? []
        return groups.filter { group in
            memberIdentifiers(ofGroup: group.identifier, in: store).contains { member in
                member == contact.identifier
                    || contact.isUnifiedWithContact(withIdentifier: member)
            }
        }
        .map(\.name)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: Conversion into Contacts types

    /// Reverses the localisation applied when a label is read.
    ///
    /// Reads turn Contacts' `_$!<Home>!$_` marker into presentable text, so a caller
    /// that reads a contact and writes it back hands us "home" — or "casa" on a Spanish
    /// Mac. Storing that verbatim would quietly demote a standard label to a custom one
    /// that merely looks the same, and lists are replaced wholesale, so every
    /// read-modify-write would erode them. Anything that matches no standard label is
    /// passed through untouched, which is what makes a genuinely custom label survive.
    private static let standardLabels = [
        CNLabelHome, CNLabelWork, CNLabelSchool, CNLabelOther, CNLabelEmailiCloud,
        CNLabelURLAddressHomePage, CNLabelDateAnniversary, CNLabelPhoneNumberMobile,
        CNLabelPhoneNumberiPhone, CNLabelPhoneNumberMain, CNLabelPhoneNumberHomeFax,
        CNLabelPhoneNumberWorkFax, CNLabelPhoneNumberOtherFax, CNLabelPhoneNumberPager,
        CNLabelPhoneNumberAppleWatch,
    ]

    private static func canonicalLabel(_ label: String?) -> String? {
        guard let label, !label.isEmpty else { return label }
        return standardLabels.first {
            CNLabeledValue<NSString>.localizedString(forLabel: $0)
                .localizedCaseInsensitiveCompare(label) == .orderedSame
        } ?? label
    }

    private static func phoneNumbers(_ values: [LabelledValue]) -> [CNLabeledValue<CNPhoneNumber>] {
        values.map {
            CNLabeledValue(
                label: canonicalLabel($0.label), value: CNPhoneNumber(stringValue: $0.value))
        }
    }

    private static func strings(_ values: [LabelledValue]) -> [CNLabeledValue<NSString>] {
        values.map { CNLabeledValue(label: canonicalLabel($0.label), value: $0.value as NSString) }
    }

    private static func relations(_ values: [LabelledValue]) -> [CNLabeledValue<CNContactRelation>] {
        values.map {
            CNLabeledValue(
                label: canonicalLabel($0.label), value: CNContactRelation(name: $0.value))
        }
    }

    private static func postalAddresses(_ values: [PostalAddress])
        -> [CNLabeledValue<CNPostalAddress>]
    {
        values.map { address in
            let postal = CNMutablePostalAddress()
            postal.street = address.street
            postal.subLocality = address.subLocality
            postal.city = address.city
            postal.subAdministrativeArea = address.subAdministrativeArea
            postal.state = address.state
            postal.postalCode = address.postalCode
            postal.country = address.country
            postal.isoCountryCode = address.isoCountryCode
            return CNLabeledValue(label: canonicalLabel(address.label), value: postal)
        }
    }

    /// The social services Contacts knows by name. Both lists exist to be reversed, not
    /// to restrict: a service matching none of them is a **custom** service and is stored
    /// exactly as given, which is what lets "GitHub" or "Revolut" work at all.
    private static let socialServices = [
        CNSocialProfileServiceFacebook, CNSocialProfileServiceFlickr,
        CNSocialProfileServiceLinkedIn, CNSocialProfileServiceMySpace,
        CNSocialProfileServiceSinaWeibo, CNSocialProfileServiceTencentWeibo,
        CNSocialProfileServiceTwitter, CNSocialProfileServiceYelp,
        CNSocialProfileServiceGameCenter,
    ]

    private static let messageServices = [
        CNInstantMessageServiceAIM, CNInstantMessageServiceFacebook,
        CNInstantMessageServiceGaduGadu, CNInstantMessageServiceGoogleTalk,
        CNInstantMessageServiceICQ, CNInstantMessageServiceJabber,
        CNInstantMessageServiceMSN, CNInstantMessageServiceQQ,
        CNInstantMessageServiceSkype, CNInstantMessageServiceYahoo,
    ]

    /// Reverses the localisation a read applied to a service name — the same hazard as
    /// `canonicalLabel`, and missed for years because most services survive the round
    /// trip unchanged.
    ///
    /// Not all do. `SinaWeibo` reads back as "Sina Weibo" and `GoogleTalk` as "Google
    /// Talk", so a caller that reads a contact and writes it back hands us the display
    /// form. Stored verbatim that becomes a *custom* service that merely looks like the
    /// built-in one, and since value lists replace wholesale, every read-modify-write
    /// would erode them. Measured, not assumed: `localizedString(forService:)` inserts
    /// the space.
    /// `localizedBy` must be the localiser belonging to the same class as `known`:
    /// `CNSocialProfile` and `CNInstantMessageAddress` each localise only their own
    /// services, so crossing them would quietly reverse nothing.
    private static func canonicalService(
        _ service: String, in known: [String], localizedBy localize: (String) -> String
    ) -> String {
        known.first {
            localize($0).localizedCaseInsensitiveCompare(service) == .orderedSame
        } ?? service
    }

    private static func socialProfiles(_ values: [SocialProfile])
        -> [CNLabeledValue<CNSocialProfile>]
    {
        values.map {
            CNLabeledValue(
                label: canonicalLabel($0.label),
                value: CNSocialProfile(
                    urlString: $0.urlString.isEmpty ? nil : $0.urlString,
                    username: $0.username, userIdentifier: $0.userIdentifier,
                    service: canonicalService(
                        $0.service, in: socialServices,
                        localizedBy: CNSocialProfile.localizedString(forService:))))
        }
    }

    private static func instantMessages(_ values: [InstantMessage])
        -> [CNLabeledValue<CNInstantMessageAddress>]
    {
        values.map {
            CNLabeledValue(
                label: canonicalLabel($0.label),
                value: CNInstantMessageAddress(
                    username: $0.username,
                    service: canonicalService(
                        $0.service, in: messageServices,
                        localizedBy: CNInstantMessageAddress.localizedString(forService:))))
        }
    }

    private static func dates(_ values: [LabelledDate]) -> [CNLabeledValue<NSDateComponents>] {
        values.map {
            CNLabeledValue(
                label: canonicalLabel($0.label),
                value: $0.components as NSDateComponents)
        }
    }

    /// nil means "the caller said nothing, leave the field alone". Written once because
    /// the list fields differ only in which Contacts type they convert to, and hand-copied
    /// switches drift the moment one of them gains a rule.
    private func resolved<Source, Value>(
        _ edit: FieldEdit<[Source]>, _ convert: ([Source]) -> [CNLabeledValue<Value>]
    ) -> [CNLabeledValue<Value>]? {
        switch edit {
        case .unchanged: return nil
        case .cleared: return []
        case .set(let values): return convert(values)
        }
    }

    /// Reads a photo off disk. Contacts wants the bytes, and a caller that had to
    /// serialise an image through a tool argument would be paying thousands of tokens
    /// to move a file that is already on this machine.
    private static func imageData(atPath path: String) throws -> Data {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ToolError.badArgument(
                name: "photo_path", reason: "no readable file at '\(path)'")
        }
        return data
    }

    // MARK: Writes

    public func create(_ draft: ContactDraft) async throws -> ContactDetail {
        let contact = CNMutableContact()
        contact.contactType = draft.kind == .organization ? .organization : .person
        contact.namePrefix = draft.namePrefix
        contact.givenName = draft.givenName
        contact.middleName = draft.middleName
        contact.familyName = draft.familyName
        contact.previousFamilyName = draft.previousFamilyName
        contact.nameSuffix = draft.nameSuffix
        contact.nickname = draft.nickname
        contact.phoneticGivenName = draft.phoneticGivenName
        contact.phoneticMiddleName = draft.phoneticMiddleName
        contact.phoneticFamilyName = draft.phoneticFamilyName
        contact.phoneticOrganizationName = draft.phoneticOrganizationName
        contact.organizationName = draft.organization
        contact.jobTitle = draft.jobTitle
        contact.departmentName = draft.department
        contact.phoneNumbers = Self.phoneNumbers(draft.phones)
        contact.emailAddresses = Self.strings(draft.emails)
        contact.urlAddresses = Self.strings(draft.urls)
        contact.postalAddresses = Self.postalAddresses(draft.addresses)
        contact.socialProfiles = Self.socialProfiles(draft.socialProfiles)
        contact.instantMessageAddresses = Self.instantMessages(draft.instantMessages)
        contact.contactRelations = Self.relations(draft.relations)
        contact.birthday = draft.birthday
        contact.dates = Self.dates(draft.dates)
        if !draft.photoPath.isEmpty {
            contact.imageData = try Self.imageData(atPath: draft.photoPath)
        }

        // The note is deliberately not on this contact. Contacts refuses the *entire*
        // save when a note is present without the entitlement — observed live as an
        // opaque "Cocoa error 134092" that named no field and created nothing — so it
        // is written afterwards, through Contacts.app, where it cannot take the rest
        // of the record down with it.
        let store = Self.shared

        // Resolved before anything is created: a bad list name should fail loudly, not
        // leave a contact behind with no way to say which list it never joined.
        let groups = try draft.lists.map { try self.group(matching: $0, in: store) }

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        // In the SAME save as the creation, not a follow-up changeMembership call: this
        // object has no faults yet, so the reindex that trips on a fetched contact's
        // unfetched properties has nothing here to trip on.
        for group in groups { request.addMember(contact, to: group) }
        do {
            try store.execute(request)
        } catch {
            throw ToolError.storeFailure(Self.describe(error))
        }

        // A failure here loses the note but keeps the contact, and the re-read below
        // reports whatever was actually stored: a note that did not make it comes back
        // absent, and the output says why. Throwing instead would claim the contact
        // was not created.
        if !draft.note.isEmpty {
            try? notes.write(draft.note, id: contact.identifier)
        }

        // Re-read rather than returning the draft: Contacts normalises phone numbers
        // and assigns the identifier, so the draft is not what was actually stored.
        return try await fetch(id: contact.identifier) ?? detail(from: contact)
    }

    public func update(id: String, changes: ContactChanges) async throws -> ContactUpdateResult {
        let store = Self.shared
        guard let existing = try fetchForMutation(id: id, in: store) else {
            throw ToolError.notFound(id: id)
        }
        // Snapshotted before `existing` is mutated below, so a caller can compare what a
        // multi-value field held against what it holds now — value lists replace
        // wholesale, and "3 → 1" is the difference between a trim and data loss.
        let before = detail(from: existing)

        // The note goes first, on purpose. It is the one field written through another
        // process, so it is the one that can fail on its own; doing it before anything
        // else means a failure leaves the record exactly as it was and the error is the
        // whole truth.
        var noteWritten = false
        if changes.note != .unchanged {
            let current = notes.read(id: existing.identifier) ?? ""
            do {
                try notes.write(changes.note.applied(to: current), id: existing.identifier)
                noteWritten = true
            } catch {
                throw ToolError.noteFailure(Self.describe(error))
            }
        }

        let contact = existing.mutableCopy() as! CNMutableContact
        if case .set(let kind) = changes.kind {
            contact.contactType = kind == .organization ? .organization : .person
        }
        contact.namePrefix = changes.namePrefix.applied(to: contact.namePrefix)
        contact.givenName = changes.givenName.applied(to: contact.givenName)
        contact.middleName = changes.middleName.applied(to: contact.middleName)
        contact.familyName = changes.familyName.applied(to: contact.familyName)
        contact.previousFamilyName = changes.previousFamilyName.applied(
            to: contact.previousFamilyName)
        contact.nameSuffix = changes.nameSuffix.applied(to: contact.nameSuffix)
        contact.nickname = changes.nickname.applied(to: contact.nickname)
        contact.phoneticGivenName = changes.phoneticGivenName.applied(to: contact.phoneticGivenName)
        contact.phoneticMiddleName = changes.phoneticMiddleName.applied(
            to: contact.phoneticMiddleName)
        contact.phoneticFamilyName = changes.phoneticFamilyName.applied(
            to: contact.phoneticFamilyName)
        contact.phoneticOrganizationName = changes.phoneticOrganizationName.applied(
            to: contact.phoneticOrganizationName)
        contact.organizationName = changes.organization.applied(to: contact.organizationName)
        contact.jobTitle = changes.jobTitle.applied(to: contact.jobTitle)
        contact.departmentName = changes.department.applied(to: contact.departmentName)

        if let phones = resolved(changes.phones, Self.phoneNumbers) { contact.phoneNumbers = phones }
        if let emails = resolved(changes.emails, Self.strings) { contact.emailAddresses = emails }
        if let urls = resolved(changes.urls, Self.strings) { contact.urlAddresses = urls }
        if let addresses = resolved(changes.addresses, Self.postalAddresses) {
            contact.postalAddresses = addresses
        }
        if let profiles = resolved(changes.socialProfiles, Self.socialProfiles) {
            contact.socialProfiles = profiles
        }
        if let messages = resolved(changes.instantMessages, Self.instantMessages) {
            contact.instantMessageAddresses = messages
        }
        if let relations = resolved(changes.relations, Self.relations) {
            contact.contactRelations = relations
        }
        if let dates = resolved(changes.dates, Self.dates) { contact.dates = dates }
        switch changes.birthday {
        case .unchanged: break
        case .cleared: contact.birthday = nil
        case .set(let components): contact.birthday = components
        }
        switch changes.photoPath {
        case .unchanged: break
        case .cleared: contact.imageData = nil
        case .set(let path): contact.imageData = try Self.imageData(atPath: path)
        }

        let request = CNSaveRequest()
        request.update(contact)
        do {
            try store.execute(request)
        } catch {
            // A contact that carries a note cannot be saved through CNSaveRequest at all.
            // Contacts rebuilds the search index during `willSave` and the index reads the
            // note; `CNContactNoteKey` is unfetchable without an entitlement this binary
            // can never hold, so that property is a permanently unresolvable fault and the
            // save dies with Cocoa error 134092 naming nothing. Widening `mutationKeys`
            // cannot help: the key it would need is the one key that is unreachable.
            //
            // Contacts.app owns the data and needs no entitlement, so the edit is retried
            // there. Framework first, because that path covers every field and needs no
            // Automation consent; this one only on proof the framework refused.
            //
            // The failed save applied nothing — Core Data rejects during validation,
            // before any change is pushed — so retrying cannot double-apply.
            // Explained failures get the explanation, not the evidence. The full NSError
            // expansion carries a forty-frame Core Data stack — indispensable while this
            // defect was being diagnosed, pure noise once the cause is known, and it
            // buries the one sentence the caller can act on.
            let unsupported = ContactsAppScripting.unsupportedFields(in: changes)
            guard unsupported.isEmpty else {
                throw ToolError.storeFailure(
                    """
                    This contact carries a note, and Contacts.framework cannot save one \
                    (\(Self.shortCode(error))): the search index it rebuilds on every save \
                    reads the note, and this server is not allowed to fetch that field. \
                    Contacts.app is the only route left, and it cannot write \
                    \(unsupported.joined(separator: ", ")). Nothing was changed — every \
                    other field on this contact can still be updated.
                    """)
            }
            do {
                try notes.update(id: id, changes: changes)
            } catch let fallbackError {
                var detail = Self.describe(error)
                detail += " | Contacts.app could not apply the change either: "
                detail += Self.describe(fallbackError)
                let unapplied = changes.changedFields.filter { $0 != "note" }
                if !unapplied.isEmpty {
                    detail += " | fields not applied: \(unapplied.joined(separator: ", "))"
                }
                if noteWritten {
                    detail += " | the note was already updated before this failed"
                }
                throw ToolError.storeFailure(detail)
            }
        }
        let after = try await fetch(id: id) ?? detail(from: contact)
        return ContactUpdateResult(before: before, after: after)
    }

    public func addToList(id: String, list: String) async throws -> ContactDetail {
        try await changeMembership(id: id, list: list, adding: true)
    }

    public func removeFromList(id: String, list: String) async throws -> ContactDetail {
        try await changeMembership(id: id, list: list, adding: false)
    }

    private func changeMembership(id: String, list: String, adding: Bool) async throws
        -> ContactDetail
    {
        let store = Self.shared
        guard let contact = try fetchForMutation(id: id, in: store) else {
            throw ToolError.notFound(id: id)
        }
        let group = try self.group(matching: list, in: store)

        // Group membership is a row pointing at an INDIVIDUAL contact, never at the
        // unified one. `fetchForMutation` returns a unified contact — the aggregate of a
        // set of linked records — and the asymmetry that follows is brutal:
        // `addMember` resolves it to a primary record and works, while `removeMember`
        // looks for a membership row naming exactly the object it was handed, finds
        // none, removes nothing, and **reports success**. Observed live: a remove that
        // said "removed from ZZTest List" while three separate reads, including a
        // `predicateForContactsInGroup` query, still showed the contact as a member.
        //
        // So membership operates on the individual records, and on all of them: a linked
        // contact can be a member through any one of them. The unified contact is the
        // fallback only when the individual fetch comes back empty, so this can never be
        // worse than what it replaces.
        let individuals = Self.individuals(withIdentifier: id, in: store)
        let members = individuals.isEmpty ? [contact] : individuals

        let request = CNSaveRequest()
        // removeMember drops the membership and leaves the contact alone. The name
        // reads like a deletion and is not one; nothing here can delete a person.
        for member in members {
            if adding {
                request.addMember(member, to: group)
            } else {
                request.removeMember(member, from: group)
            }
        }

        // A framework failure here is not treated as fatal on its own. A contact that
        // carries a note cannot be saved through CNSaveRequest at all — `willSave`
        // reindexes the whole contact regardless of which property is changing, or
        // whether one is, and the reindex trips on the same unresolvable
        // `CNContactNoteKey` fault `update_contact` hits — so this save fails for every
        // noted contact the same way a field update used to. The fallback below has to
        // run whether the framework threw or silently did nothing: both look identical
        // from here, a record that does not show the change that was asked for.
        var frameworkError: Error?
        do {
            try store.execute(request)
        } catch {
            frameworkError = error
        }

        // No note: this tool changes membership and prints membership. Reading the note
        // here would launch Contacts.app for a field the answer never mentions.
        guard var after = try record(id: id, in: store, includingNote: false) else {
            throw ToolError.notFound(id: id)
        }

        // `execute` not throwing is never accepted as proof either: a save that succeeds
        // having done nothing is the worst failure this server can have, because the
        // caller is told the change landed and only finds out otherwise by reading the
        // record back. Measured live: `removeMember` against an iCloud group is accepted
        // and does nothing. Contacts.app is asked directly whenever the record does not
        // yet show what was asked for, regardless of why.
        var usedContactsApp = false
        if after.lists.contains(group.name) != adding {
            do {
                try notes.changeMembership(contactID: id, groupNamed: group.name, adding: adding)
                usedContactsApp = true
            } catch let fallbackError {
                var detail = ""
                if let frameworkError {
                    detail += "Contacts.framework: \(Self.shortCode(frameworkError)) | "
                }
                detail += """
                    Contacts.app could not \(adding ? "add" : "remove") the membership \
                    either: \(Self.describe(fallbackError))

                    If that names a permission problem, grant it in: \
                    System Settings → Privacy & Security → Automation → \
                    "apple-contacts-mcp" → enable "Contacts".
                    """
                throw ToolError.storeFailure(detail)
            }
            guard let recheck = try record(id: id, in: store, includingNote: false) else {
                throw ToolError.notFound(id: id)
            }
            after = recheck
        }

        let isMember = after.lists.contains(group.name)
        guard isMember == adding else {
            // Kept for exactly this last-resort case: the two are still worth knowing
            // when nothing else explains a failure this stubborn. Apple documents that
            // the container lookup itself returns empty for a unified identifier, so
            // "unknown" is expected and not itself a sign of a mismatch.
            let contactContainer = try? store.containers(
                matching: CNContainer.predicateForContainerOfContact(
                    withIdentifier: contact.identifier)
            ).first?.identifier
            let groupContainer = try? store.containers(
                matching: CNContainer.predicateForContainerOfGroup(withIdentifier: group.identifier)
            ).first?.identifier
            throw ToolError.storeFailure(
                """
                The membership did not change: '\(after.displayName)' is \
                \(isMember ? "still" : "still not") in '\(group.name)'\
                \(usedContactsApp ? ", even after asking Contacts.app directly" : ""). \
                Nothing was reported as an error, so this is a silent no-op rather than a \
                refusal. contact container: \(contactContainer ?? "unknown") | group \
                container: \(groupContainer ?? "unknown")
                """)
        }
        return after
    }

    /// The individual (non-unified) records behind an identifier.
    ///
    /// `unifiedContact(withIdentifier:)` returns the aggregate of a set of linked
    /// contacts, and that aggregate is not what a group membership row points at — see
    /// `changeMembership`. `unifyResults = false` is the documented way to get the real
    /// records underneath.
    ///
    /// Returns an empty array rather than throwing: every caller has a working fallback,
    /// and a membership change must not fail merely because this lookup did.
    private static func individuals(withIdentifier id: String, in store: CNContactStore)
        -> [CNContact]
    {
        let request = CNContactFetchRequest(keysToFetch: mutationKeys)
        request.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
        request.unifyResults = false

        var found: [CNContact] = []
        try? store.enumerateContacts(with: request) { contact, _ in found.append(contact) }
        return found
    }

    public func delete(id: String) async throws -> ContactDetail {
        let store = Self.shared
        guard let existing = try fetchForMutation(id: id, in: store) else {
            throw ToolError.notFound(id: id)
        }

        // Snapshot before the delete: afterwards there is nothing left to describe,
        // and a delete that cannot say what it removed is not auditable.
        var snapshot = detail(from: existing)
        snapshot.lists = listNames(for: existing, in: store)
        snapshot.note = notes.read(id: existing.identifier)

        let request = CNSaveRequest()
        request.delete(existing.mutableCopy() as! CNMutableContact)
        do {
            try store.execute(request)
        } catch {
            throw ToolError.storeFailure(Self.describe(error))
        }
        return snapshot
    }

    // MARK: Conversion out of Contacts types

    private func displayName(_ contact: CNContact) -> String {
        if let formatted = CNContactFormatter.string(from: contact, style: .fullName),
            !formatted.isEmpty
        {
            return formatted
        }
        if !contact.organizationName.isEmpty { return contact.organizationName }
        if !contact.nickname.isEmpty { return contact.nickname }
        return "(no name)"
    }

    private func summary(from contact: CNContact, displayName name: String) -> ContactSummary {
        ContactSummary(
            id: contact.identifier,
            displayName: name,
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
            phone: contact.phoneNumbers.first?.value.stringValue,
            email: contact.emailAddresses.first.map { $0.value as String }
        )
    }

    private func labelled<T>(_ values: [CNLabeledValue<T>], _ extract: (T) -> String)
        -> [LabelledValue]
    {
        values.map {
            LabelledValue(label: Self.localized($0.label), value: extract($0.value))
        }
    }

    private static func localized(_ label: String?) -> String? {
        label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) }
    }

    private func detail(from contact: CNContact) -> ContactDetail {
        ContactDetail(
            id: contact.identifier,
            displayName: displayName(contact),
            kind: contact.isKeyAvailable(CNContactTypeKey) && contact.contactType == .organization
                ? .organization : .person,
            namePrefix: contact.isKeyAvailable(CNContactNamePrefixKey) ? contact.namePrefix : "",
            givenName: contact.givenName,
            middleName: contact.middleName,
            familyName: contact.familyName,
            previousFamilyName: contact.isKeyAvailable(CNContactPreviousFamilyNameKey)
                ? contact.previousFamilyName : "",
            nameSuffix: contact.isKeyAvailable(CNContactNameSuffixKey) ? contact.nameSuffix : "",
            nickname: contact.nickname,
            phoneticGivenName: contact.isKeyAvailable(CNContactPhoneticGivenNameKey)
                ? contact.phoneticGivenName : "",
            phoneticMiddleName: contact.isKeyAvailable(CNContactPhoneticMiddleNameKey)
                ? contact.phoneticMiddleName : "",
            phoneticFamilyName: contact.isKeyAvailable(CNContactPhoneticFamilyNameKey)
                ? contact.phoneticFamilyName : "",
            phoneticOrganizationName: contact.isKeyAvailable(CNContactPhoneticOrganizationNameKey)
                ? contact.phoneticOrganizationName : "",
            organization: contact.organizationName,
            jobTitle: contact.isKeyAvailable(CNContactJobTitleKey) ? contact.jobTitle : "",
            department: contact.isKeyAvailable(CNContactDepartmentNameKey)
                ? contact.departmentName : "",
            phones: labelled(contact.phoneNumbers) { $0.stringValue },
            emails: labelled(contact.emailAddresses) { $0 as String },
            urls: contact.isKeyAvailable(CNContactUrlAddressesKey)
                ? labelled(contact.urlAddresses, { $0 as String }) : [],
            addresses: contact.isKeyAvailable(CNContactPostalAddressesKey)
                ? contact.postalAddresses.map { entry in
                    PostalAddress(
                        label: Self.localized(entry.label),
                        street: entry.value.street, subLocality: entry.value.subLocality,
                        city: entry.value.city,
                        subAdministrativeArea: entry.value.subAdministrativeArea,
                        state: entry.value.state, postalCode: entry.value.postalCode,
                        country: entry.value.country,
                        isoCountryCode: entry.value.isoCountryCode)
                } : [],
            socialProfiles: contact.isKeyAvailable(CNContactSocialProfilesKey)
                ? contact.socialProfiles.map { entry in
                    SocialProfile(
                        label: Self.localized(entry.label),
                        service: CNSocialProfile.localizedString(forService: entry.value.service),
                        username: entry.value.username, urlString: entry.value.urlString,
                        userIdentifier: entry.value.userIdentifier)
                } : [],
            instantMessages: contact.isKeyAvailable(CNContactInstantMessageAddressesKey)
                ? contact.instantMessageAddresses.map { entry in
                    InstantMessage(
                        label: Self.localized(entry.label),
                        service: CNInstantMessageAddress.localizedString(
                            forService: entry.value.service),
                        username: entry.value.username)
                } : [],
            relations: contact.isKeyAvailable(CNContactRelationsKey)
                ? labelled(contact.contactRelations, { $0.name }) : [],
            birthday: contact.isKeyAvailable(CNContactBirthdayKey) ? contact.birthday : nil,
            nonGregorianBirthday: contact.isKeyAvailable(CNContactNonGregorianBirthdayKey)
                ? contact.nonGregorianBirthday : nil,
            dates: contact.isKeyAvailable(CNContactDatesKey)
                ? contact.dates.map {
                    LabelledDate(label: Self.localized($0.label), components: $0.value as DateComponents)
                } : [],
            photo: Self.photoInfo(contact),
            note: nil
        )
    }

    /// Presence and thumbnail size only — the original is never fetched here. A
    /// contact whose photo exists but whose thumbnail did not come back still reports
    /// a photo, at zero bytes, because "there is one" is the part that matters.
    private static func photoInfo(_ contact: CNContact) -> PhotoInfo? {
        guard contact.isKeyAvailable(CNContactImageDataAvailableKey), contact.imageDataAvailable
        else { return nil }
        let thumbnail =
            contact.isKeyAvailable(CNContactThumbnailImageDataKey)
            ? contact.thumbnailImageData : nil
        return PhotoInfo(thumbnailByteCount: thumbnail?.count ?? 0)
    }
}
