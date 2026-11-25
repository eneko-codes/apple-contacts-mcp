# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Reading the address book is always fine. Do not modify or delete an existing contact or List membership.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real address book, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own contact or List and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Anything you are allowed to create must be clearly named `TESTING: ...` and removed in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Contacts app through `Contacts.framework`. Reads and writes the address book on this Mac. No network, no credential, no cloud API — iCloud is only the sync engine, gated by TCC consent. **No third-party dependency**: `Package.swift` lists none, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so.

**`MCPServer.swift`, `Value.swift`, `ToolStandard.swift` and the tests `MCPProtocolTests.swift` and `ToolStandardTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test files differ only in their `@testable import`). A change to one is made to every copy in the same piece of work; never let a copy drift.

`ToolStandard.swift` holds what every tool here must keep to: the longest result, description and error, the time a call may take, the fixed wording of each notice that says what a result left out (`Notice`), and the guard `MCPServer.swift` passes every result through. A tool bounds its own result and says how to get the rest; the guard only catches the one that forgot.

## Apple frameworks

[Contacts](https://developer.apple.com/documentation/contacts) for everything the framework will do: `CNContactStore`, `CNContact`/`CNMutableContact`, `CNGroup`, `CNContainer`, `CNSaveRequest`, `CNLabeledValue`, `CNContactFormatter`, the `CNKeyDescriptor` key constants. [Apple events](https://developer.apple.com/documentation/coreservices/apple_events) for the rest — `AEDeterminePermissionToAutomateTarget` to check consent, `osascript` to drive Contacts.app. Consent keys: [`NSContactsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nscontactsusagedescription) and [`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription).

## Native surface not used

The framework offers more than this server exposes. Before proposing a tool, check it against this list rather than assuming.

- `CNMutableGroup` — a List can be joined and left, never created, renamed or deleted.
- `CNContactVCardSerialization` — no vCard import or export.
- `CNChangeHistoryFetchRequest`/`CNChangeHistoryEvent` — no "what changed since" feed.
- `CNPostalAddressFormatter` — addresses are formatted here by hand.
- `CNContactProperty`, `CNContactsUserDefaults`, `CNFetchResult`.
- ContactsUI in its entirety — it is a user-interface framework, and this is a stdio server.
- `CNContactNoteKey` is named but never fetched through the framework: a save touching a noted contact needs an entitlement this server does not have, so the note is read and written through Contacts.app instead.

## Contacts.app writes

Contacts.app's `save` can return with no error and save nothing. Measured cause: a contact that Screen Time allows during downtime (`ZDOWNTIMEWHITELIST` in the store, not exposed by Contacts.framework). Every save touching one fails, whatever field changes; a card with a WhatsApp-contributed IM and no flag saved fine. One failed save leaves `unsaved` true and blocks every later save. A read-back through Contacts.app is not evidence: it answers from its own unsaved model. The only independent check of a note is the store on disk. Every script therefore gates on `unsaved` before its change, and after it quits Contacts.app without saving when its own save did not happen (`ContactsAppScripting`); do not remove either to make a write "work".

## The live-check executable

`Sources/contacts-live-check` is a second executable that writes to the **real** address book. It is not part of `swift test` and must never be run to satisfy a test. Running it is live data under the rule above: ask first.

## Commands

```bash
swift build                      # debug
swift build -c release           # what Claude Desktop should run
swift test                       # all against the fake store
```

```bash
otool -P .build/release/apple-contacts-mcp | grep -E 'NSContactsUsageDescription|NSAppleEventsUsageDescription'
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone — a plain `swift build -c release`, no `--arch` flags — and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.

`ContactStore` is the only door to the address book. `SystemContactStore` implements it over Contacts.framework and Contacts.app; tests implement it with `FakeContactStore`. The store returns every match in no order: ordering and paging belong to `ContactTools`, so the fake and the real store cannot disagree about them.

**How a tool keeps to the tool standard here.** Sizes are constants in `ToolCatalog`, and the schemas, the descriptions and the instructions quote them by interpolation, never as literals. `Arguments.int` moves a quantity (`limit`, `offset`, a window) into its range and collects the sentence that says so in `notices`; every other accessor refuses a value of the wrong type, and a date that does not exist. A listing (`contacts_search`, `contacts_all`, `contacts_lists`) sorts its rows into an order it states, down to the id so that nothing ties, then goes through `ContactTools.page`, which puts the notices and the page's position (`Notice.page`) before the rows. `Format.Clipper` shortens a value wider than `ToolCatalog.cellWidth` inside a row and the page says so (`Notice.clipped`). A contact's record is one text with no length limit, `Format.record`: `contacts_get` returns a window of it (`ToolStandard.window`), and a write shows its start, so the offset where a receipt stops is the `character_offset` that `contacts_get` resumes from. Everything renders through `ToolStandard.fitting`, which halves a page or a window whose text would still be longer than a result may be, so a tool never leans on the guard. A photo is not text and the guard does not shorten it: `ContactPhoto` redraws it within a pixel and a byte ceiling, or it is not returned. Errors repeat a caller's text only through `ToolStandard.echo`, and a text Contacts wrote only through `ToolError.clipped`.

**Every call has a deadline**, `ContactTools.defaultTimeout`, inside `ToolStandard.timeLimit`. At it the call is answered with an error and the work is cancelled, not stopped: a read's enumeration and the loop over Lists in `update_contact_lists` notice and stop, but a save already handed to Contacts or Contacts.app may still land, which is why the error for a write says its outcome is unknown. The fallback scan of `contacts_search` has its own, shorter limit (`ToolCatalog.scanTimeLimit`) and answers with what it found (`Notice.partial`). `BoundsTests` holds every bound, notice and length to this: a new listing takes `limit` and `offset` through `Arguments.page` and gets an entry in its `listings`.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, a result, an error's `localizedDescription` or an identifier; log a fixed event, the tool name, the error's kind and a duration.
