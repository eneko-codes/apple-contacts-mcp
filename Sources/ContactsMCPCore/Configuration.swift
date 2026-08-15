import Foundation

/// Settings the person installing the extension can change.
///
/// Everything except `disablePhotoWrites` is a fixed constant per the owner's
/// plug-and-play rule — there is nothing else here to configure, and the per-tool
/// allow/ask/prohibit switch in Claude Desktop is the only other knob. `disablePhotoWrites`
/// is the deliberate exception: a hardening switch, not a preference, in the same spirit
/// as `apple-filesystem-mcp`'s `read_roots`/`write_roots`. It arrives as a command-line
/// argument because that is how a Claude extension passes `user_config`: the manifest
/// substitutes `${user_config.disable_photo_writes}` into `mcp_config.args`.
public struct Configuration: Sendable, Equatable {
    /// When true, no tool may set or clear a contact's photo, even if `photo_path` is
    /// present in the call. Off by default, so an install that has not touched this
    /// setting is unaffected.
    public var disablePhotoWrites: Bool = false

    public init(disablePhotoWrites: Bool = false) {
        self.disablePhotoWrites = disablePhotoWrites
    }

    /// Default page size for `contacts_search` and `contacts_all` when the caller does
    /// not say. The tool's own `limit` argument still wins; this only sets the default.
    public static let searchLimit = 25

    public static let searchLimitRange = 1...100

    /// `contacts_all` gets a higher ceiling than search does. Enumerating an address
    /// book of two thousand people through a hundred-row window is twenty calls, and
    /// its compact mode prints one short line per contact, so a large page is cheap in
    /// a way a search result full of phone numbers and companies is not.
    public static let listLimitRange = 1...500

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...10_000

    /// True when an argument is an unsubstituted manifest placeholder.
    ///
    /// Claude Desktop leaves `${user_config.key}` untouched when the person left that
    /// setting empty, so the literal text arrives as an argument. Taking that at face
    /// value would read as "true" or "false" depending on how the placeholder text
    /// happens to compare, which is worse than falling back to the default.
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// Unknown flags are ignored rather than fatal. A manifest written against a newer
    /// version of this binary should degrade to defaults, not refuse to start — a server
    /// that will not launch is much harder to diagnose than one running on a default.
    public static func parse(_ arguments: [String]) -> Configuration {
        var configuration = Configuration()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            // An unset checkbox in the manifest can substitute to an empty string.
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil

            switch flag {
            case "--disable-photo-writes":
                if let value, !isPlaceholder(value) {
                    configuration.disablePhotoWrites = (value as NSString).boolValue
                }
                index += 2
            default:
                index += 1
            }
        }
        return configuration
    }
}
