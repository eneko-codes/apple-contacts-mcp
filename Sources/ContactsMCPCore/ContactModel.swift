import Foundation

/// A value with the label Contacts stores alongside it, e.g. `("casa", "+34 …")`.
///
/// Contacts persists labels as markers like `_$!<Home>!$_`; the store localises them
/// before they reach this type, so `label` is always presentable text or nil.
public struct LabelledValue: Sendable, Equatable {
    public let label: String?
    public let value: String

    public init(label: String?, value: String) {
        self.label = label
        self.value = value
    }
}

/// A date Contacts keeps under a label — an anniversary, a graduation, a leaving date.
///
/// The components are stored rather than a `Date` because Contacts allows a date with
/// no year, exactly as it does for a birthday. Resolving one to a `Date` would have to
/// invent the missing year.
public struct LabelledDate: Sendable, Equatable {
    public let label: String?
    public let components: DateComponents

    public init(label: String?, components: DateComponents) {
        self.label = label
        self.components = components
    }
}

/// A social media account. `service` is Contacts' own service name ("Twitter",
/// "LinkedIn"…); anything outside its known set is stored verbatim and comes back
/// verbatim, so a service this framework has never heard of still round-trips.
public struct SocialProfile: Sendable, Equatable {
    public let label: String?
    public let service: String
    public let username: String
    public let urlString: String
    public let userIdentifier: String

    public init(
        label: String?, service: String, username: String, urlString: String = "",
        userIdentifier: String = ""
    ) {
        self.label = label
        self.service = service
        self.username = username
        self.urlString = urlString
        self.userIdentifier = userIdentifier
    }
}

/// An instant messaging handle. Same open-set rule for `service` as `SocialProfile`.
public struct InstantMessage: Sendable, Equatable {
    public let label: String?
    public let service: String
    public let username: String

    public init(label: String?, service: String, username: String) {
        self.label = label
        self.service = service
        self.username = username
    }
}

/// Whether the record describes a human being or a company.
///
/// Contacts uses this to decide how to display a name: an organization contact shows
/// its company name where a person shows a given and family name.
public enum ContactKind: String, Sendable, Equatable, CaseIterable {
    case person
    case organization
}

/// What is known about a contact's photo without hauling the image itself around.
///
/// The byte count is the *thumbnail's*. Contacts will only report the original's size
/// by handing over the whole original, which is the thing this type exists to avoid
/// doing on every read; `ContactStore.photo(id:)` fetches that on demand.
public struct PhotoInfo: Sendable, Equatable {
    public let thumbnailByteCount: Int

    public init(thumbnailByteCount: Int) {
        self.thumbnailByteCount = thumbnailByteCount
    }
}

public struct PostalAddress: Sendable, Equatable {
    public let label: String?
    public let street: String
    public let subLocality: String
    public let city: String
    public let subAdministrativeArea: String
    public let state: String
    public let postalCode: String
    public let country: String
    public let isoCountryCode: String

    public init(
        label: String?, street: String, subLocality: String = "", city: String,
        subAdministrativeArea: String = "", state: String, postalCode: String,
        country: String, isoCountryCode: String = ""
    ) {
        self.label = label
        self.street = street
        self.subLocality = subLocality
        self.city = city
        self.subAdministrativeArea = subAdministrativeArea
        self.state = state
        self.postalCode = postalCode
        self.country = country
        self.isoCountryCode = isoCountryCode
    }

    /// Single-line rendering for compact output. Empty components are dropped rather
    /// than leaving the stray commas an address template would produce.
    ///
    /// The ISO code stands in for the country only when the country itself is blank —
    /// printing both would read as two different countries on the same envelope.
    public var oneLine: String {
        let country = self.country.isEmpty ? isoCountryCode : self.country
        return [street, subLocality, postalCode, city, subAdministrativeArea, state, country]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// One line of a search result. Carries only what the summary format prints, so a
/// search never pays for fetching fields it will not show.
public struct ContactSummary: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let organization: String?
    public let phone: String?
    public let email: String?

    public init(
        id: String, displayName: String, organization: String?, phone: String?, email: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.organization = organization
        self.phone = phone
        self.email = email
    }
}

/// A list of contacts — what `Contacts.app` calls a List and `Contacts.framework`
/// calls a `CNGroup`. The tools use the interface word because that is what is on
/// screen when someone goes looking for it.
public struct ContactList: Sendable, Equatable {
    public let id: String
    public let name: String
    /// The account the list lives in. A list is meaningless without it: two accounts
    /// may each hold a "Family" and they are not the same list.
    public let accountName: String?
    public let memberCount: Int

    public init(id: String, name: String, accountName: String?, memberCount: Int) {
        self.id = id
        self.name = name
        self.accountName = accountName
        self.memberCount = memberCount
    }
}

/// Where contacts are actually stored — `CNContainer`. One per account: iCloud, an
/// Exchange server, a CardDAV server, or the local "On My Mac" store.
public struct ContactAccount: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case local
        case exchange
        case cardDAV
        case unknown
    }

    public let id: String
    public let name: String
    public let kind: Kind
    /// Where `create_contact` puts a new record when nothing says otherwise.
    public let isDefault: Bool

    public init(id: String, name: String, kind: Kind, isDefault: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isDefault = isDefault
    }
}

public struct ContactDetail: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let kind: ContactKind
    public let namePrefix: String
    public let givenName: String
    public let middleName: String
    public let familyName: String
    public let previousFamilyName: String
    public let nameSuffix: String
    public let nickname: String
    public let phoneticGivenName: String
    public let phoneticMiddleName: String
    public let phoneticFamilyName: String
    public let phoneticOrganizationName: String
    public let organization: String
    public let jobTitle: String
    public let department: String
    public let phones: [LabelledValue]
    public let emails: [LabelledValue]
    public let urls: [LabelledValue]
    public let addresses: [PostalAddress]
    public let socialProfiles: [SocialProfile]
    public let instantMessages: [InstantMessage]
    /// Named people, labelled by how they relate: `("sister", "Ana Fakeperson")`.
    public let relations: [LabelledValue]
    public let birthday: DateComponents?
    /// The birthday in whatever non-Gregorian calendar the owner entered it in.
    /// Contacts keeps this separately from `birthday`, not as a conversion of it.
    public let nonGregorianBirthday: DateComponents?
    public let dates: [LabelledDate]
    public let photo: PhotoInfo?
    /// Names of the lists this contact belongs to. Empty means "in no list"; there is
    /// no third state, because membership is derived by asking every list who is in it.
    ///
    /// Mutable because it is not a property of the contact in Contacts — it is derived
    /// by asking every list who belongs to it, at a cost of one fetch per list. The
    /// store builds the record first and fills this in only where a caller will show
    /// it, rather than paying for it on every read.
    public var lists: [String]
    /// nil when the note could not be read at all. Contacts.framework refuses the
    /// field without an entitlement this binary cannot carry, so the note arrives via
    /// Contacts.app instead — and that route can be switched off in Privacy settings.
    ///
    /// Mutable for the same reason as `lists`: it is fetched by a second route, after
    /// the rest of the record already exists.
    public var note: String?

    public init(
        id: String,
        displayName: String,
        kind: ContactKind = .person,
        namePrefix: String = "",
        givenName: String,
        middleName: String,
        familyName: String,
        previousFamilyName: String = "",
        nameSuffix: String = "",
        nickname: String,
        phoneticGivenName: String = "",
        phoneticMiddleName: String = "",
        phoneticFamilyName: String = "",
        phoneticOrganizationName: String = "",
        organization: String,
        jobTitle: String,
        department: String,
        phones: [LabelledValue],
        emails: [LabelledValue],
        urls: [LabelledValue],
        addresses: [PostalAddress],
        socialProfiles: [SocialProfile] = [],
        instantMessages: [InstantMessage] = [],
        relations: [LabelledValue] = [],
        birthday: DateComponents?,
        nonGregorianBirthday: DateComponents? = nil,
        dates: [LabelledDate] = [],
        photo: PhotoInfo? = nil,
        lists: [String] = [],
        note: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.namePrefix = namePrefix
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.previousFamilyName = previousFamilyName
        self.nameSuffix = nameSuffix
        self.nickname = nickname
        self.phoneticGivenName = phoneticGivenName
        self.phoneticMiddleName = phoneticMiddleName
        self.phoneticFamilyName = phoneticFamilyName
        self.phoneticOrganizationName = phoneticOrganizationName
        self.organization = organization
        self.jobTitle = jobTitle
        self.department = department
        self.phones = phones
        self.emails = emails
        self.urls = urls
        self.addresses = addresses
        self.socialProfiles = socialProfiles
        self.instantMessages = instantMessages
        self.relations = relations
        self.birthday = birthday
        self.nonGregorianBirthday = nonGregorianBirthday
        self.dates = dates
        self.photo = photo
        self.lists = lists
        self.note = note
    }

}

/// Distinguishes "the caller said nothing about this field" from "the caller wants it
/// empty". Without the distinction there is no way to express removing a job title:
/// an omitted key and an explicit null would both arrive as nil.
public enum FieldEdit<Value: Sendable & Equatable>: Sendable, Equatable {
    case unchanged
    case cleared
    case set(Value)

    /// Applies the edit to a current value, for stores that need a plain result.
    public func applied(to current: Value, empty: Value) -> Value {
        switch self {
        case .unchanged: return current
        case .cleared: return empty
        case .set(let new): return new
        }
    }
}

extension FieldEdit where Value == String {
    public func applied(to current: String) -> String { applied(to: current, empty: "") }
}

/// The fields a new contact can be created with. Every field is optional, but a
/// contact with no name and no organisation is rejected before it reaches the store.
public struct ContactDraft: Sendable, Equatable {
    public var kind: ContactKind = .person
    public var namePrefix: String = ""
    public var givenName: String = ""
    public var middleName: String = ""
    public var familyName: String = ""
    public var previousFamilyName: String = ""
    public var nameSuffix: String = ""
    public var nickname: String = ""
    public var phoneticGivenName: String = ""
    public var phoneticMiddleName: String = ""
    public var phoneticFamilyName: String = ""
    public var phoneticOrganizationName: String = ""
    public var organization: String = ""
    public var jobTitle: String = ""
    public var department: String = ""
    public var phones: [LabelledValue] = []
    public var emails: [LabelledValue] = []
    public var urls: [LabelledValue] = []
    public var addresses: [PostalAddress] = []
    public var socialProfiles: [SocialProfile] = []
    public var instantMessages: [InstantMessage] = []
    public var relations: [LabelledValue] = []
    public var birthday: DateComponents?
    public var dates: [LabelledDate] = []
    /// Path to an image file on disk. The bytes are read by the store, so a caller
    /// never has to serialise a photo through a tool argument.
    public var photoPath: String = ""
    public var note: String = ""
    /// Lists to add the new contact to, by exact name or by id, applied in the same
    /// save as the creation itself. Doing it there rather than as a follow-up
    /// `update_contact_lists` call is not only convenient: a just-created
    /// `CNMutableContact` has no Core Data faults to resolve, so folding membership
    /// into the same save sidesteps the reindex failure a *fetched* contact can hit.
    public var lists: [String] = []

    public init() {}

    public var isEmpty: Bool {
        givenName.isEmpty && middleName.isEmpty && familyName.isEmpty && nickname.isEmpty
            && organization.isEmpty && phones.isEmpty && emails.isEmpty
    }
}

/// A partial edit. Collection fields replace wholesale rather than merging: merging
/// would need a stable identity per phone number, which Contacts does not expose in a
/// way the model could address.
public struct ContactChanges: Sendable, Equatable {
    public var kind: FieldEdit<ContactKind> = .unchanged
    public var namePrefix: FieldEdit<String> = .unchanged
    public var givenName: FieldEdit<String> = .unchanged
    public var middleName: FieldEdit<String> = .unchanged
    public var familyName: FieldEdit<String> = .unchanged
    public var previousFamilyName: FieldEdit<String> = .unchanged
    public var nameSuffix: FieldEdit<String> = .unchanged
    public var nickname: FieldEdit<String> = .unchanged
    public var phoneticGivenName: FieldEdit<String> = .unchanged
    public var phoneticMiddleName: FieldEdit<String> = .unchanged
    public var phoneticFamilyName: FieldEdit<String> = .unchanged
    public var phoneticOrganizationName: FieldEdit<String> = .unchanged
    public var organization: FieldEdit<String> = .unchanged
    public var jobTitle: FieldEdit<String> = .unchanged
    public var department: FieldEdit<String> = .unchanged
    public var phones: FieldEdit<[LabelledValue]> = .unchanged
    public var emails: FieldEdit<[LabelledValue]> = .unchanged
    public var urls: FieldEdit<[LabelledValue]> = .unchanged
    public var addresses: FieldEdit<[PostalAddress]> = .unchanged
    public var socialProfiles: FieldEdit<[SocialProfile]> = .unchanged
    public var instantMessages: FieldEdit<[InstantMessage]> = .unchanged
    public var relations: FieldEdit<[LabelledValue]> = .unchanged
    public var birthday: FieldEdit<DateComponents> = .unchanged
    public var dates: FieldEdit<[LabelledDate]> = .unchanged
    public var photoPath: FieldEdit<String> = .unchanged
    public var note: FieldEdit<String> = .unchanged

    public init() {}

    /// The argument names of the fields this edit actually touches, in output order.
    ///
    /// One place pairs a field with the name callers know it by. Building that pairing at
    /// the call site instead meant writing the name twice per field, where a mismatch
    /// compiles cleanly and only shows up as a confirmation message that under-reports
    /// what was changed.
    public var changedFields: [String] {
        var names: [String] = []
        if kind != .unchanged { names.append("contact_type") }
        if namePrefix != .unchanged { names.append("name_prefix") }
        if givenName != .unchanged { names.append("given_name") }
        if middleName != .unchanged { names.append("middle_name") }
        if familyName != .unchanged { names.append("family_name") }
        if previousFamilyName != .unchanged { names.append("previous_family_name") }
        if nameSuffix != .unchanged { names.append("name_suffix") }
        if nickname != .unchanged { names.append("nickname") }
        if phoneticGivenName != .unchanged { names.append("phonetic_given_name") }
        if phoneticMiddleName != .unchanged { names.append("phonetic_middle_name") }
        if phoneticFamilyName != .unchanged { names.append("phonetic_family_name") }
        if phoneticOrganizationName != .unchanged {
            names.append("phonetic_organization_name")
        }
        if organization != .unchanged { names.append("organization") }
        if jobTitle != .unchanged { names.append("job_title") }
        if department != .unchanged { names.append("department") }
        if note != .unchanged { names.append("note") }
        if birthday != .unchanged { names.append("birthday") }
        if phones != .unchanged { names.append("phones") }
        if emails != .unchanged { names.append("emails") }
        if urls != .unchanged { names.append("urls") }
        if addresses != .unchanged { names.append("addresses") }
        if socialProfiles != .unchanged { names.append("social_profiles") }
        if instantMessages != .unchanged { names.append("instant_messages") }
        if relations != .unchanged { names.append("relations") }
        if dates != .unchanged { names.append("dates") }
        if photoPath != .unchanged { names.append("photo_path") }
        return names
    }

    public var isEmpty: Bool { changedFields.isEmpty }
}
