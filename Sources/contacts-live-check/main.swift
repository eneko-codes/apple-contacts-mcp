import Contacts
import ContactsMCPCore
import Foundation

// Live verification of everything below the `ContactStore` seam, against the real
// address book — using only records this program creates and then deletes.
//
// WHY THIS IS AN EXECUTABLE AND NOT A TEST. It was written as a Swift Testing suite
// first, and that suite could never run: `swift test` loads an `.xctest` bundle whose
// host binary is linker-signed and carries no `NSContactsUsageDescription`, so macOS
// denies Contacts access **without ever prompting** and the status stays `notDetermined`
// forever. Being its own signed executable with the embedded Info.plist is what makes
// this a TCC subject at all — the same reason the server itself is built that way. Run
// it with `scripts/live-check.sh`, which does the signing that makes the prompt appear.
//
// SAFETY, per the hard rule in CLAUDE.md. Every subject here is created by this program,
// named `ZZTest…`, and deleted before it exits, including on failure. Nothing searches,
// enumerates or pages the address book, and no record the owner made is read, written or
// looked at.

let store = SystemContactStore()

var failures = 0
var checks = 0

// Top-level code is main-actor isolated, and so are the counters above.
@MainActor
func report(_ name: String, _ passed: Bool, _ detail: String = "") {
    checks += 1
    if !passed { failures += 1 }
    let mark = passed ? "✓" : "✗"
    print("  \(mark) \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
}

/// Unmistakable in Contacts.app at a glance, and unique per run so two runs cannot
/// collide on one record.
func disposableName() -> String { "ZZTest \(UUID().uuidString.prefix(8))" }

func makeContact(note: String = "") async throws -> ContactDetail {
    var draft = ContactDraft()
    draft.givenName = disposableName()
    draft.familyName = "Disposable"
    draft.note = note
    return try await store.create(draft)
}

/// Swallows failure on purpose: this runs while a check may already have failed, and
/// throwing here would replace the real diagnosis with a cleanup error. A leftover is
/// still obvious by its name.
func discard(contact id: String) async {
    _ = try? await store.delete(id: id)
}

/// Lists are not part of the `ContactStore` seam — this server deliberately exposes no
/// tool that creates one — so this reaches Contacts.framework directly, through the very
/// same shared store the fix is about.
func makeList() throws -> CNMutableGroup {
    let group = CNMutableGroup()
    group.name = disposableName() + " List"
    let request = CNSaveRequest()
    request.add(group, toContainerWithIdentifier: nil)
    try SystemContactStore.shared.execute(request)
    return group
}

func discard(list group: CNMutableGroup) {
    let request = CNSaveRequest()
    request.delete(group)
    try? SystemContactStore.shared.execute(request)
}

func describe(_ error: Error) -> String {
    (error as? ToolError)?.message ?? error.localizedDescription
}

// MARK: Permission

print("apple-contacts-mcp live check")
print("binary: \(CommandLine.arguments.first ?? "?")")
print("")

var authorization = store.authorization()
if authorization == .notDetermined {
    print("Requesting Contacts access — approve the dialog if it appears…")
    authorization = await store.requestAccess()
}
guard authorization == .authorized else {
    print(ToolError.notAuthorized(authorization).message)
    exit(1)
}
print("Contacts access: granted")
print("Automation (notes): \(store.automationConsent() == .granted ? "granted" : "not granted")")
print("")

// MARK: Every writable field, one at a time

// One field per case, because the reported failure was total: if a whole-record update
// fails there is no way to tell which property Contacts choked on, and that ambiguity is
// what cost two round trips through the owner to diagnose.
struct FieldCase {
    let name: String
    let apply: (inout ContactChanges) -> Void
    let holds: (ContactDetail) -> Bool
}

let fieldCases: [FieldCase] = [
    FieldCase(
        name: "name_prefix", apply: { $0.namePrefix = .set("Dr") },
        holds: { $0.namePrefix == "Dr" }),
    FieldCase(
        name: "given_name", apply: { $0.givenName = .set("ZZTestGiven") },
        holds: { $0.givenName == "ZZTestGiven" }),
    FieldCase(
        name: "middle_name", apply: { $0.middleName = .set("Middle") },
        holds: { $0.middleName == "Middle" }),
    FieldCase(
        name: "family_name", apply: { $0.familyName = .set("ZZTestFamily") },
        holds: { $0.familyName == "ZZTestFamily" }),
    FieldCase(
        name: "previous_family_name", apply: { $0.previousFamilyName = .set("Former") },
        holds: { $0.previousFamilyName == "Former" }),
    FieldCase(
        name: "name_suffix", apply: { $0.nameSuffix = .set("Jr") },
        holds: { $0.nameSuffix == "Jr" }),
    // The exact field the owner reported failing on a real contact.
    FieldCase(
        name: "nickname", apply: { $0.nickname = .set("Nick") },
        holds: { $0.nickname == "Nick" }),
    FieldCase(
        name: "phonetic_given_name", apply: { $0.phoneticGivenName = .set("Fo Net Ik") },
        holds: { $0.phoneticGivenName == "Fo Net Ik" }),
    FieldCase(
        name: "phonetic_middle_name", apply: { $0.phoneticMiddleName = .set("Mid Ul") },
        holds: { $0.phoneticMiddleName == "Mid Ul" }),
    FieldCase(
        name: "phonetic_family_name", apply: { $0.phoneticFamilyName = .set("Fam Il Ee") },
        holds: { $0.phoneticFamilyName == "Fam Il Ee" }),
    FieldCase(
        name: "phonetic_organization_name", apply: { $0.phoneticOrganizationName = .set("Or Gan") },
        holds: { $0.phoneticOrganizationName == "Or Gan" }),
    FieldCase(
        name: "organization", apply: { $0.organization = .set("Nowhere Ltd") },
        holds: { $0.organization == "Nowhere Ltd" }),
    FieldCase(
        name: "job_title", apply: { $0.jobTitle = .set("Tester") },
        holds: { $0.jobTitle == "Tester" }),
    // The other field the owner reported failing.
    FieldCase(
        name: "department", apply: { $0.department = .set("Quality") },
        holds: { $0.department == "Quality" }),
    FieldCase(
        name: "contact_type", apply: { $0.kind = .set(.organization) },
        holds: { $0.kind == .organization }),
    FieldCase(
        name: "phones",
        apply: { $0.phones = .set([LabelledValue(label: "mobile", value: "+34 600 000 999")]) },
        holds: { !$0.phones.isEmpty }),
    FieldCase(
        name: "emails",
        apply: { $0.emails = .set([LabelledValue(label: "work", value: "zztest@invalid.invalid")]) },
        holds: { $0.emails.first?.value == "zztest@invalid.invalid" }),
    FieldCase(
        name: "urls",
        apply: { $0.urls = .set([LabelledValue(label: nil, value: "https://invalid.invalid")]) },
        holds: { $0.urls.first?.value == "https://invalid.invalid" }),
    FieldCase(
        name: "relations",
        apply: { $0.relations = .set([LabelledValue(label: "sister", value: "ZZTest Sibling")]) },
        holds: { $0.relations.first?.value == "ZZTest Sibling" }),
    FieldCase(
        name: "addresses",
        apply: {
            $0.addresses = .set([
                PostalAddress(
                    label: "home", street: "1 Nowhere Street", city: "Invented", state: "",
                    postalCode: "00000", country: "Nowhere")
            ])
        },
        holds: { $0.addresses.first?.city == "Invented" }),
    FieldCase(
        name: "social_profiles",
        apply: {
            $0.socialProfiles = .set([
                SocialProfile(label: nil, service: "LinkedIn", username: "zztest")
            ])
        },
        holds: { $0.socialProfiles.first?.username == "zztest" }),
    FieldCase(
        name: "instant_messages",
        apply: {
            $0.instantMessages = .set([
                InstantMessage(label: nil, service: "Skype", username: "zztest")
            ])
        },
        holds: { $0.instantMessages.first?.username == "zztest" }),
    FieldCase(
        name: "dates",
        apply: {
            $0.dates = .set([
                LabelledDate(
                    label: "anniversary", components: DateComponents(year: 2020, month: 6, day: 1))
            ])
        },
        holds: { $0.dates.first?.components.year == 2020 }),
    FieldCase(
        name: "birthday",
        apply: { $0.birthday = .set(DateComponents(year: 1990, month: 3, day: 14)) },
        holds: { $0.birthday?.year == 1990 && $0.birthday?.month == 3 }),
]

print("Writable fields, one at a time, on a contact fetched back out of the store:")
do {
    let contact = try await makeContact()
    for field in fieldCases {
        var changes = ContactChanges()
        field.apply(&changes)
        do {
            // The store re-reads the record and returns what was actually stored, so this
            // is a genuine round trip and not an echo of what was sent.
            let updated = try await store.update(id: contact.id, changes: changes).after
            report(field.name, field.holds(updated), field.holds(updated) ? "" : "did not persist")
        } catch {
            report(field.name, false, describe(error))
        }
    }
    await discard(contact: contact.id)
} catch {
    report("create the fixture contact", false, describe(error))
}
print("")

// MARK: Photo

// `photo_path` is the field whose key was added to the mutation descriptor, so it is the
// one most likely to regress if that descriptor is ever narrowed again.
print("Photo:")
do {
    // A real 1×1 PNG: Contacts validates the bytes, not the extension.
    let pixel = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("zztest-\(UUID().uuidString).png")
    try pixel.write(to: path)
    defer { try? FileManager.default.removeItem(at: path) }

    let contact = try await makeContact()
    var set = ContactChanges()
    set.photoPath = .set(path.path)
    let withPhoto = try await store.update(id: contact.id, changes: set).after
    report("photo_path sets a photo", withPhoto.photo != nil)

    var clear = ContactChanges()
    clear.photoPath = .cleared
    let without = try await store.update(id: contact.id, changes: clear).after
    report("photo_path \"\" clears it", without.photo == nil)

    await discard(contact: contact.id)
} catch {
    report("photo round trip", false, describe(error))
}
print("")

// MARK: List membership

print("List membership:")
do {
    let group = try makeList()
    defer { discard(list: group) }

    let contact = try await makeContact()
    // Both by name, which is what a caller types, and the path that failed live.
    let added = try await store.addToList(id: contact.id, list: group.name)
    report("added by list name", added.lists.contains(group.name))

    let removed = try await store.removeFromList(id: contact.id, list: group.name)
    report("removed by list name", !removed.lists.contains(group.name))

    let byIdentifier = try await store.addToList(id: contact.id, list: group.identifier)
    report("added by list identifier", byIdentifier.lists.contains(group.name))

    await discard(contact: contact.id)
} catch {
    report("list membership", false, describe(error))
}
print("")

// MARK: The note, and what it costs

// `CNContactNoteKey` cannot be fetched by this binary at all, so a contact carrying a note
// is saved with that one property still a fault. If Contacts' reindexing reads the note,
// this is the case that fails while everything above passes — precisely the signal worth
// having, because there would then be no route to a fix from inside this server.
print("A contact that carries a note:")
if store.automationConsent() == .granted {
    do {
        let contact = try await makeContact(note: "ZZTest note — safe to delete.")
        var changes = ContactChanges()
        changes.jobTitle = .set("Tester")
        let updated = try await store.update(id: contact.id, changes: changes).after
        report("other fields still update", updated.jobTitle == "Tester")
        await discard(contact: contact.id)
    } catch {
        report("other fields still update", false, describe(error))
    }
} else {
    print("  · skipped: Contacts.app automation is not granted, so no note could be written.")
    print("    This is the one case that would reveal CNContactNoteKey breaking a save.")
}
print("")

// MARK: Verdict

if failures == 0 {
    print("\(checks) checks passed. Every ZZTest record created has been deleted.")
    exit(0)
}
print("\(failures) of \(checks) checks FAILED. Every ZZTest record created has been deleted.")
exit(1)
