import Foundation

/// Plain-text rendering of every tool result.
///
/// Search output is one line per hit so a long result set stays scannable; detail
/// output is a labelled block. Nothing here emits JSON: a model reading a wall of
/// braces spends attention on syntax that a table gives away for free.
public enum Format {

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    /// Renders a labelled block: two spaces, a padded label, the value. Multi-line
    /// values are indented to line up under the first line rather than wrapping back
    /// to column zero, where they would read as separate fields.
    ///
    /// Empty values are dropped entirely, which is what keeps a contact holding three
    /// facts from printing twenty blank rows now that every Contacts field is offered.
    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    static func birthday(_ components: DateComponents?) -> String? {
        guard let components, let month = components.month, let day = components.day else {
            return nil
        }
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        guard (1...12).contains(month) else { return nil }
        let dayMonth = String(format: "%02d %@", day, months[month - 1])
        // Contacts stores a birthday with no year when the year is unknown; printing
        // a placeholder year would invent a fact the address book does not hold.
        return components.year.map { "\(dayMonth) \($0)" } ?? dayMonth
    }

    /// One place decides how a label is attached to a value, so phones, emails, websites
    /// and postal addresses cannot end up punctuated differently in the same block.
    static func labelled(_ value: String, _ label: String?) -> String {
        label.map { "\(value) (\($0))" } ?? value
    }

    static func labelledList(_ values: [LabelledValue]) -> String? {
        guard !values.isEmpty else { return nil }
        return values.map { labelled($0.value, $0.label) }.joined(separator: "\n")
    }

    static func joined(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Byte counts appear only next to a photo, where the point is "roughly how big",
    /// not an exact figure worth a rounding library.
    static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) bytes" : String(format: "%.0f KB", Double(bytes) / 1024)
    }

    // MARK: Tools

    public static func searchResults(_ page: ContactSearchPage, query: String, offset: Int)
        -> String
    {
        guard !page.results.isEmpty else {
            return "No contacts match '\(query)'."
        }
        let heading = "\(page.total) contact\(page.total == 1 ? "" : "s") matching '\(query)'"
        return rows(page, heading: heading, offset: offset, compact: false)
    }

    public static func everyone(
        _ page: ContactSearchPage, list: String?, offset: Int, compact: Bool
    ) -> String {
        guard !page.results.isEmpty else {
            return list.map { "No contacts are in '\($0)'." } ?? "The address book is empty."
        }
        var heading = "\(page.total) contact\(page.total == 1 ? "" : "s")"
        if let list { heading += " in '\(list)'" }
        return rows(page, heading: heading, offset: offset, compact: compact)
    }

    /// The shared body of every multi-contact result.
    ///
    /// Columns are padded to the widest value in the page rather than to a fixed width,
    /// so a page of short names does not carry a corridor of spaces.
    private static func rows(
        _ page: ContactSearchPage, heading: String, offset: Int, compact: Bool
    ) -> String {
        var lines = [heading]

        if compact {
            let nameWidth = page.results.map(\.displayName.count).max() ?? 0
            for result in page.results {
                lines.append("\(pad(result.displayName, to: nameWidth))  id=\(result.id)")
            }
        } else {
            let nameWidth = page.results.map(\.displayName.count).max() ?? 0
            let phoneWidth = page.results.compactMap(\.phone?.count).max() ?? 0
            for result in page.results {
                var line = pad(result.displayName, to: nameWidth)
                line += "  " + pad(result.phone ?? "", to: phoneWidth)
                if let email = result.email { line += "  " + email }
                if let organization = result.organization { line += "  [\(organization)]" }
                lines.append(line.trimmingCharacters(in: .whitespaces) + "  id=\(result.id)")
            }
        }

        let shown = offset + page.results.count
        if shown < page.total {
            // Saying nothing here would let a truncated page read as the whole answer.
            lines.append("…\(page.total - shown) more · call again with offset=\(shown)")
        }
        return lines.joined(separator: "\n")
    }

    public static func lists(_ book: AddressBookLists) -> String {
        var sections: [String] = []
        let byName = { (left: String, right: String) in
            left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }

        if book.lists.isEmpty {
            sections.append("No lists. Contacts calls these Lists; the API calls them groups.")
        } else {
            let nameWidth = book.lists.map(\.name.count).max() ?? 0
            var lines = ["\(book.lists.count) list\(book.lists.count == 1 ? "" : "s")"]
            for list in book.lists.sorted(by: { byName($0.name, $1.name) }) {
                var line = pad(list.name, to: nameWidth)
                line += "  \(list.memberCount) "
                line += list.memberCount == 1 ? "person" : "people"
                if let account = list.accountName { line += "  [\(account)]" }
                lines.append(line + "  id=\(list.id)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if !book.accounts.isEmpty {
            var lines = ["Accounts"]
            let nameWidth = book.accounts.map(\.name.count).max() ?? 0
            for account in book.accounts.sorted(by: { byName($0.name, $1.name) }) {
                var line = "  " + pad(account.name, to: nameWidth) + "  \(account.kind.rawValue)"
                if account.isDefault { line += "  (new contacts go here)" }
                lines.append(line)
            }
            sections.append(lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    public static func detail(_ contact: ContactDetail) -> String {
        var rows: [(String, String?)] = [
            ("name", contact.displayName),
            // Printed only for a company: every other record is a person, and saying so
            // on each one would be a row of noise repeated across the whole book.
            ("type", contact.kind == .organization ? "organization" : nil),
            ("prefix", contact.namePrefix),
            ("suffix", contact.nameSuffix),
            ("was", contact.previousFamilyName),
            ("nickname", contact.nickname),
            (
                "pronounced",
                joined(
                    contact.phoneticGivenName, contact.phoneticMiddleName,
                    contact.phoneticFamilyName)
            ),
            ("company", contact.organization),
            ("company said", contact.phoneticOrganizationName),
            (
                "role",
                [contact.jobTitle, contact.department].filter { !$0.isEmpty }
                    .joined(separator: " · ")
            ),
            ("phones", labelledList(contact.phones)),
            ("emails", labelledList(contact.emails)),
            ("urls", labelledList(contact.urls)),
        ]

        if !contact.addresses.isEmpty {
            rows.append(
                (
                    "addresses",
                    contact.addresses.map { labelled($0.oneLine, $0.label) }
                        .joined(separator: "\n")
                ))
        }
        if !contact.socialProfiles.isEmpty {
            rows.append(
                (
                    "social",
                    contact.socialProfiles.map { profile in
                        let handle = profile.username.isEmpty ? profile.urlString : profile.username
                        return "\(profile.service): \(handle)"
                    }.joined(separator: "\n")
                ))
        }
        if !contact.instantMessages.isEmpty {
            rows.append(
                (
                    "messaging",
                    contact.instantMessages.map { "\($0.service): \($0.username)" }
                        .joined(separator: "\n")
                ))
        }
        rows.append(("related", labelledList(contact.relations)))
        rows.append(("birthday", birthday(contact.birthday)))
        rows.append(("birthday (other calendar)", birthday(contact.nonGregorianBirthday)))
        if !contact.dates.isEmpty {
            rows.append(
                (
                    "dates",
                    contact.dates.compactMap { entry in
                        birthday(entry.components).map { labelled($0, entry.label) }
                    }.joined(separator: "\n")
                ))
        }
        rows.append(("lists", contact.lists.isEmpty ? nil : contact.lists.joined(separator: ", ")))
        rows.append(
            (
                "photo",
                contact.photo.map {
                    "yes · thumbnail \(size($0.thumbnailByteCount)) "
                        + "· pass include_photo=true to see it"
                }
            ))
        rows.append(("note", contact.note))
        rows.append(("id", contact.id))

        var text = contact.displayName + "\n" + block(rows)
        if contact.note == nil {
            // A missing note is a permission story, not a fact about this person, and
            // saying nothing would let it read as "this contact has no note".
            text += """


                (The note could not be read. It is the one field that comes from
                Contacts.app rather than Contacts.framework, and that needs Automation
                permission — call contacts_status to see whether it is granted.)
                """
        }
        return text
    }

    public static func created(_ contact: ContactDetail) -> String {
        // `detail`'s block-rendering drops an empty "lists" row silently, which reads
        // as "this section does not apply" on a read. On a creation it reads as
        // something else entirely: the caller cannot tell "born into no list" from
        // "the lists argument was silently ignored", and the second of those was a
        // real, undetected failure mode before create_contact accepted lists at all.
        var text = "Created contact '\(contact.displayName)'.\n\n" + detail(contact)
        if contact.lists.isEmpty {
            text += "\n\n  lists   (none — pass lists: [...] to add it to one)"
        }
        if let warning = selfRelationWarning(contact) { text += "\n\n" + warning }
        return text
    }

    public static func updated(_ result: ContactUpdateResult, fields: [String]) -> String {
        let contact = result.after
        // An update with nothing to change is refused before it reaches the store, so
        // `fields` is never empty here.
        var text =
            "Updated contact '\(contact.displayName)'. Fields changed: "
            + fields.joined(separator: ", ") + ".\n\n" + detail(contact)

        let counts = multiValueCountChanges(from: result.before, to: contact, touching: fields)
        if !counts.isEmpty {
            text += "\n\n" + counts.map { "  \($0.field): \($0.before) → \($0.after)" }
                .joined(separator: "\n")
        }
        if let warning = selfRelationWarning(contact) { text += "\n\n" + warning }
        return text
    }

    /// How many entries each touched multi-value field held before this update, versus
    /// now. These fields replace wholesale rather than merge — passing one relation
    /// discards the other three — and the record afterwards looks identical whether
    /// that was intended or a mistake. Reported for every field named in `fields`,
    /// whether the count grew, shrank or held, so a caller never has to wonder whether
    /// silence meant "nothing happened" or "the count did not seem worth mentioning".
    private static func multiValueCountChanges(
        from before: ContactDetail, to after: ContactDetail, touching fields: [String]
    ) -> [(field: String, before: Int, after: Int)] {
        let counted: [String: (ContactDetail) -> Int] = [
            "phones": { $0.phones.count },
            "emails": { $0.emails.count },
            "urls": { $0.urls.count },
            "addresses": { $0.addresses.count },
            "social_profiles": { $0.socialProfiles.count },
            "instant_messages": { $0.instantMessages.count },
            "relations": { $0.relations.count },
            "dates": { $0.dates.count },
        ]
        return fields.compactMap { field in
            guard let count = counted[field] else { return nil }
            return (field, count(before), count(after))
        }
    }

    /// A relation naming the contact itself is almost certainly a mistake — seen live,
    /// introduced by duplicating a sibling's card and never changing the name on the
    /// copy — and this server cannot know who anyone really is, so it cannot refuse
    /// one. It can compare a string to another string, though, and value lists replace
    /// wholesale, so a self-relation that is never flagged survives every future
    /// update indefinitely. A note, not an error: the record may be exactly what the
    /// owner intended.
    private static func selfRelationWarning(_ contact: ContactDetail) -> String? {
        let matches = contact.relations.filter {
            $0.value.localizedCaseInsensitiveCompare(contact.displayName) == .orderedSame
        }
        guard !matches.isEmpty else { return nil }
        let labels = matches.compactMap(\.label)
        return "Note: this contact is listed as its own relation"
            + (labels.isEmpty ? "" : " (\(labels.joined(separator: ", ")))")
            + " — check whether that was intended."
    }

    /// Reports membership as it now stands rather than as it was asked to be: adding
    /// someone to a list they were already in changes nothing, and a confirmation that
    /// claims otherwise is worse than no confirmation.
    public static func listsChanged(
        _ contact: ContactDetail, added: [String], removed: [String]
    ) -> String {
        var actions: [String] = []
        if !added.isEmpty { actions.append("added to \(added.joined(separator: ", "))") }
        if !removed.isEmpty { actions.append("removed from \(removed.joined(separator: ", "))") }

        var text = "'\(contact.displayName)' \(actions.joined(separator: ", "))."
        text += "\n\n"
        text += block([
            ("name", contact.displayName),
            (
                "lists",
                contact.lists.isEmpty ? "(in no list)" : contact.lists.joined(separator: ", ")
            ),
            ("id", contact.id),
        ])
        text += "\n\nThe contact itself was not changed."
        return text
    }

    /// A delete has to leave behind enough to undo it by hand; otherwise the only
    /// record that the contact ever existed is gone with it.
    public static func deleted(_ contact: ContactDetail) -> String {
        var text = "Deleted contact '\(contact.displayName)'.\n\n"
        text += block([
            ("name", contact.displayName),
            ("company", contact.organization.isEmpty ? nil : contact.organization),
            ("phones", labelledList(contact.phones)),
            ("emails", labelledList(contact.emails)),
            (
                "lists",
                contact.lists.isEmpty ? nil : contact.lists.joined(separator: ", ")
            ),
            ("note", contact.note),
            ("id", "\(contact.id) (no longer exists)"),
        ])

        var arguments: [String] = []
        if !contact.givenName.isEmpty { arguments.append("given_name=\"\(contact.givenName)\"") }
        if !contact.familyName.isEmpty {
            arguments.append("family_name=\"\(contact.familyName)\"")
        }
        if !contact.organization.isEmpty {
            arguments.append("organization=\"\(contact.organization)\"")
        }
        if !contact.phones.isEmpty {
            arguments.append(
                "phones=[\(contact.phones.map { "\"\($0.value)\"" }.joined(separator: ", "))]")
        }
        if !contact.emails.isEmpty {
            arguments.append(
                "emails=[\(contact.emails.map { "\"\($0.value)\"" }.joined(separator: ", "))]")
        }
        if let note = contact.note, !note.isEmpty {
            arguments.append("note=\"\(note)\"")
        }
        text += "\n\nTo recreate it:\n  create_contact(\(arguments.joined(separator: ", ")))"
        // Membership is not restored by recreating the contact: a new record is a new
        // record, and the lists it belonged to have no way to know about it.
        if !contact.lists.isEmpty {
            text += "\n  then update_contact_lists(id=<the new id>, add=["
            text += contact.lists.map { "\"\($0)\"" }.joined(separator: ", ") + "])"
        }
        return text
    }

    public static func status(
        _ authorization: ContactsAuthorization, automation: AutomationConsent,
        binaryPath: String
    ) -> String {
        let headline: String
        switch authorization {
        case .authorized: headline = "Contacts permission: GRANTED."
        case .denied: headline = "Contacts permission: DENIED."
        case .restricted: headline = "Contacts permission: RESTRICTED by system policy."
        case .notDetermined: headline = "Contacts permission: not requested yet."
        }

        var text = headline + "\n\n"
        text += block([
            ("binary", binaryPath),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("default results", "\(Configuration.searchLimit)"),
        ])
        if authorization != .authorized {
            text += "\n\n" + ToolError.authorizationMessage(authorization)
        }
        // Reported separately because it is a different switch in a different pane, and
        // it gates exactly one field.
        text += "\n\n" + ToolError.automationMessage(automation)
        return text
    }
}
