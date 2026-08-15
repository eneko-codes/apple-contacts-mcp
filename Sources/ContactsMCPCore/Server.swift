import Foundation
import MCP

public enum ContactsMCPServer {

    public static let name = "apple-contacts-mcp"
    public static let version = "1.0.0"

    /// Returned from `initialize`. It carries the two things per-tool descriptions
    /// cannot state once: that ids come from a search and are not durable, and that
    /// what this server is allowed to do is decided by the permission switches in the
    /// client, not by the code.
    public static let instructions = """
        Access to the macOS Contacts app through Contacts.framework.

        Workflow: search first with contacts_search and use the id it returns. Contacts \
        identifiers are not guessable and can change when an account is resynchronised, so \
        do not reuse one from an earlier conversation without looking it up again.

        contacts_all answers questions about the address book as a whole — how many \
        contacts there are, who is in a list — and contacts_lists shows the Lists and the \
        accounts they live in. contacts_get returns every field Contacts stores for one \
        person, including which Lists they belong to.

        There are two permissions, and contacts_status reports both. Contacts covers \
        reading and most writing. Automation — permission to control Contacts.app — covers \
        the three things Contacts.framework cannot do from here: the note field, changing \
        List membership on a contact that has one (either direction), and updating any \
        other field on a contact that has one. The note field is a framework limitation \
        with no workaround; the other two are because a save touching a noted contact \
        needs a key this server is not allowed to read, regardless of what is changing.

        create_contact accepts lists and applies membership in the same save as the \
        creation — prefer that over a follow-up update_contact_lists call when the \
        contact is new, since a just-created contact has nothing that reindex can trip \
        on.

        For annotating a person with a link, prefer urls with a descriptive label \
        ("GitHub", "Expediente"): labels are free text and work on every contact. \
        social_profiles also accepts any service name. Only instant_messages is \
        restricted, and only on a contact that has a note, where Contacts.app knows a \
        fixed set of services.

        Write tools carry a verb prefix (create_, update_, delete_). delete_contact is \
        permanent and requires confirm=true. update_contact_lists changes only membership \
        — removing someone from a list never deletes them. update_contact reports each \
        touched list-type field's count before and after, since those fields replace \
        wholesale rather than merge.

        This server exposes the address book's full capability. What may be used at any \
        moment is decided by the permission switches in the client, not by this code.
        """

    /// Wires the catalogue to a store and serves stdio until the client disconnects.
    ///
    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function reads an address book by itself.
    public static func run(
        store: any ContactStore = SystemContactStore(),
        configuration: Configuration = Configuration()
    ) async throws {
        let tools = ContactTools(store: store, configuration: configuration)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolCatalog.all())
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await tools.handle(parameters)
        }

        // The default StdioTransport logger is a no-op handler. Leave it that way:
        // a logger that writes to stdout would interleave with the JSON-RPC stream
        // and break every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
