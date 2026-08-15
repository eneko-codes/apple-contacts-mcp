import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
///
/// The one rule that shapes this type: an absent key and an explicit `null` mean
/// different things. Omitting `job_title` leaves it alone; passing `job_title: null`
/// empties it. Every accessor below preserves that distinction instead of collapsing
/// both to nil.
public struct Arguments {
    private let values: [String: Value]

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) -> String? {
        values[name]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    /// Clamps rather than rejects. A model asking for 500 results wants "as many as
    /// you will give me", and failing the call teaches it nothing the cap does not.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    // MARK: Labelled values

    /// Accepts `["+34 …"]` or `[{"value": "+34 …", "label": "home"}]`. Both forms turn
    /// up in practice depending on how the model reads the schema, and rejecting the
    /// bare-string form buys nothing.
    public func labelledValues(_ name: String) throws -> [LabelledValue]? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return [] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array was expected")
        }
        return try entries.map { entry in
            if let text = entry.stringValue {
                return LabelledValue(label: nil, value: text)
            }
            guard let object = entry.objectValue, let value = object["value"]?.stringValue else {
                throw ToolError.badArgument(
                    name: name,
                    reason: "each item must be a string, or an object with a \"value\" key")
            }
            return LabelledValue(label: object["label"]?.stringValue, value: value)
        }
    }

    /// Accepts `["2015-06-01"]` or `[{"label": "anniversary", "value": "2015-06-01"}]`,
    /// mirroring `labelledValues` so a caller does not have to learn a second shape.
    public func labelledDates(_ name: String) throws -> [LabelledDate]? {
        try objectList(name) { entry in
            if let text = entry.stringValue {
                return LabelledDate(label: nil, components: try Self.dateComponents(text, name))
            }
            guard let object = entry.objectValue, let value = object["value"]?.stringValue else {
                throw ToolError.badArgument(
                    name: name,
                    reason: "each item must be a date, or an object with a \"value\" key")
            }
            return LabelledDate(
                label: object["label"]?.stringValue,
                components: try Self.dateComponents(value, name))
        }
    }

    /// `service` is the only required key: a profile that carries a URL but no username
    /// is a real thing Contacts stores, and rejecting it would lose data on a
    /// read-modify-write.
    public func socialProfiles(_ name: String) throws -> [SocialProfile]? {
        try objectList(name) { entry in
            guard let object = entry.objectValue, let service = object["service"]?.stringValue
            else {
                throw ToolError.badArgument(
                    name: name, reason: "each item must be an object with a \"service\" key")
            }
            let username = object["username"]?.stringValue ?? ""
            let url = object["url"]?.stringValue ?? ""
            guard !username.isEmpty || !url.isEmpty else {
                throw ToolError.badArgument(
                    name: name, reason: "each item needs a \"username\" or a \"url\"")
            }
            return SocialProfile(
                label: object["label"]?.stringValue, service: service, username: username,
                urlString: url, userIdentifier: object["user_identifier"]?.stringValue ?? "")
        }
    }

    public func instantMessages(_ name: String) throws -> [InstantMessage]? {
        try objectList(name) { entry in
            guard let object = entry.objectValue, let service = object["service"]?.stringValue,
                let username = object["username"]?.stringValue
            else {
                throw ToolError.badArgument(
                    name: name,
                    reason: "each item must be an object with \"service\" and \"username\" keys")
            }
            return InstantMessage(
                label: object["label"]?.stringValue, service: service, username: username)
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
            let field = { (key: String) in object[key]?.stringValue ?? "" }
            let address = PostalAddress(
                label: object["label"]?.stringValue,
                street: field("street"), subLocality: field("sub_locality"), city: field("city"),
                subAdministrativeArea: field("sub_administrative_area"), state: field("state"),
                postalCode: field("postal_code"), country: field("country"),
                isoCountryCode: field("iso_country_code"))
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

    public func stringEdit(_ name: String) -> FieldEdit<String> {
        guard let raw = values[name] else { return .unchanged }
        if case .null = raw { return .cleared }
        guard let text = raw.stringValue else { return .unchanged }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let raw = optionalString(name), !raw.isEmpty else { return .unchanged }
        guard let kind = ContactKind(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: name,
                reason: "expected \(ContactKind.allCases.map(\.rawValue).joined(separator: " or "))")
        }
        return .set(kind)
    }

    public func birthdayEdit(_ name: String) throws -> FieldEdit<DateComponents> {
        guard let raw = values[name] else { return .unchanged }
        if case .null = raw { return .cleared }
        guard let text = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return .cleared }
        return .set(try Self.dateComponents(text, name))
    }

    // MARK: Dates

    /// Only `YYYY-MM-DD` and `--MM-DD`. The second form is how a date with no known
    /// year is written, which Contacts stores and this server must not invent a year
    /// for.
    public func birthday(_ name: String) throws -> DateComponents? {
        guard let raw = optionalString(name), !raw.isEmpty else { return nil }
        return try Self.dateComponents(raw, name)
    }

    static func dateComponents(_ raw: String, _ name: String) throws -> DateComponents {
        if raw.hasPrefix("--") {
            let parts = raw.dropFirst(2).split(separator: "-")
            guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
                (1...12).contains(month), (1...31).contains(day)
            else {
                throw ToolError.badArgument(
                    name: name, reason: "expected --MM-DD for a date with no year")
            }
            return DateComponents(month: month, day: day)
        }

        let parts = raw.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
            let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day)
        else {
            throw ToolError.badArgument(
                name: name, reason: "expected YYYY-MM-DD, or --MM-DD when the year is unknown")
        }
        return DateComponents(year: year, month: month, day: day)
    }
}
