import Foundation
import MCP

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

    public static func all() -> [Tool] {
        [status, search, everyone, lists, get, create, update, updateLists, delete]
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

    private static func boolean(_ description: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(description)])
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

    private static func integer(_ description: String, minimum: Int, maximum: Int, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"),
            "description": .string(description),
            "minimum": .int(minimum),
            "maximum": .int(maximum),
            "default": .int(def),
        ])
    }

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

    static let status = Tool(
        name: statusName,
        title: "Contacts permission status",
        description: """
            Reports whether this server has permission to reach Contacts, and says \
            exactly what to enable and where if it does not. Reads no contact data.

            It reports two separate permissions: Contacts, which every tool needs, and \
            Automation of Contacts.app, which only the note field needs.

            It never raises a consent dialog itself — it reports the permission rather \
            than requesting it. The first other tool you call is what asks.

            Use it when another Contacts tool fails on permissions, or when setting the \
            server up for the first time. Do not use it to look up people.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let search = Tool(
        name: searchName,
        title: "Search contacts",
        description: """
            Searches contacts by name, nickname, company, phone number or email address, \
            and returns one line per match with its id.

            Always use this before contacts_get: ids are not guessable and change when an \
            account is resynchronised, so they must come from a recent search. To read \
            the whole address book instead of searching it, use contacts_all.
            """,
        inputSchema: object(
            properties: [
                "query": string("Text to look for: a name, company, phone number or email."),
                "limit": integer(
                    "Maximum number of results to return.",
                    minimum: Configuration.searchLimitRange.lowerBound,
                    maximum: Configuration.searchLimitRange.upperBound,
                    default: Configuration.searchLimit),
                "offset": integer(
                    "Skip this many matches; use it to ask for the next page.",
                    minimum: Configuration.offsetRange.lowerBound,
                    maximum: Configuration.offsetRange.upperBound, default: 0),
            ],
            required: ["query"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let everyone = Tool(
        name: allName,
        title: "All contacts",
        description: """
            Returns every contact in the address book, sorted by name, one line per \
            person with its id. Pass list to return only the people in one list.

            This is the tool for "how many contacts do I have", "who is in Family" \
            and any question that is about the address book as a whole rather than \
            about one person.

            It always says how many contacts exist in total, so a page that stops \
            short is never mistaken for the whole answer. Use compact=true when you \
            only need names and ids: it prints far less per person, which makes a \
            large page affordable.
            """,
        inputSchema: object(properties: [
            "list": string(
                "Only people in this list. The exact name or the id from contacts_lists."),
            "compact": boolean("Print names and ids only, without phone or company."),
            "limit": integer(
                "Maximum number of contacts to return.",
                minimum: Configuration.listLimitRange.lowerBound,
                maximum: Configuration.listLimitRange.upperBound,
                default: Configuration.searchLimit),
            "offset": integer(
                "Skip this many contacts; use it to ask for the next page.",
                minimum: Configuration.offsetRange.lowerBound,
                maximum: Configuration.offsetRange.upperBound, default: 0),
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let lists = Tool(
        name: listsName,
        title: "Lists and accounts",
        description: """
            Returns the lists in the address book — what Contacts calls Lists and the \
            API calls groups — with how many people each holds, and the accounts they \
            belong to.

            Two accounts can each have a list of the same name, so a list is identified \
            by the account it lives in as well as by its name. Use this before \
            contacts_all(list:) or update_contact_lists.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let get = Tool(
        name: getName,
        title: "Full contact record",
        description: """
            Returns everything stored for one contact: every name field, phone numbers, \
            emails, websites, postal addresses, social profiles, instant messaging \
            handles, related people, birthday and other dates, the note, and which \
            lists the person belongs to.

            Needs an id from contacts_search or contacts_all. Do not reuse an id from an \
            earlier conversation without looking it up again.

            The note is read through Contacts.app rather than Contacts.framework, so it \
            needs Automation permission; when that is missing the rest of the record is \
            still returned and the output says so.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by contacts_search or contacts_all."),
                "include_photo": boolean(
                    "Also return the contact's photo as an image. Off by default: a photo "
                        + "is large, and the record always says whether one exists."),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    // MARK: Writes

    static let create = Tool(
        name: createName,
        title: "Create a contact",
        description: """
            Creates a new contact in the address book. Requires at least a given name, \
            family name, organization, phone number or email address.

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
            Changes fields on an existing contact. Omitting a field leaves it as it is. \
            Lists are replaced wholesale, not appended to.

            Read the contact with contacts_get first if you are touching a list: passing \
            only the new phone number discards the others.

            To empty a field, pass "" for a text field and [] for a list.

            \(listShapes)

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
            Adds a contact to Lists, removes it from Lists, or both in one call. Name \
            each list by its exact name or by the id from contacts_lists.

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
            and returns the full record it removed, together with the call that would \
            recreate it.

            There is no trash: Contacts keeps no copy. Confirm with the person before \
            calling this. To take someone out of a List without deleting them, use \
            update_contact_lists.
            """,
        inputSchema: object(
            properties: [
                "id": string("Identifier returned by contacts_search or contacts_all."),
                "confirm": .object([
                    "type": .string("boolean"),
                    "description": .string("Must be true. Without it the call is refused."),
                ]),
            ],
            required: ["id", "confirm"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )
}
