import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot
/// be called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Reads carry no verb prefix; writes always start with
/// create_/update_/delete_, so the destructive ones sort together.
public enum ToolCatalog {

    public static let statusName = "contacts_status"
    public static let searchName = "contacts_search"
    public static let allName = "contacts_all"
    public static let listsName = "contacts_lists"
    public static let getName = "contacts_get"
    public static let createName = "create_contact"
    public static let updateName = "update_contact"
    public static let updateListsName = "update_contact_lists"
    public static let deleteName = "delete_contact"

    // Pages. A row's values are shortened to `cellWidth`, so a row has a widest form, and
    // each maximum is a number of rows that fits `ToolStandard.longestResult` even when
    // every value of every row is that wide. Each default makes a call with no optional
    // argument about `ToolStandard.usualPage` or less. `BoundsTests` renders both to hold
    // them to that.
    public static let offsetRange = 0...10_000_000
    public static let contactLimitRange = 1...100
    public static let defaultContactLimit = 25
    public static let listLimitRange = 1...100
    public static let defaultListLimit = 50

    /// The widest a value may be inside a row of a listing, in characters. A longer name,
    /// address or company is shortened to it, so that no single row can outgrow a result;
    /// `contacts_get` returns the value whole.
    public static let cellWidth = 64

    /// The window on one contact's record. The maximum is half the longest result;
    /// `ToolStandard.fitting` shrinks a window whose characters take more UTF-16 units
    /// than that leaves room for.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)
    public static let defaultMaxCharacters = ToolStandard.usualPage

    /// How much of the record a write shows of the contact it wrote. `contacts_get` reads
    /// the rest, from the character where the receipt stopped.
    public static let receiptCharacters = ToolStandard.usualPage

    /// A delete shows as much of the record as one window of `contacts_get` can hold,
    /// because afterwards there is nothing left to read the rest from.
    public static let deleteReceiptCharacters = maxCharactersRange.upperBound

    /// The longest call a delete receipt spells out for recreating the contact. A longer
    /// one would repeat the record above it.
    public static let recreateCallCharacters = 2_000

    /// How many names a sentence lists before it counts the others.
    public static let fewNames = 20

    /// How long a search may spend walking the whole address book when the predicates
    /// Contacts offers found nothing. Past it the search answers with what it has.
    public static let scanTimeLimit = Duration.seconds(20)

    /// What a search that ran out of time is told, in the words of `Notice.partial`.
    static let scanNarrowing =
        "query: a name, an email address or a phone number is found without the scan"

    /// At most this many images in one result, and each no larger than `ContactPhoto` makes.
    public static let photosPerCall = 1

    public static func all() -> [Tool] {
        [status, search, everyone, lists, get, create, update, updateLists, delete]
    }

    /// Whether a tool of this server can change the address book. A name that is not in
    /// the catalogue changes nothing, because it is refused before it reaches the store.
    static func writes(_ name: String) -> Bool {
        all().first { $0.name == name }?.annotations.readOnlyHint == false
    }

    // MARK: Schema helpers

    private static func object(
        properties: [String: Value], required: [String] = []
    ) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        // Contact fields are a closed set; an unrecognised key is a typo the model
        // should hear about rather than a value that vanishes silently.
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String, default def: Bool) -> Value {
        .object([
            "type": .string("boolean"), "description": .string(description),
            "default": .bool(def),
        ])
    }

    private static func choice(_ description: String, _ options: [String]) -> Value {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(options.map { .string($0) }),
        ])
    }

    /// A field an update may also empty.
    ///
    /// `type` is the single string `"string"`, never `["string", "null"]`. Claude
    /// Desktop's schema sanitiser drops a property outright when its `type` is a union,
    /// and the model then receives a bare `{}` it has to guess at. Observed live: text
    /// fields survived that by luck — an unschema'd string is still sent as a string —
    /// while the array fields alongside them were silently stringified and rejected by
    /// `Arguments`. So the clearing affordance is the empty string, which `stringEdit`
    /// already reads as `.cleared`, and the schema stays inside the subset that survives
    /// the trip. An explicit `null` is still honoured for any client that sends one; it
    /// is simply no longer the advertised way to ask.
    private static func clearableString(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String, range: ClosedRange<Int>, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"),
            "description": .string(description),
            "minimum": .int(range.lowerBound),
            "maximum": .int(range.upperBound),
            "default": .int(def),
        ])
    }

    private static func limit(_ things: String, range: ClosedRange<Int>, default def: Int) -> Value {
        integer("Maximum number of \(things) in one page.", range: range, default: def)
    }

    private static let offset = integer(
        """
        Number of rows to skip. A result that does not hold every row says, in its first \
        lines, the offset to pass for the next page.
        """, range: offsetRange, default: 0)

    private static func stringArray(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("string")]),
        ])
    }

    /// A phone/email/url list. Both shapes are accepted so the model can pass the
    /// short form when it has no label to attach.
    ///
    /// `type` is always the single string `"array"` — see `clearableString` for why a
    /// union is unusable here. An update empties the list with `[]`, which
    /// `labelledEdit` already reads as `.cleared`.
    ///
    /// The two accepted item shapes are spelled out in each tool's own description as
    /// well as in this `anyOf`, because the sanitiser flattens `items` to `{}` on the
    /// way to the model. The `anyOf` is kept for clients that do read it; the prose is
    /// what survives for the ones that do not.
    private static func labelledArray(_ description: String) -> Value {
        let item: Value = .object([
            "anyOf": .array([
                .object(["type": .string("string")]),
                .object([
                    "type": .string("object"),
                    "properties": .object([
                        "value": .object(["type": .string("string")]),
                        "label": .object([
                            "type": .string("string"),
                            "description": .string("Label: home, work, mobile…"),
                        ]),
                    ]),
                    "required": .array([.string("value")]),
                ]),
            ])
        ])
        return .object([
            "type": .string("array"),
            "description": .string(description),
            "items": item,
        ])
    }

    /// A list whose items are always objects. Same warning as `labelledArray`: what
    /// `items` says here does not reach the model, so every one of these keys is
    /// repeated in the owning tool's description.
    private static func objectArray(
        _ description: String, properties: [String: Value], required: [String]
    ) -> Value {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ]),
        ])
    }

    // MARK: Shared field groups

    /// The fields create and update both take, in the shape create wants them.
    /// Update re-declares its own because its descriptions have to explain clearing.
    private static let writableLists: [String: Value] = [
        "phones": labelledArray("Phone numbers."),
        "emails": labelledArray("Email addresses."),
        "urls": labelledArray("Websites."),
        "relations": labelledArray("Related people. The label is the relationship."),
        "addresses": objectArray(
            "Postal addresses.",
            properties: [
                "street": .object(["type": .string("string")]),
                "city": .object(["type": .string("string")]),
                "state": .object(["type": .string("string")]),
                "postal_code": .object(["type": .string("string")]),
                "country": .object(["type": .string("string")]),
                "sub_locality": .object(["type": .string("string")]),
                "sub_administrative_area": .object(["type": .string("string")]),
                "iso_country_code": .object(["type": .string("string")]),
                "label": .object(["type": .string("string")]),
            ], required: []),
        "social_profiles": objectArray(
            "Social media profiles.",
            properties: [
                "service": .object(["type": .string("string")]),
                "username": .object(["type": .string("string")]),
                "url": .object(["type": .string("string")]),
                "label": .object(["type": .string("string")]),
            ], required: ["service"]),
        "instant_messages": objectArray(
            "Instant messaging handles.",
            properties: [
                "service": .object(["type": .string("string")]),
                "username": .object(["type": .string("string")]),
                "label": .object(["type": .string("string")]),
            ], required: ["service", "username"]),
        "dates": labelledArray("Other dates such as anniversaries. The label names the date."),
    ]

    /// The prose half of the schema. `items` never reaches the model, so a shape that
    /// is only described in `items` is a shape the model has to guess — which is how
    /// arrays ended up being sent as strings before. Everything nested is spelled out
    /// here instead.
    private static let listShapes = """
        List shapes:
        • phones, emails, urls, relations, dates — each item is either a plain string \
        ("+34 600 123 456") or an object with a label \
        ({"value": "+34 600 123 456", "label": "mobile"}). For relations the value is a \
        person's name and the label is the relationship ("sister"). For dates the value \
        is YYYY-MM-DD, or --MM-DD when the year is unknown.
        • addresses — objects: {"street": "…", "city": "…", "state": "…", \
        "postal_code": "…", "country": "…", "label": "home"}. Also accepted: \
        sub_locality, sub_administrative_area, iso_country_code. Every part is optional \
        but an address needs at least one.
        • social_profiles — objects: {"service": "LinkedIn", "username": "…", \
        "url": "…", "label": "…"}. service is required, plus a username or a url.
        • instant_messages — objects: {"service": "Skype", "username": "…", \
        "label": "…"}. Both service and username are required.
        """

    // MARK: Reads

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    /// Said by every listing whose rows shorten a long value.
    private static let cellHelp = """
        A value longer than \(cellWidth) characters is shortened in its row, and the first \
        lines of the result say so; contacts_get returns it whole.
        """

    static let status = Tool(
        name: statusName,
        title: "Contacts permission status",
        description: """
            Reports whether this server has permission to reach Contacts, and says \
            exactly what to enable and where if it does not. Reads no contact data.

            It reports two separate permissions: Contacts, which every tool needs, and \
            Automation of Contacts.app, which only the note field needs. It also says \
            when Contacts.app holds unsaved changes, which blocks notes until resolved.

            It never raises a consent dialog itself — it reports the permission rather \
            than requesting it. The first other tool you call is what asks.

            Use it when another Contacts tool fails on permissions, or when setting the \
            server up for the first time. Do not use it to look up people.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly)

    static let search = Tool(
        name: searchName,
        title: "Search contacts",
        description: """
            Searches contacts by name, nickname, company, phone number or email address \
            and returns the first \(defaultContactLimit) matches in name order, one line \
            each with its id, first phone, first email and company. When more match than \
            the page holds, the first lines of the result say how many there are and the \
            offset of the next page: pass limit (up to \(contactLimitRange.upperBound)) and \
            offset for the rest. \(cellHelp)

            Always use this before contacts_get: ids are not guessable and change when an \
            account is resynchronised, so they must come from a recent search. To read \
            the whole address book instead of searching it, use contacts_all.

            A name, an email address or a phone number is found directly. When none of \
            those match, the server walks the whole address book comparing names, \
            nicknames and companies, for at most \(scanTimeLimit.components.seconds) \
            seconds: past that the result holds what was found so far, and its first lines \
            say it is partial.
            """,
        inputSchema: object(
            properties: [
                "query": string("Text to look for: a name, company, phone number or email."),
                "limit": limit("matches", range: contactLimitRange, default: defaultContactLimit),
                "offset": offset,
            ],
            required: ["query"]),
        annotations: readOnly)

    static let everyone = Tool(
        name: allName,
        title: "All contacts",
        description: """
            Returns the contacts of the address book in name order, \
            \(defaultContactLimit) to a page, one line per person with its id, first phone, \
            first email and company, and states how many there are in total. When there \
            are more than the page holds, the first lines of the result give the offset \
            of the next page: pass limit (up to \(contactLimitRange.upperBound)) and \
            offset for the rest. list returns only the people in one List; compact prints \
            names and ids only.

            This is the tool for "how many contacts do I have", "who is in Family" \
            and any question that is about the address book as a whole rather than \
            about one person. \(cellHelp)
            """,
        inputSchema: object(properties: [
            "list": string(
                "Only people in this list. The exact name or the id from contacts_lists."),
            "compact": boolean(
                "Print names and ids only, without phone, email or company.", default: false),
            "limit": limit("contacts", range: contactLimitRange, default: defaultContactLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let lists = Tool(
        name: listsName,
        title: "Lists and accounts",
        description: """
            Returns the Lists of the address book (what the API calls groups) in name \
            order, \(defaultListLimit) to a page, each with how many people it holds, its \
            account and its id, followed by the accounts themselves and which one new \
            contacts go to. Lists and accounts are paged together: when either has more \
            than the page holds, the first lines of the result give the offset of the \
            next page: pass limit (up to \(listLimitRange.upperBound)) and offset. A name \
            longer than \(cellWidth) characters is shortened in its row, and the first \
            lines say so.

            Two accounts can each have a list of the same name, so a list is identified \
            by the account it lives in as well as by its name. Use this before \
            contacts_all(list:) or update_contact_lists.
            """,
        inputSchema: object(properties: [
            "limit": limit("lists, and of accounts,", range: listLimitRange, default: defaultListLimit),
            "offset": integer(
                """
                Number of lists, and of accounts, to skip. A result that does not hold \
                every one says, in its first lines, the offset to pass for the next page.
                """, range: offsetRange, default: 0),
        ]),
        annotations: readOnly)

    static let get = Tool(
        name: getName,
        title: "Full contact record",
        description: """
            Returns the record of one contact: every name field, phone numbers, emails, \
            websites, postal addresses, social profiles, instant messaging handles, \
            related people, birthday and other dates, which Lists it belongs to, its id \
            and, last, the note. A record of more than \(defaultMaxCharacters) characters \
            (a long note, usually) comes one window at a time: the first lines of the \
            result say how many characters there are and the character_offset to pass for \
            the rest, and max_characters (up to \(maxCharactersRange.upperBound)) sets the \
            size of a window. The photo is left out unless include_photo is set; the \
            record says whether one exists.

            Needs an id from contacts_search or contacts_all. Do not reuse an id from an \
            earlier conversation without looking it up again.

            The note is read through Contacts.app rather than Contacts.framework, so it \
            needs Automation permission and is unavailable while Contacts.app holds \
            unsaved changes; in either case the rest of the record is still returned and \
            the output says so.

            include_photo adds the photo as \(photosPerCall) JPEG image, reduced to at most \
            \(ContactPhoto.longestSide) pixels on its longer side.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by contacts_search or contacts_all."),
                "include_photo": boolean(
                    "Also return the contact's photo as an image. The record always says "
                        + "whether one exists.", default: false),
                "character_offset": integer(
                    """
                    Number of characters of the record to skip. A result that does not \
                    hold all of it says, in its first lines, the value to pass for the rest.
                    """, range: offsetRange, default: 0),
                "max_characters": integer(
                    "The most characters of the record to return.",
                    range: maxCharactersRange, default: defaultMaxCharacters),
            ],
            required: ["id"]),
        annotations: readOnly)

    // MARK: Writes

    static let create = Tool(
        name: createName,
        title: "Create a contact",
        description: """
            Creates a new contact in the address book and returns the record as Contacts \
            stored it, id first, up to \(receiptCharacters) characters of it; contacts_get \
            reads the rest. Requires at least a given name, family name, organization, \
            phone number or email address.

            Check with contacts_search first that the person is not already there: this \
            server does not detect duplicates, and Contacts will happily store two \
            identical records.

            \(listShapes)

            photo_path is a path to an image file already on this Mac; the file is read \
            here, so the image never has to be pasted into the call.

            lists adds the new contact to one or more Lists in the same save as the \
            creation itself — prefer this over a follow-up update_contact_lists call.
            """,
        inputSchema: object(properties: [
            "contact_type": choice(
                "Whether this record is a person or a company.",
                ContactKind.allCases.map(\.rawValue)),
            "lists": stringArray(
                "Lists to add this contact to, by exact name or by id from contacts_lists."),
            "name_prefix": string("Title before the name, such as Dr."),
            "given_name": string("First name."),
            "middle_name": string("Middle name."),
            "family_name": string("Last name."),
            "previous_family_name": string("Maiden or former last name."),
            "name_suffix": string("Suffix after the name, such as Jr."),
            "nickname": string("Nickname."),
            "phonetic_given_name": string("How the first name is pronounced."),
            "phonetic_middle_name": string("How the middle name is pronounced."),
            "phonetic_family_name": string("How the last name is pronounced."),
            "phonetic_organization_name": string("How the company name is pronounced."),
            "organization": string("Company or organisation."),
            "job_title": string("Job title."),
            "department": string("Department."),
            "birthday": string("Birthday as YYYY-MM-DD, or --MM-DD when the year is unknown."),
            "photo_path": string(
                "Path to an image file on this Mac to use as the photo. Refused outright "
                    + "if the person who installed this extension turned off photo writes."),
            "note": string("Free-text note. Needs Automation permission; see contacts_get."),
        ].merging(writableLists) { current, _ in current }),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
        )
    )

    static let update = Tool(
        name: updateName,
        title: "Modify a contact",
        description: """
            Changes fields on an existing contact and returns the fields changed, the \
            record as it now stands, up to \(receiptCharacters) characters of it \
            (contacts_get reads the rest), and how many entries each list that was touched \
            held before and after. Omitting a field leaves it as it is. Lists are replaced \
            wholesale, not appended to.

            Read the contact with contacts_get first if you are touching a list: passing \
            only the new phone number discards the others.

            To empty a field, pass "" for a text field and [] for a list.

            \(listShapes)

            note replaces the whole note. contacts_get returns a long note one window at \
            a time: read all of it before writing it back, or the part that was not read \
            is lost.

            This tool does not change which Lists a person belongs to — that is \
            update_contact_lists.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by contacts_search or contacts_all."),
                "contact_type": choice(
                    "Whether this record is a person or a company.",
                    ContactKind.allCases.map(\.rawValue)),
                "name_prefix": clearableString("Title before the name. \"\" clears it."),
                "given_name": clearableString("First name. \"\" clears it."),
                "middle_name": clearableString("Middle name. \"\" clears it."),
                "family_name": clearableString("Last name. \"\" clears it."),
                "previous_family_name": clearableString("Former last name. \"\" clears it."),
                "name_suffix": clearableString("Suffix after the name. \"\" clears it."),
                "nickname": clearableString("Nickname. \"\" clears it."),
                "phonetic_given_name": clearableString("First-name pronunciation. \"\" clears it."),
                "phonetic_middle_name": clearableString(
                    "Middle-name pronunciation. \"\" clears it."),
                "phonetic_family_name": clearableString("Last-name pronunciation. \"\" clears it."),
                "phonetic_organization_name": clearableString(
                    "Company-name pronunciation. \"\" clears it."),
                "organization": clearableString("Company. \"\" clears it."),
                "job_title": clearableString("Job title. \"\" clears it."),
                "department": clearableString("Department. \"\" clears it."),
                "birthday": clearableString(
                    "Birthday as YYYY-MM-DD, or --MM-DD with no year. \"\" clears it."),
                "photo_path": clearableString(
                    "Path to an image file on this Mac. \"\" removes the photo. Refused "
                        + "outright — setting or clearing — if photo writes are turned off."),
                "note": clearableString("Free-text note. \"\" clears it."),
            ].merging(writableLists) { current, _ in current },
            required: ["id"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let updateLists = Tool(
        name: updateListsName,
        title: "Change a contact's lists",
        description: """
            Adds a contact to Lists, removes it from Lists, or both in one call, and \
            returns the Lists it is in afterwards: the first \(fewNames) by name when there \
            are more, which contacts_get shows in full. Name each list by its exact name or \
            by the id from contacts_lists.

            This never deletes anyone. Removing a contact from a list removes only the \
            membership; the contact itself stays in the address book. Use \
            delete_contact for the other thing.

            The lists themselves cannot be created, renamed or deleted here — do that \
            in Contacts.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by contacts_search or contacts_all."),
                "add": stringArray("Lists to add the contact to."),
                "remove": stringArray("Lists to remove the contact from."),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let delete = Tool(
        name: deleteName,
        title: "Delete a contact",
        description: """
            Permanently deletes a contact from the address book. Requires confirm=true \
            and returns the record it removed, up to \(deleteReceiptCharacters) characters \
            of it, together with the call that would recreate it when that call is short.

            There is no trash: Contacts keeps no copy, and whatever of a longer record the \
            result does not show is gone with the contact, so read a long one in full \
            with contacts_get first. Confirm with the person before calling this. To take \
            someone out of a List without deleting them, use update_contact_lists.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by contacts_search or contacts_all."),
                "confirm": boolean(
                    "Must be true. Without it the call is refused.", default: false),
            ],
            required: ["id", "confirm"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )
}
