import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// Two rules shape this type. An absent key and an explicit `null` mean different things
/// to an edit: omitting `job_title` leaves it alone, passing `job_title: null` empties it,
/// and every edit accessor below keeps that distinction. Everywhere else `null` means "not
/// given". And nothing is ever read leniently: a value of the wrong type is refused with
/// the form expected, because ignoring it would do something other than what was asked.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call
/// and never leaves it.
public final class Arguments {
    private let values: [String: Value]

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    // MARK: Scalars

    /// `nil` when the argument is absent or null, which mean the same outside an edit.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    private static func text(_ raw: Value, _ name: String) throws -> String {
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func requiredString(_ name: String) throws -> String {
        guard let raw = given(name) else { throw ToolError.missingArgument(name) }
        let trimmed = try Self.text(raw, name)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    /// `nil` when the argument is absent, null or empty text.
    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        let trimmed = try Self.text(raw, name)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool) throws -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    /// A quantity: a size, a count. Outside its range it is moved to the nearest allowed
    /// value, and `notices` gains the sentence that says which value was used. A model
    /// asking for 500 results wants as many as it can have, and failing the call would
    /// teach it nothing the notice does not.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = given(name) else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    /// One text member of an item of a list, or `nil` when the item does not carry it.
    private static func member(_ key: String, of object: [String: Value], in name: String) throws
        -> String?
    {
        guard let raw = object[key], !raw.isNull else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "\"\(key)\" must be text in every item")
        }
        return text
    }

    // MARK: Labelled values

    /// Accepts `["+34 …"]` or `[{"value": "+34 …", "label": "home"}]`. Both forms turn
    /// up in practice depending on how the model reads the schema, and rejecting the
    /// bare-string form buys nothing.
    public func labelledValues(_ name: String) throws -> [LabelledValue]? {
        try objectList(name) { entry in
            if let text = entry.stringValue {
                return LabelledValue(label: nil, value: text)
            }
            guard let object = entry.objectValue,
                let value = try Self.member("value", of: object, in: name)
            else {
                throw ToolError.badArgument(
                    name: name,
                    reason: "each item must be a string, or an object with a \"value\" key")
            }
            return LabelledValue(label: try Self.member("label", of: object, in: name), value: value)
        }
    }

    /// Accepts `["2015-06-01"]` or `[{"label": "anniversary", "value": "2015-06-01"}]`,
    /// mirroring `labelledValues` so a caller does not have to learn a second shape.
    public func labelledDates(_ name: String) throws -> [LabelledDate]? {
        try objectList(name) { entry in
            if let text = entry.stringValue {
                return LabelledDate(label: nil, components: try Self.dateComponents(text, name))
            }
            guard let object = entry.objectValue,
                let value = try Self.member("value", of: object, in: name)
            else {
                throw ToolError.badArgument(
                    name: name,
                    reason: "each item must be a date, or an object with a \"value\" key")
            }
            return LabelledDate(
                label: try Self.member("label", of: object, in: name),
                components: try Self.dateComponents(value, name))
        }
    }

    /// `service` is the only required key: a profile that carries a URL but no username
    /// is a real thing Contacts stores, and rejecting it would lose data on a
    /// read-modify-write.
    public func socialProfiles(_ name: String) throws -> [SocialProfile]? {
        try objectList(name) { entry in
            guard let object = entry.objectValue,
                let service = try Self.member("service", of: object, in: name)
            else {
                throw ToolError.badArgument(
                    name: name, reason: "each item must be an object with a \"service\" key")
            }
            let username = try Self.member("username", of: object, in: name) ?? ""
            let url = try Self.member("url", of: object, in: name) ?? ""
            guard !username.isEmpty || !url.isEmpty else {
                throw ToolError.badArgument(
                    name: name, reason: "each item needs a \"username\" or a \"url\"")
            }
            return SocialProfile(
                label: try Self.member("label", of: object, in: name), service: service,
                username: username, urlString: url,
                userIdentifier: try Self.member("user_identifier", of: object, in: name) ?? "")
        }
    }

    public func instantMessages(_ name: String) throws -> [InstantMessage]? {
        try objectList(name) { entry in
            guard let object = entry.objectValue,
                let service = try Self.member("service", of: object, in: name),
                let username = try Self.member("username", of: object, in: name)
            else {
                throw ToolError.badArgument(
                    name: name,
                    reason: "each item must be an object with \"service\" and \"username\" keys")
            }
            return InstantMessage(
                label: try Self.member("label", of: object, in: name), service: service,
                username: username)
        }
    }

    /// Every component is optional: a postal address holding only a country is still a
    /// postal address, and Contacts stores it happily.
    public func postalAddresses(_ name: String) throws -> [PostalAddress]? {
        try objectList(name) { entry in
            guard let object = entry.objectValue else {
                throw ToolError.badArgument(
                    name: name, reason: "each item must be an object with address components")
            }
            let field = { (key: String) in try Self.member(key, of: object, in: name) ?? "" }
            let address = PostalAddress(
                label: try Self.member("label", of: object, in: name),
                street: try field("street"), subLocality: try field("sub_locality"),
                city: try field("city"),
                subAdministrativeArea: try field("sub_administrative_area"),
                state: try field("state"), postalCode: try field("postal_code"),
                country: try field("country"), isoCountryCode: try field("iso_country_code"))
            guard !address.oneLine.isEmpty else {
                throw ToolError.badArgument(
                    name: name, reason: "each item needs at least one address component")
            }
            return address
        }
    }

    /// The shared spine of every list parser: absent stays absent, an explicit null is
    /// an empty list, and a non-array is a mistake worth naming.
    private func objectList<T>(_ name: String, _ transform: (Value) throws -> T) throws -> [T]? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return [] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array was expected")
        }
        return try entries.map(transform)
    }

    // MARK: Edits

    /// Anything but text or null is refused: taking it for "not given" would report an
    /// update as made while leaving the field as it was.
    public func stringEdit(_ name: String) throws -> FieldEdit<String> {
        guard let raw = values[name] else { return .unchanged }
        if case .null = raw { return .cleared }
        let trimmed = try Self.text(raw, name)
        return trimmed.isEmpty ? .cleared : .set(trimmed)
    }

    public func labelledEdit(_ name: String) throws -> FieldEdit<[LabelledValue]> {
        Self.listEdit(try labelledValues(name))
    }

    public func dateEdit(_ name: String) throws -> FieldEdit<[LabelledDate]> {
        Self.listEdit(try labelledDates(name))
    }

    public func socialProfileEdit(_ name: String) throws -> FieldEdit<[SocialProfile]> {
        Self.listEdit(try socialProfiles(name))
    }

    public func instantMessageEdit(_ name: String) throws -> FieldEdit<[InstantMessage]> {
        Self.listEdit(try instantMessages(name))
    }

    public func addressEdit(_ name: String) throws -> FieldEdit<[PostalAddress]> {
        Self.listEdit(try postalAddresses(name))
    }

    /// An empty list is the way to clear one, exactly as `""` clears a text field.
    private static func listEdit<T: Sendable & Equatable>(_ parsed: [T]?) -> FieldEdit<[T]> {
        guard let parsed else { return .unchanged }
        return parsed.isEmpty ? .cleared : .set(parsed)
    }

    /// There is nothing to clear here: a contact is a person or a company, never
    /// neither, so this edit has no `.cleared` case.
    public func kindEdit(_ name: String) throws -> FieldEdit<ContactKind> {
        guard let raw = try optionalString(name) else { return .unchanged }
        guard let kind = ContactKind(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: name,
                reason: "expected \(ContactKind.allCases.map(\.rawValue).joined(separator: " or "))")
        }
        return .set(kind)
    }

    public func birthdayEdit(_ name: String) throws -> FieldEdit<DateComponents> {
        switch try stringEdit(name) {
        case .unchanged: return .unchanged
        case .cleared: return .cleared
        case .set(let text): return .set(try Self.dateComponents(text, name))
        }
    }

    // MARK: Dates

    /// Only `YYYY-MM-DD` and `--MM-DD`. The second form is how a date with no known
    /// year is written, which Contacts stores and this server must not invent a year
    /// for.
    public func birthday(_ name: String) throws -> DateComponents? {
        guard let raw = try optionalString(name) else { return nil }
        return try Self.dateComponents(raw, name)
    }

    /// A leap year, so that 29 February with no year is a day that exists.
    private static let yearForDatesWithoutOne = 2000

    /// Whether the Gregorian calendar has that day: 31 April and, outside a leap year,
    /// 29 February do not exist, and Contacts would store either as given.
    private static func exists(year: Int, month: Int, day: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return (1...9999).contains(year)
            && DateComponents(calendar: calendar, year: year, month: month, day: day).isValidDate
    }

    static func dateComponents(_ raw: String, _ name: String) throws -> DateComponents {
        if raw.hasPrefix("--") {
            let parts = raw.dropFirst(2).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
                exists(year: yearForDatesWithoutOne, month: month, day: day)
            else {
                throw ToolError.badArgument(
                    name: name,
                    reason: "expected --MM-DD for a date with no year, naming a day that month has")
            }
            return DateComponents(month: month, day: day)
        }

        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
            let day = Int(parts[2]), exists(year: year, month: month, day: day)
        else {
            throw ToolError.badArgument(
                name: name,
                reason: "expected YYYY-MM-DD, or --MM-DD when the year is unknown, naming a date that exists")
        }
        return DateComponents(year: year, month: month, day: day)
    }
}
