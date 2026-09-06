# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Reading the address book is always fine. Do not modify or delete an existing contact or List membership. Test contacts/Lists may be created but must be clearly named `TESTING: ...` and cleaned up when done.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Contacts app through `Contacts.framework`. Reads and writes the address book on this Mac. No network, no credential, no cloud API — iCloud is only the sync engine, gated by TCC consent.

## Commands

```bash
swift build                      # debug
swift build -c release           # what Claude Desktop should run
swift test                       # all against the fake store
```

```bash
otool -P .build/release/apple-contacts-mcp | grep -E 'NSContactsUsageDescription|NSAppleEventsUsageDescription'
```
