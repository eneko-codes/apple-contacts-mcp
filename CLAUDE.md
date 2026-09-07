# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Reading the address book is always fine. Do not modify or delete an existing contact or List membership.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real address book, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own contact or List and work on that; failing that, ask the owner to make a throwaway one; failing that, work on a copy. Touching what the owner made is the last resort, has to have been named in the ask, and has to be undoable. Anything you are allowed to create must be clearly named `TESTING: ...` and removed in the same session.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Contacts app through `Contacts.framework`. Reads and writes the address book on this Mac. No network, no credential, no cloud API — iCloud is only the sync engine, gated by TCC consent.

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
