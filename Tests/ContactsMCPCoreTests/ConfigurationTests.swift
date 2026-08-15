import Foundation
import MCP
import Testing

@testable import ContactsMCPCore

/// Almost everything in `Configuration` is a fixed constant now — the owner's
/// plug-and-play rule removed the connector setting that used to let a person override
/// the search-result default. `disablePhotoWrites` is the one exception, arriving as a
/// command-line flag exactly the way `apple-filesystem-mcp`'s `read_roots`/`write_roots`
/// do. What is worth pinning is that the constant is what the tool layer actually uses,
/// not merely what it says in a doc comment, and that the flag parses the way the
/// manifest actually substitutes it.
@Suite("Configuration")
struct ConfigurationTests {

    @Test("The documented default is 25")
    func defaultHolds() {
        #expect(Configuration.searchLimit == 25)
    }

    @Test("contacts_search falls back to Configuration.searchLimit when limit is omitted")
    func searchUsesTheFixedDefault() async {
        let store = FakeContactStore(contacts: Fixtures.sample)
        let tools = ContactTools(store: store)
        _ = await tools.handle(
            .init(name: "contacts_search", arguments: ["query": .string("Fictitious")]))
        #expect(store.lastSearchLimit == Configuration.searchLimit)
    }

    @Test("disablePhotoWrites defaults to false, so an unconfigured install is unaffected")
    func photoWritesDefaultToEnabled() {
        #expect(Configuration().disablePhotoWrites == false)
    }

    @Test("--disable-photo-writes true turns the switch on")
    func parsesTheFlag() {
        #expect(Configuration.parse(["--disable-photo-writes", "true"]).disablePhotoWrites == true)
        #expect(Configuration.parse(["--disable-photo-writes", "false"]).disablePhotoWrites == false)
    }

    /// Claude Desktop leaves `${user_config.key}` untouched when a checkbox setting was
    /// never set, and that literal text must not be read as either "true" or "false" —
    /// it has to fall back to the documented default instead.
    @Test("An unsubstituted manifest placeholder is ignored, not read as a value")
    func ignoresUnsubstitutedPlaceholder() {
        let configuration = Configuration.parse([
            "--disable-photo-writes", "${user_config.disable_photo_writes}",
        ])
        #expect(configuration.disablePhotoWrites == false)
    }

    @Test("An unknown flag is ignored rather than crashing the parse")
    func ignoresUnknownFlags() {
        let configuration = Configuration.parse(["--some-future-flag", "value"])
        #expect(configuration.disablePhotoWrites == false)
    }
}
