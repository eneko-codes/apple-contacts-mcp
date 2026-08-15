import Foundation

/// Every failure a tool can report. The messages are the product: a permission error
/// that does not say which switch to flip costs the reader a web search.
public enum ToolError: Error, Equatable {
    case notAuthorized(ContactsAuthorization)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case notFound(id: String)
    case listNotFound(String)
    case confirmationRequired(action: String)
    case emptyContact
    case nothingToUpdate
    case emptyListChange
    case storeFailure(String)
    case noteFailure(String)
    case photoWritesDisabled

    public var message: String {
        switch self {
        case .notAuthorized(let status):
            return Self.authorizationMessage(status)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .notFound(let id):
            return """
                No contact exists with id '\(id)'.

                Contacts identifiers change when an account is resynchronised. Look the
                contact up again with contacts_search instead of reusing an earlier id.
                """

        case .listNotFound(let reference):
            return """
                No list called '\(reference)' exists.

                Call contacts_lists to see the lists and the accounts they belong to. A
                list can be named by its exact name or by its id.
                """

        case .confirmationRequired(let action):
            return """
                \(action) requires confirm=true.

                This is destructive. Call again with confirm=true only if you really mean
                to delete it.
                """

        case .emptyContact:
            return
                "A contact needs at least a given name, family name, organization, phone or email."

        case .nothingToUpdate:
            return """
                No field to change was given.

                Pass a field with a value to set it, "" to empty a text field, or [] to
                empty a list. Omitting a field leaves it untouched.
                """

        case .emptyListChange:
            return """
                No list to add to or remove from was given.

                Pass add=["Family"], remove=["Work"], or both. Call contacts_lists to see
                what exists.
                """

        case .storeFailure(let detail):
            return "Contacts returned an error: \(detail)"

        case .photoWritesDisabled:
            return """
                Photo writes are disabled on this server.

                photo_path was present in this call, but the person who installed this \
                extension turned off "Allow photo writes" — no call, including this one, \
                may set or clear a contact's photo while that is off. Every other field \
                is unaffected.
                """

        case .noteFailure(let detail):
            return """
                The note could not be written, so nothing was changed.

                Notes are the one field this server reaches through Contacts.app rather
                than through Contacts.framework, and that needs its own permission:
                  System Settings → Privacy & Security → Automation → "apple-contacts-mcp"
                  → enable "Contacts"

                Contacts.app said: \(detail)
                """
        }
    }

    /// The one message worth writing carefully: it is what the reader sees the first
    /// time the server is wired up, and it names both the switch and its location. The
    /// Spanish pane names are kept alongside because they are what is on screen on a
    /// Spanish-language Mac.
    static func authorizationMessage(_ status: ContactsAuthorization) -> String {
        switch status {
        case .authorized:
            return "Contacts access granted."

        case .notDetermined:
            return """
                No Contacts access: macOS has not asked yet.

                contacts_status will not bring up the dialog — it reports the permission
                rather than requesting it, which is the point of having it. Any other tool
                requests: call contacts_search, and macOS should ask.

                If a tool has already asked and the status is still this, the binary is not
                a TCC subject at all and no dialog will ever appear. Two causes, both
                silent, checked against the binary path printed above:

                  # Linker-signed means "signed by nobody": no designated requirement, so
                  # nothing is ever logged and no prompt is shown. Every swift build
                  # produces one; scripts/pack.sh re-signs.
                  codesign -dv <binary> 2>&1 | grep flags

                  # No embedded usage description means there is nothing to show.
                  otool -P <binary> | grep NSContactsUsageDescription
                """

        case .denied:
            return """
                No Contacts access: it is denied.

                Grant it in:
                  System Settings → Privacy & Security → Contacts → enable "apple-contacts-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Contactos)

                Then restart Claude Desktop: the permission is resolved when the process
                starts.
                """

        case .restricted:
            return """
                No Contacts access: restricted by a system policy (parental controls or a
                device management profile).

                This cannot be granted from System Settings; the policy imposing it has to
                be lifted.
                """
        }
    }

    /// Explains the second privacy gate, the one nothing else in this server needs.
    ///
    /// Notes are unreachable through Contacts.framework — the entitlement they require
    /// cannot be carried by a command-line binary at all — so they come from
    /// Contacts.app over Apple events, and that is governed by Automation rather than
    /// by Contacts. Somebody who has already granted Contacts access and still cannot
    /// see a note is looking at the wrong pane, so the message names the right one.
    static func automationMessage(_ consent: AutomationConsent) -> String {
        switch consent {
        case .granted:
            return "Contacts.app automation granted (this is what reads and writes notes)."

        case .denied:
            return """
                Notes unavailable: permission to control Contacts.app is denied.

                Grant it in:
                  System Settings → Privacy & Security → Automation → "apple-contacts-mcp"
                  → enable "Contacts"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Automatización)

                Every other field is unaffected; only the note needs this.
                """

        case .notDetermined:
            return """
                Notes: macOS has not yet asked whether this server may control
                Contacts.app. The first tool call that needs a note will bring up the
                dialog.
                """

        case .unknown:
            return """
                Notes: Contacts.app is not running, so macOS will not say whether
                automation is permitted without launching it. Reading a note will launch
                it and settle the question.
                """
        }
    }
}
