import Foundation
import MCP
import Testing

@testable import ContactsMCPCore

/// Drives the tool layer end to end against `FakeContactStore`. No test in this file
/// touches Contacts.framework, so the suite runs with no permissions and no address
/// book — which is the point.
@Suite("Tool dispatch")
struct ContactToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeContactStore = FakeContactStore(contacts: Fixtures.sample),
        configuration: Configuration = Configuration()
    ) async -> (text: String, isError: Bool) {
        let result = await ContactTools(store: store, configuration: configuration)
            .handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name and a description")
    func catalogueIsWellFormed() {
        let names = ToolCatalog.all().map(\.name)
        #expect(names.count == Set(names).count)
        for tool in ToolCatalog.all() {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// A client treats an unannotated tool as write-capable and destructive. Reads
    /// must say otherwise, and the only destructive tool must admit it.
    @Test("Annotations match what each tool actually does")
    func annotationsAreHonest() {
        // Spelled out rather than derived from the naming convention: that convention
        // has its own test, and a new tool should have to declare here what it does
        // rather than inherit an answer from the shape of its name.
        let reads = [
            "contacts_status", "contacts_search", "contacts_all", "contacts_lists",
            "contacts_get",
        ]
        for tool in ToolCatalog.all() {
            if reads.contains(tool.name) {
                #expect(tool.annotations.readOnlyHint == true, "\(tool.name)")
            } else {
                #expect(tool.annotations.readOnlyHint == false, "\(tool.name)")
            }
            #expect(tool.annotations.destructiveHint == (tool.name == "delete_contact"))
        }
    }

    @Test("Write tools carry a verb prefix and reads do not")
    func namingConventionHolds() {
        for tool in ToolCatalog.all() {
            let isWrite = tool.annotations.readOnlyHint == false
            let hasVerb = ["create_", "update_", "delete_"].contains { tool.name.hasPrefix($0) }
            #expect(isWrite == hasVerb, "\(tool.name)")
        }
    }

    /// Regression guard for the defect that made update_contact unusable for lists.
    ///
    /// Claude Desktop's schema sanitiser drops any property whose `type` is a union
    /// such as `["array", "null"]`, replacing the whole subtree with `{}`. The model
    /// then sees an untyped field and serialises an array to a string, which
    /// `Arguments` rejects. Text fields hid the problem because an untyped string is
    /// still sent as a string. Nothing downstream can catch this, so it is caught here.
    @Test("No property declares its type as a union")
    func schemasDeclareScalarTypes() {
        func walk(_ value: Value, path: String) {
            guard let node = value.objectValue else { return }
            if let declared = node["type"] {
                #expect(
                    declared.stringValue != nil,
                    "\(path): type must be a single string, not a union")
            }
            for (key, child) in node["properties"]?.objectValue ?? [:] {
                walk(child, path: "\(path).\(key)")
            }
            if let items = node["items"] { walk(items, path: "\(path)[]") }
            for (index, branch) in (node["anyOf"]?.arrayValue ?? []).enumerated() {
                walk(branch, path: "\(path)|anyOf[\(index)]")
            }
        }
        for tool in ToolCatalog.all() { walk(tool.inputSchema, path: tool.name) }
    }

    // MARK: Permissions

    @Test("A denied permission names the switch and where to find it")
    func deniedPermissionExplainsItself() async {
        let store = FakeContactStore(status: .denied, contacts: Fixtures.sample)
        let result = await call("contacts_search", ["query": .string("Aurora")], store: store)
        #expect(result.isError)
        #expect(result.text.contains("System Settings"))
        #expect(result.text.contains("apple-contacts-mcp"))
    }

    @Test("An undetermined permission is requested once, not reported as failure")
    func undeterminedTriggersRequest() async {
        let store = FakeContactStore(status: .notDetermined, contacts: Fixtures.sample)
        let result = await call("contacts_search", ["query": .string("Aurora")], store: store)
        #expect(store.accessRequests == 1)
        #expect(!result.isError)
    }

    @Test("contacts_status reports without needing permission")
    func statusWorksWhileDenied() async {
        let store = FakeContactStore(status: .denied)
        let result = await call("contacts_status", store: store)
        #expect(!result.isError)
        #expect(result.text.contains("DENIED"))
    }

    /// The tool you reach for when the others are refusing to work must not itself be
    /// the thing that changes the permission. It reports; it does not request. Every
    /// other tool requests on first use, which is what the next test pins.
    @Test("contacts_status never triggers the consent dialog")
    func statusDoesNotRequestAccess() async {
        let store = FakeContactStore(status: .notDetermined)
        let result = await call("contacts_status", store: store)
        #expect(store.accessRequests == 0)
        #expect(store.status == .notDetermined)
        // And it says which tool will ask, because "not requested yet" on its own leaves
        // the reader waiting for a dialog that this tool is never going to raise.
        #expect(result.text.contains("contacts_search"))
    }

    // MARK: Search

    @Test("Search prints one line per hit, each carrying its id")
    func searchListsHits() async {
        let result = await call("contacts_search", ["query": .string("Fictitious")])
        #expect(!result.isError)
        #expect(result.text.contains("id=id-aurora"))
        #expect(result.text.contains("id=id-basilio"))
        #expect(!result.text.contains("id=id-cecilia"))
    }

    /// A page that stops short must say so; otherwise it reads as the whole answer.
    @Test("A truncated page announces what it withheld")
    func truncationIsAnnounced() async {
        let result = await call(
            "contacts_search", ["query": .string("Fictitious"), "limit": .int(1)])
        #expect(result.text.contains("…1 more"))
        #expect(result.text.contains("offset=1"))
    }

    @Test("No matches says so instead of returning an empty list")
    func emptySearchIsExplicit() async {
        let result = await call("contacts_search", ["query": .string("nobody")])
        #expect(!result.isError)
        #expect(result.text.contains("No contacts match"))
    }

    @Test("A missing query is rejected by name")
    func missingQueryIsNamed() async {
        let result = await call("contacts_search")
        #expect(result.isError)
        #expect(result.text.contains("query"))
    }

    // MARK: Delete

    @Test("Delete without confirm=true changes nothing")
    func deleteRequiresConfirmation() async {
        let store = FakeContactStore(contacts: Fixtures.sample)
        let result = await call("delete_contact", ["id": .string("id-aurora")], store: store)
        #expect(result.isError)
        #expect(result.text.contains("confirm=true"))
        #expect(store.deletedIDs.isEmpty)
        #expect(store.contacts.count == 3)
    }

    @Test("Delete describes what it removed and how to recreate it")
    func deleteIsAuditable() async {
        let store = FakeContactStore(contacts: Fixtures.sample)
        let result = await call(
            "delete_contact", ["id": .string("id-aurora"), "confirm": .bool(true)], store: store)
        #expect(!result.isError)
        #expect(store.deletedIDs == ["id-aurora"])
        #expect(result.text.contains("Aurora Fakeperson"))
        #expect(result.text.contains("+34 600 000 001"))
        #expect(result.text.contains("create_contact("))
        #expect(result.text.contains("no longer exists"))
    }

    @Test("Deleting an unknown id explains that ids go stale")
    func deleteUnknownIsExplained() async {
        let result = await call(
            "delete_contact", ["id": .string("does-not-exist"), "confirm": .bool(true)])
        #expect(result.isError)
        #expect(result.text.contains("contacts_search"))
    }

    // MARK: Create and update

    @Test("Creating with no identifying field is rejected")
    func emptyCreateIsRejected() async {
        let result = await call("create_contact", ["job_title": .string("Engineer")])
        #expect(result.isError)
        #expect(result.text.contains("at least"))
    }

    @Test("Create accepts phones as bare strings or as labelled objects")
    func createAcceptsBothPhoneShapes() async {
        let store = FakeContactStore()
        let result = await call(
            "create_contact",
            [
                "given_name": .string("Dora"),
                "phones": .array([
                    .string("+34 600 000 009"),
                    .object(["value": .string("+34 600 000 010"), "label": .string("home")]),
                ]),
            ], store: store)
        #expect(!result.isError)
        #expect(store.contacts.first?.phones.count == 2)
        #expect(store.contacts.first?.phones.last?.label == "home")
    }

    @Test("An update naming no field is rejected rather than silently doing nothing")
    func emptyUpdateIsRejected() async {
        let result = await call("update_contact", ["id": .string("id-aurora")])
        #expect(result.isError)
        #expect(result.text.contains("\"\""), "the message must show how to empty a field")
    }

    /// The distinction the whole `FieldEdit` type exists for.
    @Test("Emptying a field clears it; omitting it leaves the field alone")
    func emptyingClearsAndOmissionPreserves() async {
        let store = FakeContactStore(contacts: Fixtures.sample)
        _ = await call(
            "update_contact", ["id": .string("id-aurora"), "organization": .string("")],
            store: store)
        let updated = store.contacts.first { $0.id == "id-aurora" }
        #expect(updated?.organization == "")
        #expect(updated?.givenName == "Aurora", "an omitted field must be left alone")
    }

    /// Kept because a client may still send one even though the schema no longer
    /// advertises it; dropping support would break those callers silently.
    @Test("An explicit null still clears a field")
    func nullStillClears() async {
        let store = FakeContactStore(contacts: Fixtures.sample)
        _ = await call(
            "update_contact", ["id": .string("id-aurora"), "organization": .null], store: store)
        #expect(store.contacts.first { $0.id == "id-aurora" }?.organization == "")
    }

    @Test("An empty list empties the list rather than being ignored")
    func emptyListClearsTheList() async {
        let store = FakeContactStore(contacts: Fixtures.sample)
        _ = await call(
            "update_contact", ["id": .string("id-aurora"), "phones": .array([])], store: store)
        #expect(store.contacts.first { $0.id == "id-aurora" }?.phones.isEmpty == true)
    }

    @Test("Update accepts phones as bare strings or as labelled objects")
    func updateAcceptsBothPhoneShapes() async {
        let store = FakeContactStore(contacts: Fixtures.sample)
        let result = await call(
            "update_contact",
            [
                "id": .string("id-aurora"),
                "phones": .array([
                    .string("+34 600 000 011"),
                    .object(["value": .string("+34 600 000 012"), "label": .string("work")]),
                ]),
            ], store: store)
        #expect(!result.isError)
        let updated = store.contacts.first { $0.id == "id-aurora" }
        #expect(updated?.phones.count == 2)
        #expect(updated?.phones.last?.label == "work")
    }

    @Test("Update reports which fields moved")
    func updateNamesChangedFields() async {
        let result = await call(
            "update_contact",
            ["id": .string("id-aurora"), "organization": .string("Other Fictitious")])
        #expect(result.text.contains("organization"))
    }

    /// Value lists replace wholesale, so a `relations` argument carrying one entry
    /// silently discards the others — and the response looked identical to an add
    /// until this was reported. Aurora's fixture starts with no relations, so this
    /// pins the growth direction; the shrink direction is exactly the risk that
    /// prompted the feature, and a production session losing relations this way is
    /// what it exists to make visible.
    @Test("Update reports a multi-value field's count before and after")
    func updateReportsMultiValueCountChange() async {
        let result = await call(
            "update_contact",
            [
                "id": .string("id-aurora"),
                "relations": .array([
                    .object(["label": .string("sister"), "value": .string("Someone")]),
                    .object(["label": .string("brother"), "value": .string("Someone Else")]),
                ]),
            ])
        #expect(!result.isError)
        #expect(result.text.contains("relations: 0 → 2"))
    }

    /// A relation naming the contact itself is likely a mistake, not a rule violation —
    /// this server cannot know who anyone really is, so it warns rather than refuses.
    @Test("Update warns, but does not fail, when a relation names the contact itself")
    func updateWarnsOnSelfRelation() async {
        let result = await call(
            "update_contact",
            [
                "id": .string("id-aurora"),
                "relations": .array([
                    .object(["label": .string("twin"), "value": .string("Aurora Fakeperson")])
                ]),
            ])
        #expect(!result.isError)
        #expect(result.text.contains("its own relation"))
    }

    // MARK: Photo write hardening

    /// The switch has to stop the write before it happens, not merely drop the
    /// argument: a caller who cannot tell "refused" from "there was nothing to change"
    /// would retry with the same photo_path and get the same silent no-op forever.
    @Test("create_contact refuses photo_path when photo writes are disabled")
    func createRefusesPhotoWhenDisabled() async {
        let store = FakeContactStore()
        let result = await call(
            "create_contact",
            ["given_name": .string("Zed"), "photo_path": .string("/tmp/whatever.jpg")],
            store: store,
            configuration: Configuration(disablePhotoWrites: true))
        #expect(result.isError)
        #expect(result.text.contains("Photo writes are disabled"))
        #expect(store.contacts.isEmpty, "the disabled write must not reach the store at all")
    }

    @Test("update_contact refuses to set photo_path when photo writes are disabled")
    func updateRefusesSettingPhotoWhenDisabled() async {
        let store = FakeContactStore(contacts: Fixtures.sample)
        let result = await call(
            "update_contact",
            ["id": .string("id-aurora"), "photo_path": .string("/tmp/whatever.jpg")],
            store: store,
            configuration: Configuration(disablePhotoWrites: true))
        #expect(result.isError)
        #expect(result.text.contains("Photo writes are disabled"))
    }

    /// "" on photo_path means "remove the photo" — the same hardening switch must catch
    /// a clear as well as a set, since both touch the photo.
    @Test("update_contact refuses to clear photo_path when photo writes are disabled")
    func updateRefusesClearingPhotoWhenDisabled() async {
        let result = await call(
            "update_contact",
            ["id": .string("id-aurora"), "photo_path": .string("")],
            configuration: Configuration(disablePhotoWrites: true))
        #expect(result.isError)
        #expect(result.text.contains("Photo writes are disabled"))
    }

    @Test("create_contact with photo_path still works when photo writes are not disabled")
    func createAllowsPhotoWhenNotDisabled() async {
        // Configuration() defaults to disablePhotoWrites == false: an install that never
        // touched the setting must see no change in behaviour.
        let result = await call(
            "create_contact",
            ["given_name": .string("Zed"), "photo_path": .string("/tmp/whatever.jpg")])
        #expect(!result.isError)
    }

    // MARK: Unknown tool

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async {
        let result = await call("contacts_delete_everything")
        #expect(result.isError)
    }
}
