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

    /// Collapses a multi-line value onto one line, so the one-row-per-contact contract
    /// that makes a listing scannable survives a name containing a newline.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// The first `limit` of `items`, and how many others there are.
    static func few(_ items: [String], limit: Int = ToolCatalog.fewNames) -> String {
        let shown = items.prefix(limit).joined(separator: ", ")
        return items.count > limit ? "\(shown) and \(items.count - limit) more" : shown
    }

    /// Shortens the values of a listing's rows to `ToolCatalog.cellWidth`, and remembers
    /// whether it had to, so the listing can say so only when it is true.
    ///
    /// A row is one line of a contact's own text, and that text has no length limit: one
    /// pasted paragraph in a company field would otherwise fill a result by itself.
    struct Clipper {
        private(set) var clipped = false

        mutating func callAsFunction(_ text: String) -> String {
            let line = Format.oneLine(text)
            guard line.count > ToolCatalog.cellWidth else { return line }
            clipped = true
            return String(line.prefix(ToolCatalog.cellWidth - 1)) + "…"
        }
    }

    /// The rows of a listing, and whether any value in them was shortened.
    public typealias Listing = (text: String, clipped: Bool)

    /// What an empty page says under its heading when rows exist further back.
    static let nothingAtThisOffset = "(nothing at this offset)"

    // MARK: Listings

    /// The order every listing of contacts is in, in words, because a page means nothing
    /// without it.
    static let contactOrder = "ordered by name, then id"

    static func searchHeading(total: Int, query: String) -> String {
        "\(plural(total, "contact")) matching '\(ToolStandard.echo(query))', \(contactOrder)"
    }

    /// `partial` is true when the search stopped before it had looked at every contact.
    static func noMatch(query: String, partial: Bool) -> String {
        "No contacts match '\(ToolStandard.echo(query))'" + (partial ? " among those looked at." : ".")
    }

    static func everyoneHeading(total: Int, list: String?) -> String {
        var heading = plural(total, "contact")
        if let list { heading += " in '\(ToolStandard.echo(list))'" }
        return heading + ", \(contactOrder)"
    }

    static func nobody(list: String?) -> String {
        list.map { "No contacts are in '\(ToolStandard.echo($0))'." } ?? "The address book is empty."
    }

    /// The shared body of every multi-contact result. `rows` is the page to show; `total`
    /// counts every contact that matched, and `none` is what to say when that is zero.
    ///
    /// Columns are padded to the widest value in the page rather than to a fixed width,
    /// so a page of short names does not carry a corridor of spaces.
    public static func contacts(
        _ rows: [ContactSummary], heading: String, none: String, total: Int, compact: Bool
    ) -> Listing {
        guard total > 0 else { return (none, false) }
        guard !rows.isEmpty else { return (heading + "\n" + nothingAtThisOffset, false) }

        var clip = Clipper()
        var lines = [heading]
        let names = rows.map { clip($0.displayName) }
        let nameWidth = names.map(\.count).max() ?? 0

        if compact {
            for (row, name) in zip(rows, names) {
                lines.append("\(pad(name, to: nameWidth))  id=\(row.id)")
            }
        } else {
            let phones = rows.map { $0.phone.map { clip($0) } ?? "" }
            let phoneWidth = phones.map(\.count).max() ?? 0
            for (index, row) in rows.enumerated() {
                var line = pad(names[index], to: nameWidth)
                line += "  " + pad(phones[index], to: phoneWidth)
                if let email = row.email { line += "  " + clip(email) }
                if let organization = row.organization { line += "  [\(clip(organization))]" }
                lines.append(line.trimmingCharacters(in: .whitespaces) + "  id=\(row.id)")
            }
        }
        return (lines.joined(separator: "\n"), clip.clipped)
    }

    /// `lists` and `accounts` are the pages to show, already in order; the totals count
    /// every list and every account.
    public static func lists(
        _ lists: [ContactList], totalLists: Int, accounts: [ContactAccount], totalAccounts: Int
    ) -> Listing {
        var clip = Clipper()
        var sections: [String] = []

        if totalLists == 0 {
            sections.append("No lists. Contacts calls these Lists; the API calls them groups.")
        } else {
            var lines = ["\(plural(totalLists, "list")), ordered by name, then account and id"]
            if lists.isEmpty { lines.append(nothingAtThisOffset) }
            let names = lists.map { clip($0.name) }
            let nameWidth = names.map(\.count).max() ?? 0
            for (list, name) in zip(lists, names) {
                var line = pad(name, to: nameWidth)
                line += "  \(list.memberCount) "
                line += list.memberCount == 1 ? "person" : "people"
                if let account = list.accountName { line += "  [\(clip(account))]" }
                lines.append(line + "  id=\(list.id)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if totalAccounts > 0 {
            var lines = ["Accounts: \(totalAccounts), ordered by name, then id"]
            if accounts.isEmpty { lines.append("  " + nothingAtThisOffset) }
            let names = accounts.map { clip($0.name) }
            let nameWidth = names.map(\.count).max() ?? 0
            for (account, name) in zip(accounts, names) {
                var line = "  " + pad(name, to: nameWidth) + "  \(account.kind.rawValue)"
                if account.isDefault { line += "  (new contacts go here)" }
                lines.append(line)
            }
            sections.append(lines.joined(separator: "\n"))
        }

        return (sections.joined(separator: "\n\n"), clip.clipped)
    }

    // MARK: One contact

    /// The whole record of one contact as text. It has no length limit of its own (a note
    /// can be any length, and so can every list of values), so no tool returns it as it
    /// is: `contacts_get` returns a window of it and a write shows its start.
    ///
    /// The id comes before the note, and the note last, so that the first window of a
    /// record with a long note still holds every other field.
    public static func record(_ contact: ContactDetail) -> String {
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
        rows.append(("id", contact.id))
        rows.append(("note", contact.note))

        var text = oneLine(contact.displayName) + "\n" + block(rows)
        if contact.note == nil {
            // A missing note is a story about the route, not a fact about this person, and
            // saying nothing would let it read as "this contact has no note".
            text += """


                (The note could not be read. It is the one field that comes from
                Contacts.app rather than Contacts.framework, which needs Automation
                permission and a Contacts.app holding no unsaved changes — call
                contacts_status to see which is missing.)
                """
        }
        return text
    }

    /// Said before a record whose note could not be read. The record explains it where
    /// the note would be, at its end, and that end may be several windows away.
    static let noteNotRead = """
        The note could not be read; the end of the record says why, and contacts_status \
        which permission or state is missing.
        """

    /// The window of a record that `contacts_get` returns, with what it left out said
    /// first: the notices it is handed, a note that could not be read, and where the
    /// window sits in the whole.
    public static func recordWindow(
        _ contact: ContactDetail, characterOffset: Int, maxCharacters: Int, notices: [String]
    ) -> String {
        let whole = record(contact)
        let unread = contact.note == nil ? [noteNotRead] : []
        return ToolStandard.fitting(maxCharacters) { size in
            let window = ToolStandard.window(
                of: whole, characterOffset: characterOffset, maxCharacters: size, label: "Record")
            return ToolStandard.withNotices(
                notices + unread + [window.notice].compactMap { $0 }, window.text)
        }
    }

    // MARK: Receipts

    /// A contact's name inside a sentence: on one line and no wider than a row's value.
    private static func named(_ contact: ContactDetail) -> String {
        var clip = Clipper()
        return clip(contact.displayName)
    }

    /// Said under the window notice of a write's receipt: the notice names an argument
    /// the write does not take, because the rest is read with another tool.
    static let receiptContinues = """
        character_offset is an argument of \(ToolCatalog.getName): pass it there, with this \
        id, to read the rest of the record.
        """

    /// What a write shows of the contact it wrote: the start of its record, which is the
    /// same text `contacts_get` windows, so the offset where this stops is the offset
    /// that tool resumes from. `body` receives that start and returns the whole receipt.
    private static func receipt(_ contact: ContactDetail, body: (String) -> String) -> String {
        let whole = record(contact)
        return ToolStandard.fitting(ToolCatalog.receiptCharacters) { size in
            let window = ToolStandard.window(
                of: whole, characterOffset: 0, maxCharacters: size, label: "Record")
            let notices = window.notice.map { [$0, receiptContinues] } ?? []
            return ToolStandard.withNotices(notices, body(window.text))
        }
    }

    public static func created(_ contact: ContactDetail) -> String {
        receipt(contact) { record in
            // The record drops an empty "lists" row silently, which reads as "this section
            // does not apply" on a read. On a creation it reads as something else
            // entirely: the caller cannot tell "born into no list" from "the lists
            // argument was silently ignored", and the second of those was a real,
            // undetected failure mode before create_contact accepted lists at all.
            // The id is in the first line because the record may be cut before its own
            // id row, and reading the rest needs it.
            var text = "Created contact '\(named(contact))' (id=\(contact.id)).\n\n" + record
            if contact.lists.isEmpty {
                text += "\n\n  lists   (none — pass lists: [...] to add it to one)"
            }
            if let warning = selfRelationWarning(contact) { text += "\n\n" + warning }
            return text
        }
    }

    public static func updated(_ result: ContactUpdateResult, fields: [String]) -> String {
        let contact = result.after
        let counts = multiValueCountChanges(from: result.before, to: contact, touching: fields)
        return receipt(contact) { record in
            // An update with nothing to change is refused before it reaches the store, so
            // `fields` is never empty here.
            var text =
                "Updated contact '\(named(contact))' (id=\(contact.id)). Fields changed: "
                + fields.joined(separator: ", ") + ".\n\n" + record
            if !counts.isEmpty {
                text += "\n\n" + counts.map { "  \($0.field): \($0.before) → \($0.after)" }
                    .joined(separator: "\n")
            }
            if let warning = selfRelationWarning(contact) { text += "\n\n" + warning }
            return text
        }
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
        var clip = Clipper()
        let labels = matches.compactMap(\.label).map { clip($0) }
        return "Note: this contact is listed as its own relation"
            + (labels.isEmpty ? "" : " (\(few(labels, limit: 5)))")
            + " — check whether that was intended."
    }

    /// Reports membership as it now stands rather than as it was asked to be: adding
    /// someone to a list they were already in changes nothing, and a confirmation that
    /// claims otherwise is worse than no confirmation.
    ///
    /// Every name here is shortened and counted, the caller's own and the stored ones, so
    /// the receipt has a fixed ceiling whatever the contact belongs to; what that left out
    /// is said first, with the tool that shows it.
    public static func listsChanged(
        _ contact: ContactDetail, added: [String], removed: [String]
    ) -> String {
        var clip = Clipper()
        let name = clip(contact.displayName)
        var actions: [String] = []
        if !added.isEmpty { actions.append("added to \(few(added.map { clip($0) }))") }
        if !removed.isEmpty { actions.append("removed from \(few(removed.map { clip($0) }))") }

        var text = "'\(name)' \(actions.joined(separator: ", "))."
        text += "\n\n"
        text += block([
            ("name", name),
            (
                "lists",
                contact.lists.isEmpty ? "(in no list)" : few(contact.lists.map { clip($0) })
            ),
            ("id", contact.id),
        ])
        text += "\n\nThe contact itself was not changed."

        var notices: [String] = []
        if contact.lists.count > ToolCatalog.fewNames {
            notices.append(
                """
                Showing 1–\(ToolCatalog.fewNames) of \(contact.lists.count) lists. \
                \(ToolCatalog.getName) shows every list the contact is in.
                """)
        }
        if clip.clipped {
            notices.append(
                Notice.clipped(field: "A long name", width: ToolCatalog.cellWidth, tool: ToolCatalog.getName))
        }
        return ToolStandard.withNotices(notices, text)
    }

    /// A delete has to leave behind enough to undo it by hand; otherwise the only
    /// record that the contact ever existed is gone with it. It shows the record as it
    /// was, as far as one result can hold, and says so first when that is not all of it:
    /// there is nothing left to read the rest from.
    public static func deleted(_ contact: ContactDetail) -> String {
        let whole = record(contact)
        let recreate = recreation(of: contact)
        return ToolStandard.fitting(ToolCatalog.deleteReceiptCharacters) { size in
            let shown = ToolStandard.window(of: whole, characterOffset: 0, maxCharacters: size).text
            var notices: [String] = []
            if shown.count < whole.count {
                notices.append(
                    """
                    The record was \(whole.count) characters long and only the first \
                    \(shown.count) are below. The rest was deleted with the contact and \
                    cannot be read again.
                    """)
            }
            let text =
                "Deleted contact '\(named(contact))'.\n\n" + shown
                + "\n\nThat id no longer exists.\n\n" + recreate
            return ToolStandard.withNotices(notices, text)
        }
    }

    /// The call that would put a deleted contact back, when it is short enough to spell
    /// out. A long one would only repeat the record printed above it.
    private static func recreation(of contact: ContactDetail) -> String {
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
        var call = "create_contact(\(arguments.joined(separator: ", ")))"
        // Membership is not restored by recreating the contact: a new record is a new
        // record, and the lists it belonged to have no way to know about it.
        if !contact.lists.isEmpty {
            call += "\n  then update_contact_lists(id=<the new id>, add=["
            call += contact.lists.map { "\"\($0)\"" }.joined(separator: ", ") + "])"
        }
        guard call.count <= ToolCatalog.recreateCallCharacters else {
            return """
                To recreate it, pass the fields above to create_contact, then its lists to \
                update_contact_lists with the new id.
                """
        }
        return "To recreate it:\n  " + call
    }

    public static func status(
        _ authorization: ContactsAuthorization, automation: AutomationConsent,
        contactsAppUnsaved: Bool, binaryPath: String
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
            ("default results", "\(ToolCatalog.defaultContactLimit)"),
        ])
        if authorization != .authorized {
            text += "\n\n" + ToolError.authorizationMessage(authorization)
        }
        // Reported separately because it is a different switch in a different pane, and
        // it gates exactly one field.
        text += "\n\n" + ToolError.automationMessage(automation)
        if contactsAppUnsaved {
            text += "\n\nContacts.app has UNSAVED changes. " + ToolError.unsavedChangesConsequence
        }
        return text
    }
}
