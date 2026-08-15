<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="apple-contacts-mcp icon">
</p>

# apple-contacts-mcp

A local MCP server, written in Swift, exposing the macOS **Contacts** app to Claude
through `Contacts.framework`. It ships as a Claude extension.

No network, no credentials, no cloud API. iCloud is only the sync engine that fills the
local address book; this server reads and writes that local store, and the gate is macOS
**privacy consent** rather than authentication.

Not affiliated with or endorsed by Apple Inc.

## Requirements

- macOS 15 or later
- Swift 6.0 or later (Xcode 26 ships it)
- A code signing identity. Ad-hoc works, but every rebuild then asks for permission
  again — see [Signing](#signing-and-why-it-is-not-optional).

## Tools

Reads carry no verb prefix, writes always start with one. Claude Desktop sorts the
permission switches alphabetically, so this groups the destructive tools together.

| Tool | Kind | What it does |
|---|---|---|
| `contacts_status` | read | Reports both permissions, the binary in use and the default page size. Reads no records. |
| `contacts_search` | read | Finds people by name, nickname, company, phone or email. One line per hit. |
| `contacts_all` | read | Every contact, or everyone in one List. Paged, with a compact names-and-ids mode. |
| `contacts_lists` | read | The Lists, how many people each holds, and the accounts they live in. |
| `contacts_get` | read | Every field stored for one id, including List membership and the note. |
| `create_contact` | write | Adds a new contact. |
| `update_contact` | write | Changes fields. Omitted = untouched, `""` or `[]` = cleared. |
| `update_contact_lists` | write | Adds to Lists or removes from them. Never deletes a contact. |
| `delete_contact` | **destructive** | Permanent. Requires `confirm: true`. |

Search first, then use the returned id — Contacts identifiers are not guessable and can
change when an account resynchronises.

Every property `CNContact` exposes is readable and writable: all the name parts and their
phonetic spellings, organisation, phones, emails, websites, postal addresses down to
sub-locality and ISO country code, social profiles, instant messaging handles, related
people, birthday, other dates such as anniversaries, the photo, the note, and whether the
record is a person or a company.

## Install

### 1. Build the bundle

```bash
MCPB_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/pack.sh
```

That builds a universal (arm64 + x86_64) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-contacts-mcp.mcpb`. It fails loudly rather than shipping a bundle that
would silently refuse to work.

List the identities available to you with:

```bash
security find-identity -v -p codesigning
```

### 2. Install it

Open `dist/apple-contacts-mcp.mcpb` with Claude. Then **quit Claude Desktop completely
and reopen it** — reinstalling does not replace a server process that is already running,
and the old one keeps answering.

### 3. Grant the permission

Call `contacts_status`. If macOS has never asked, the first call that needs data raises
the consent dialog. Approve it, and the entry appears as **apple-contacts-mcp** under
System Settings → Privacy & Security → Contacts
(Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Contactos).

The binary is **its own privacy subject**. Claude Desktop launches MCP servers through
`Contents/Helpers/disclaimer`, which calls `responsibility_spawnattrs_setdisclaim`, so
the child process cannot inherit the host app's permissions — and Claude.app declares no
Contacts usage description anyway. That is why this package embeds its own `Info.plist`
into the binary at link time.

If no dialog ever appears, check the usage descriptions really survived linking:

```bash
otool -P extension/server/apple-contacts-mcp | grep -E 'NSContactsUsageDescription|NSAppleEventsUsageDescription'
```

### 4. Grant the second permission, if you want notes

The Notes field is the one thing `Contacts.framework` will not hand over. Reading or
writing `CNContactNoteKey` requires `com.apple.developer.contacts.notes`, a **managed
capability**: it needs a paid developer account, Apple's approval, and a provisioning
profile — and a command-line executable has nowhere to carry a profile, so no amount of
signing makes it work. Apple's own guidance for this case is to script the Contacts app,
which owns the data and needs no entitlement to reach it, and that is what this server
does.

The cost is a second consent, in a different pane. The first tool call that touches a
note raises it, and the entry then appears under
System Settings → Privacy & Security → Automation → **apple-contacts-mcp** → Contacts
(Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Automatización).

Everything except the note works without it. `contacts_status` reports both permissions
separately, so a note that will not appear is one call away from an explanation.

### Signing, and why it is not optional

`swift build` leaves a signature the linker generated, flagged `linker-signed`. macOS
treats that as signed by nobody: it produces **no designated requirement**, so there is
nothing to anchor a permission to except the binary's cdhash — and every rebuild changes
that. Worse, a linker-signed binary never gets a consent dialog at all; the request
returns with the status still "not determined".

Signing with a real certificate produces a requirement anchored to the bundle identifier
and the certificate instead:

```
designated => identifier "codes.eneko.apple-contacts-mcp" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: …"
```

That survives rebuilds — verified by installing two builds with different cdhashes and
the same identity, with no second consent dialog. `pack.sh` prints the requirement on
every build, so a silent regression to ad-hoc is visible immediately.

**Changing certificate re-prompts once.** The requirement quotes the certificate, so
moving between ad-hoc, Apple Development and Developer ID each costs one fresh round of
consent. An Apple Development certificate is valid for about a year; a Developer ID
Application certificate lasts five and is what notarisation requires.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="Developer ID Application: …" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires.
Contacts itself is reached directly through its framework and needs no entitlements, but
the hardened runtime blocks Apple events — which is how notes are read — so `pack.sh`
also passes `Resources/entitlements.plist`, holding
`com.apple.security.automation.apple-events`. That one is not restricted: no request to
Apple, no profile.

## Tool switches

Plug and play: there is nothing to configure. Every tool can be turned on and off
individually, because the bundle declares them all in its manifest. That is where policy
lives — not in this code. The server exposes the full capability of the app; which parts
are reachable at any moment is your decision.

Turning off `create_contact`, `update_contact`, `update_contact_lists` and
`delete_contact` leaves a strictly read-only server. `contacts_all` has its own switch
because reading the whole address book is a different thing from looking one person up.

**Reinstalling may reset the switches.** Check them after every install.

## Manual registration instead

Registering the binary directly in
`~/Library/Application Support/Claude/claude_desktop_config.json` also works, but you
lose the per-tool switches.

```json
{
  "mcpServers": {
    "Apple Contacts": {
      "command": "/absolute/path/to/apple-contacts-mcp/.build/release/apple-contacts-mcp"
    }
  }
}
```

Do not do both at once. Two registrations under the same display name collide, and the
one that wins is not the one you expect — `contacts_status` prints the binary path
precisely so you can tell them apart.

## Known limits

- **Notes need a second permission.** They are the one field that does not come from
  `Contacts.framework`, for the reason described above, so they need Automation consent
  rather than Contacts consent. Without it, `contacts_get` returns the whole record and
  says the note could not be read, and `update_contact` refuses the note rather than
  half-applying the change.
- **Reading a note launches the Contacts app.** In the background, but it does launch,
  and the first call after a cold start is slow.
- **Lists cannot be created, renamed or deleted here.** Membership can be changed;
  the lists themselves are managed in Contacts.
- **List membership costs one fetch per list.** Contacts keeps no reverse index — a
  contact does not know which lists it is in — so `contacts_get` asks every list who
  belongs to it. Fine for a normal address book, noticeable with dozens of lists.
- **No duplicate detection.** Contacts will store two identical records without
  complaint. Search before creating.
- **Value lists replace, they do not merge.** Passing `phones` to `update_contact`
  discards the numbers you did not include.
- **Organization-only search is a fallback.** Contacts offers predicates for name, email
  and phone only, so a company search falls back to scanning the address book.
- **macOS has no partial Contacts access.** `CNAuthorizationStatus.limited` is iOS-only;
  here it is all or nothing.

## Development

```bash
swift build
swift test
```

79 tests, all against an in-memory fake. They need no permissions and never touch a real
address book — see `CLAUDE.md`, whose first section is the rule that makes that
non-negotiable.

Manual verification against a live address book is the owner's job; `verification.md`
is the script for it.

## Licence

MIT.
