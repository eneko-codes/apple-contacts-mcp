import CoreServices
import Foundation

/// Escaping for text placed inside an AppleScript double-quoted string literal.
///
/// The note is the one piece of contact data this server puts into executable source
/// text, so an unescaped quote is not a formatting bug — it ends the literal and the
/// rest of the note becomes script. This is also the only part of the Contacts.app
/// bridge a test can reach, which is why it is a free function rather than a private
/// detail of the caller.
public enum AppleScriptString {

    /// Wraps `text` in quotes, escaped so AppleScript reads it back byte for byte.
    ///
    /// A literal cannot span source lines, so line breaks become the `\n` and `\r`
    /// escapes AppleScript understands rather than being passed through. The backslash
    /// must be replaced first: doing it after would also escape the backslashes this
    /// function itself introduces.
    public static func literal(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\r\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

/// Whether this process may drive Contacts.app, as far as can be told without asking.
public enum AutomationConsent: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// Contacts.app is not running, so macOS will not answer the question without
    /// launching it. Says nothing about whether consent exists.
    case unknown
}

/// Reads and writes a contact's note through Contacts.app.
///
/// Contacts.framework cannot do it. `CNContactNoteKey` requires
/// `com.apple.developer.contacts.notes`, a managed capability that must be authorised
/// by a provisioning profile — and a command-line executable has nowhere to carry one,
/// so `codesign --sign -` can never satisfy it however the binary is built. Apple's
/// own guidance for this case is to script Contacts.app, which owns the data and needs
/// no entitlement to reach it.
///
/// The cost is a second privacy gate: Automation, under Privacy & Security → Automation
/// rather than → Contacts. Every failure here degrades to "the note could not be read"
/// rather than failing the call, because a contact with an unreadable note is still
/// worth returning.
struct ContactsAppScripting: Sendable {

    /// Contacts.app's bundle identifier, still `AddressBook` from before it was renamed.
    private static let contactsBundleIdentifier = "com.apple.AddressBook"

    /// Generous because the very first call may be sitting on the Automation consent
    /// dialog waiting for a human. Killing osascript at that moment cancels the prompt
    /// and leaves consent undecided, which is a worse outcome than a slow call.
    private static let timeout: TimeInterval = 60

    // MARK: Notes

    /// The contact's note, or nil when Contacts.app could not be asked at all.
    ///
    /// nil and "" are different answers: "" is a contact with no note, nil is a note
    /// this server was not allowed to see. `ContactDetail.note` carries that
    /// distinction through to the output, which explains itself when it is nil.
    func read(id: String) -> String? {
        let script = """
            tell application id \(AppleScriptString.literal(Self.contactsBundleIdentifier))
                set theNote to note of person id \(AppleScriptString.literal(id))
            end tell
            if theNote is missing value then return ""
            return theNote
            """
        guard let output = try? run(script) else { return nil }
        // osascript appends one newline of its own to a returned string. Trimming the
        // whole trailing whitespace run instead would silently eat a note that ends in
        // a deliberate blank line.
        return output.hasSuffix("\n") ? String(output.dropLast()) : output
    }

    /// Sets the note, replacing whatever was there.
    ///
    /// `save` is not optional: Contacts.app buffers the change in its own document and
    /// a script that stops without saving loses it, with no error to say so.
    func write(_ note: String, id: String) throws {
        let script = """
            tell application id \(AppleScriptString.literal(Self.contactsBundleIdentifier))
                set note of person id \(AppleScriptString.literal(id)) to \
            \(AppleScriptString.literal(note))
                save
            end tell
            """
        _ = try run(script)
    }

    // MARK: Field updates

    /// `CNInstantMessageAddress.service` → the enumerator Contacts.app's dictionary uses
    /// for it. Two of the ten differ by a space, which is exactly the sort of mismatch
    /// that would otherwise surface as an AppleScript syntax error at run time.
    ///
    /// The keys are the framework's own constant values, not display names, because
    /// `canonicalService` has already reversed any localisation by the time a service
    /// reaches here.
    static let scriptableMessageServices: [String: String] = [
        "AIM": "AIM", "Facebook": "Facebook", "GaduGadu": "Gadu Gadu",
        "GoogleTalk": "Google Talk", "ICQ": "ICQ", "Jabber": "Jabber", "MSN": "MSN",
        "QQ": "QQ", "Skype": "Skype", "Yahoo": "Yahoo",
    ]

    /// The argument names in `changes` that Contacts.app cannot write.
    ///
    /// Checked *before* anything is applied, so a partially-writable edit is refused
    /// whole rather than half-done. Contacts.app's dictionary is narrower than
    /// `CNContact`, and these are the gaps:
    ///
    /// - `phonetic_organization_name` has no property on `person` at all;
    /// - `instant_messages` keys its service off a fixed enum (`service type`) and its
    ///   `service name` is read-only, so a **custom** service — "Signal", say — cannot be
    ///   expressed here even though `CNInstantMessageAddress.service` is a free-form
    ///   string and the framework path stores it happily. The ten services Contacts.app
    ///   does name are fine. Social profiles have no such limit: their `service name` is
    ///   writable text, so "GitHub" or "Revolut" go through either route;
    /// - `photo_path` would need the image read and coerced in the script, which is a
    ///   different failure surface from everything else here;
    /// - a birthday or custom date **with no year** is not representable: `birth date`
    ///   is a date, while Contacts.framework allows the year to be absent.
    static func unsupportedFields(in changes: ContactChanges) -> [String] {
        var unsupported: [String] = []
        if changes.phoneticOrganizationName != .unchanged {
            unsupported.append("phonetic_organization_name")
        }
        if case .set(let messages) = changes.instantMessages {
            let custom = messages.map(\.service).filter { service in
                !scriptableMessageServices.keys.contains {
                    $0.localizedCaseInsensitiveCompare(service) == .orderedSame
                }
            }
            if !custom.isEmpty {
                unsupported.append(
                    "instant_messages with a custom service (\(custom.joined(separator: ", ")))")
            }
        }
        if changes.photoPath != .unchanged { unsupported.append("photo_path") }
        if case .set(let components) = changes.birthday, components.year == nil {
            unsupported.append("birthday (no year)")
        }
        if case .set(let dates) = changes.dates, dates.contains(where: { $0.components.year == nil })
        {
            unsupported.append("dates (no year)")
        }
        return unsupported
    }

    /// Applies field changes through Contacts.app rather than `CNSaveRequest`.
    ///
    /// This exists because **`update_contact` cannot save a contact that carries a note.**
    /// Contacts rebuilds the record's search index during `willSave` and the index reads
    /// the note; `CNContactNoteKey` is unfetchable without an entitlement this binary can
    /// never hold, so that one property is a permanently unresolvable fault and the whole
    /// save dies with Cocoa error 134092. Measured against two contacts identical but for
    /// the note. Contacts.app owns the data and needs no entitlement, so it can write what
    /// the framework cannot.
    ///
    /// The caller must have checked `unsupportedFields(in:)` first.
    ///
    /// `save` is not optional: Contacts.app buffers the change in its own document and a
    /// script that stops without saving loses it, with no error to say so.
    func update(id: String, changes: ContactChanges) throws {
        var lines = [
            "tell application id \(AppleScriptString.literal(Self.contactsBundleIdentifier))",
            "set thePerson to person id \(AppleScriptString.literal(id))",
        ]

        // Every text property Contacts.app exposes, paired with its AppleScript name.
        // Written once as a table because a hand-copied `if` per field is where a typo
        // silently writes the wrong property.
        let textFields: [(FieldEdit<String>, String)] = [
            (changes.namePrefix, "title"),
            (changes.givenName, "first name"),
            (changes.middleName, "middle name"),
            (changes.familyName, "last name"),
            (changes.previousFamilyName, "maiden name"),
            (changes.nameSuffix, "suffix"),
            (changes.nickname, "nickname"),
            (changes.phoneticGivenName, "phonetic first name"),
            (changes.phoneticMiddleName, "phonetic middle name"),
            (changes.phoneticFamilyName, "phonetic last name"),
            (changes.organization, "organization"),
            (changes.jobTitle, "job title"),
            (changes.department, "department"),
        ]
        for (edit, property) in textFields {
            switch edit {
            case .unchanged: continue
            case .cleared: lines.append("set \(property) of thePerson to \"\"")
            case .set(let value):
                lines.append("set \(property) of thePerson to \(AppleScriptString.literal(value))")
            }
        }

        if case .set(let kind) = changes.kind {
            lines.append("set company of thePerson to \(kind == .organization)")
        }

        switch changes.birthday {
        case .unchanged: break
        case .cleared: lines.append("set birth date of thePerson to missing value")
        case .set(let components):
            lines.append(contentsOf: Self.dateLines(components, variable: "theBirthday"))
            lines.append("set birth date of thePerson to theBirthday")
        }

        // Value lists replace wholesale, exactly as the framework path does: delete every
        // existing element, then recreate. `phone`, `email`, `url`, `related name` and
        // `custom date` all inherit label/value from Contacts.app's `contact info`.
        lines.append(
            contentsOf: Self.labelledLines(changes.phones, singular: "phone", plural: "phones"))
        lines.append(
            contentsOf: Self.labelledLines(changes.emails, singular: "email", plural: "emails"))
        lines.append(
            contentsOf: Self.labelledLines(changes.urls, singular: "url", plural: "urls"))
        lines.append(
            contentsOf: Self.labelledLines(
                changes.relations, singular: "related name", plural: "related names"))

        switch changes.addresses {
        case .unchanged: break
        case .cleared: lines.append("delete every address of thePerson")
        case .set(let addresses):
            lines.append("delete every address of thePerson")
            for address in addresses {
                var properties = [
                    "street:\(AppleScriptString.literal(address.street))",
                    "city:\(AppleScriptString.literal(address.city))",
                    "state:\(AppleScriptString.literal(address.state))",
                    "zip:\(AppleScriptString.literal(address.postalCode))",
                    "country:\(AppleScriptString.literal(address.country))",
                ]
                if let label = address.label {
                    properties.insert("label:\(AppleScriptString.literal(label))", at: 0)
                }
                lines.append(
                    "make new address at end of addresses of thePerson with properties "
                        + "{\(properties.joined(separator: ", "))}")
            }
        }

        switch changes.socialProfiles {
        case .unchanged: break
        case .cleared: lines.append("delete every social profile of thePerson")
        case .set(let profiles):
            lines.append("delete every social profile of thePerson")
            for profile in profiles {
                let properties = [
                    "service name:\(AppleScriptString.literal(profile.service))",
                    "user name:\(AppleScriptString.literal(profile.username))",
                    "url:\(AppleScriptString.literal(profile.urlString))",
                ]
                lines.append(
                    "make new social profile at end of social profiles of thePerson with "
                        + "properties {\(properties.joined(separator: ", "))}")
            }
        }

        switch changes.instantMessages {
        case .unchanged: break
        case .cleared: lines.append("delete every instant message of thePerson")
        case .set(let messages):
            lines.append("delete every instant message of thePerson")
            for message in messages {
                // Guaranteed present: unsupportedFields refuses a custom service before
                // any of this runs, so the caller never reaches here with one.
                guard
                    let enumerator = Self.scriptableMessageServices.first(where: {
                        $0.key.localizedCaseInsensitiveCompare(message.service) == .orderedSame
                    })?.value
                else { continue }
                // `service type` is an enumerator, not text, so it is the one value here
                // that must NOT be quoted.
                var properties = [
                    "service type:\(enumerator)",
                    "user name:\(AppleScriptString.literal(message.username))",
                ]
                if let label = message.label {
                    properties.insert("label:\(AppleScriptString.literal(label))", at: 0)
                }
                lines.append(
                    "make new instant message at end of instant messages of thePerson with "
                        + "properties {\(properties.joined(separator: ", "))}")
            }
        }

        switch changes.dates {
        case .unchanged: break
        case .cleared: lines.append("delete every custom date of thePerson")
        case .set(let dates):
            lines.append("delete every custom date of thePerson")
            for (index, entry) in dates.enumerated() {
                let variable = "theDate\(index)"
                lines.append(contentsOf: Self.dateLines(entry.components, variable: variable))
                var properties = ["value:\(variable)"]
                if let label = entry.label {
                    properties.insert("label:\(AppleScriptString.literal(label))", at: 0)
                }
                lines.append(
                    "make new custom date at end of custom dates of thePerson with properties "
                        + "{\(properties.joined(separator: ", "))}")
            }
        }

        lines.append("save")
        lines.append("end tell")
        _ = try run(lines.joined(separator: "\n"))
    }

    /// Builds a date in a locale-independent way.
    ///
    /// `date "14/03/1990"` parses against the machine's own format and would read as
    /// 3 December on a US Mac, so the components are assigned individually instead. The
    /// day is reset to 1 before the month changes: setting the month while the day is 31
    /// rolls the date into the next month.
    private static func dateLines(_ components: DateComponents, variable: String) -> [String] {
        [
            "set \(variable) to current date",
            "set day of \(variable) to 1",
            "set year of \(variable) to \(components.year ?? 1)",
            "set month of \(variable) to \(components.month ?? 1)",
            "set day of \(variable) to \(components.day ?? 1)",
            "set time of \(variable) to 0",
        ]
    }

    private static func labelledLines(
        _ edit: FieldEdit<[LabelledValue]>, singular: String, plural: String
    ) -> [String] {
        switch edit {
        case .unchanged: return []
        case .cleared: return ["delete every \(singular) of thePerson"]
        case .set(let values):
            var lines = ["delete every \(singular) of thePerson"]
            for value in values {
                var properties = ["value:\(AppleScriptString.literal(value.value))"]
                if let label = value.label {
                    properties.insert("label:\(AppleScriptString.literal(label))", at: 0)
                }
                lines.append(
                    "make new \(singular) at end of \(plural) of thePerson with properties "
                        + "{\(properties.joined(separator: ", "))}")
            }
            return lines
        }
    }

    // MARK: Group membership

    /// Adds or removes a contact from a group through Contacts.app.
    ///
    /// This exists for two independent reasons, discovered a session apart:
    ///
    /// - **`CNSaveRequest.removeMember(_:from:)` does not work against an iCloud group on
    ///   this system, and does not say so.** Measured directly: the save is accepted,
    ///   nothing throws, and the membership is still there afterwards on three separate
    ///   reads — while Contacts.app removes the very same person from the very same group,
    ///   seconds later, without complaint. `addMember` looked unaffected at the time, which
    ///   is exactly what kept this invisible: adding worked, so the pair looked healthy.
    /// - **Neither `addMember` nor `removeMember` can save a contact that carries a note.**
    ///   The framework call still touches the whole `CNContact` — `willSave` reindexes it
    ///   regardless of which property changed, or whether one did at all — and
    ///   `CNContactNoteKey` is unfetchable by this binary, so the reindex trips on the same
    ///   unresolvable fault as `update_contact` does. Every membership change on a noted
    ///   contact hit this and reported the framework's bare Cocoa error, with no attempt at
    ///   this fallback: `changeMembership` only reached here after a *successful* save that
    ///   had silently done nothing, never after a save that threw.
    ///
    /// The membership is addressed by the group's **name** because that is what
    /// Contacts.app's dictionary can match on; the person is addressed by identifier,
    /// which is exact. A name is ambiguous when two accounts hold a list of the same
    /// name, so the caller must have resolved the group first and pass the resolved
    /// name — this is a fallback for a broken framework call, not a lookup route.
    ///
    /// `save` is not optional: Contacts.app buffers the change in its own document and a
    /// script that stops without saving loses it, with no error to say so.
    func changeMembership(contactID: String, groupNamed name: String, adding: Bool) throws {
        let verb = adding ? "add thePerson to theGroup" : "remove thePerson from theGroup"
        let script = """
            tell application id \(AppleScriptString.literal(Self.contactsBundleIdentifier))
                set theGroups to (every group whose name is \(AppleScriptString.literal(name)))
                set thePerson to person id \(AppleScriptString.literal(contactID))
                repeat with theGroup in theGroups
                    \(verb)
                end repeat
                save
            end tell
            """
        _ = try run(script)
    }

    // MARK: Consent

    /// Asks macOS whether this process may drive Contacts.app, without prompting and
    /// without launching it. Used by `contacts_status`, where the point is to explain a
    /// refusal rather than trigger one.
    func consent() -> AutomationConsent {
        var target = AEDesc()
        let identifier = Array(Self.contactsBundleIdentifier.utf8)
        let created = identifier.withUnsafeBytes { bytes in
            AECreateDesc(
                DescType(typeApplicationBundleID), bytes.baseAddress, bytes.count, &target)
        }
        guard created == 0 else { return .unknown }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown
        }
    }

    // MARK: Running the script

    /// Runs a script through `/usr/bin/osascript`, returning its standard output.
    ///
    /// The script arrives on **stdin**, never in `arguments`. A note passed on the
    /// command line would be readable in `ps` by every process on the machine for as
    /// long as the call lasts, which is not an acceptable way to move someone's private
    /// notes around.
    ///
    /// A subprocess rather than `NSAppleScript` in-process, for two reasons: it can be
    /// killed when it hangs, which an in-process script cannot, and a wedged call is
    /// the worst failure mode for a server speaking a synchronous protocol over stdio.
    /// TCC still attributes the Apple events to this binary — a disclaimed process is
    /// responsible for itself, and its children inherit it as their responsible
    /// process, so the Automation entry names this executable and reads its
    /// `NSAppleEventsUsageDescription`.
    private func run(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw ToolError.storeFailure("could not run osascript: \(error.localizedDescription)")
        }

        // Terminating unblocks the reads below by closing the child's pipes, which is
        // what stops a hung Contacts.app from wedging this call forever.
        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: deadline)
        defer { deadline.cancel() }

        try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try? input.fileHandleForWriting.close()

        // stdout is drained first because it is the one that can be large — a note has
        // no length limit, while stderr only ever carries a single osascript error
        // line, far short of the pipe buffer that would deadlock this order.
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ToolError.storeFailure(
                String(decoding: stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: stdout, as: UTF8.self)
    }
}
