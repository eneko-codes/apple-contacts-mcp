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
| `contacts_search` | read | Finds people by name, nickname, company, phone or email. One line per hit, a page at a time. |
| `contacts_all` | read | Every contact, or everyone in one List, a page at a time, with a compact names-and-ids mode. |
| `contacts_lists` | read | The Lists, how many people each holds, and the accounts they live in, a page at a time. |
| `contacts_get` | read | Every field stored for one id, including List membership and the note; a long record a window at a time. The photo only on request, reduced. |
| `create_contact` | write | Adds a new contact and shows the start of the record stored. |
| `update_contact` | write | Changes fields. Omitted = untouched, `""` or `[]` = cleared. Shows the start of the record afterwards. |
| `update_contact_lists` | write | Adds to Lists or removes from them. Never deletes a contact. |
| `delete_contact` | **destructive** | Permanent. Requires `confirm: true`. Shows as much of the removed record as one result holds. |

Search first, then use the returned id — Contacts identifiers are not guessable and can
change when an account resynchronises.

Every property `CNContact` exposes is readable and writable: all the name parts and their
phonetic spellings, organisation, phones, emails, websites, postal addresses down to
sub-locality and ISO country code, social profiles, instant messaging handles, related
people, birthday, other dates such as anniversaries, the photo, the note, and whether the
record is a person or a company.

## Frameworks and APIs

| Used | For | Reference |
|---|---|---|
| Contacts — `CNContactStore`, `CNContact`/`CNMutableContact`, `CNGroup`, `CNContainer`, `CNSaveRequest`, `CNLabeledValue`, `CNContactFormatter` | Every read, and most writes | [Contacts](https://developer.apple.com/documentation/contacts) |
| Apple events — `AEDeterminePermissionToAutomateTarget`, `osascript` | The note field, and the saves Contacts.framework refuses on a noted contact | [Apple Events](https://developer.apple.com/documentation/coreservices/apple_events) |
| `NSContactsUsageDescription`, `NSAppleEventsUsageDescription` | The two consent strings macOS shows | [Information Property List](https://developer.apple.com/documentation/bundleresources/information-property-list/nscontactsusagedescription) |

Contacts areas this server does not use: `CNContactVCardSerialization` (no vCard import or
export), the change-history stack (`CNChangeHistoryFetchRequest`), `CNPostalAddressFormatter`,
`CNContactsUserDefaults`, and `CNMutableGroup` — Lists can be joined and left, but not
created, renamed or deleted. ContactsUI is a user-interface framework and has no place in a
stdio server.

## The rules worth knowing before you use it

- **Search first.** Every tool that takes a contact takes the id `contacts_search` (or
  `contacts_all`) returned. Ids are not guessable and can change when an account is
  resynchronised, so look one up again rather than reusing it from an earlier conversation.
- **There are two permissions.** Contacts covers reading and most writing. Automation —
  permission to control Contacts.app — covers what `Contacts.framework` cannot do: the note
  field, and changing List membership or any other field on a contact that has a note.
  `contacts_status` reports both.
- **Contacts.app can accept a change and not save it, with no error** — it does so for every
  contact that Screen Time allows during downtime, whatever field changes. Every write
  through Contacts.app is checked: a save that did not happen fails the call. Only treat a
  change as made when the tool call succeeded.
- **Multi-value fields are replaced wholesale, not merged.** Passing one new phone number
  discards the others. `update_contact` reports each touched field's count before and
  after; read the contact first when you touch phones, emails and the like.
- **Membership is separate.** `update_contact_lists` changes only which Lists a person is in;
  removing someone from a List never deletes them. `create_contact` can apply membership in
  the same save as the creation, which is preferable for a new contact.
- **Deleting is permanent** and `delete_contact` requires `confirm=true`. Its result is the
  last copy of the record, and it holds only so much: read a contact with a long note in
  full with `contacts_get` before deleting it.
- **Every result is bounded, and says what it left out.** Contacts, Lists and accounts come
  one page at a time, ordered by name and then id; one contact's record comes one window at
  a time when it is long, which a long note makes it. When a result does not hold
  everything, its first lines say how much there is and the exact arguments that return
  the rest: `limit` and `offset` for rows, `character_offset` and `max_characters` for a
  record. A number outside its range is moved to the nearest allowed value and the first
  lines say which one was used; a value of the wrong type, or a date that does not exist,
  is refused. A value too wide for its row is shortened there, and the result says so. A
  write shows the start of the record it wrote, and `contacts_get` resumes at the
  character where it stopped. The sizes are constants in `ToolCatalog.swift`, which the
  schemas and descriptions quote. No result is longer than `ToolStandard.longestResult`:
  each tool keeps to that itself, and the protocol layer cuts, with a notice, any result
  that did not.
- **`note` replaces the whole note.** Read all of a long note, every window of it, before
  writing it back; what was not read is lost.
- **Every call has a deadline.** One that has not finished after 180 seconds is abandoned and
  answered with an error that says so. A read changed nothing. A write may still land,
  because a save already handed to Contacts cannot be recalled: read the contact again
  before retrying.

## Install

### 1. Build the bundle

```bash
security find-identity -v -p codesigning   # copy the 40-character hash of an Apple Development or Developer ID Application identity
MCPB_SIGN_IDENTITY="<identity hash>" ./scripts/pack.sh
```

Pass the hash, not the certificate's name: `pack.sh` prints the identity it signs with,
and the name is yours.

That builds an arm64 (Apple silicon only) release binary, signs it, checks the embedded
`Info.plist` survived both linking and signing, prints the designated requirement, and
writes `dist/apple-contacts-mcp.mcpb`. It fails loudly rather than shipping a bundle that
would silently refuse to work.

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

Reads and contact creation work without it. Automation is also needed to update any field
on a contact that carries a note, and to change List membership on one, because the save
reaches through Contacts.app in those cases. `contacts_status` reports both permissions
separately, so a note that will not appear is one call away from an explanation.

**A save through Contacts.app is checked, not assumed.** Contacts.app's `save` was
observed returning with no error while saving nothing: the edits stayed in its own
memory, reading them back through it returned them as if stored, and neither the address
book on disk nor iCloud ever received them. The measured cause is a contact
that Screen Time allows during downtime: every save touching one fails this way, whatever
field changes, while an otherwise identical card saves normally. Contacts.framework does
not expose that flag, so such a contact cannot be spotted before the save is tried.

So every script checks Contacts.app's `unsaved` property before and after its change. A
call is refused untouched when Contacts.app already holds unsaved changes — its save
writes all of them at once — and notes read as unavailable meanwhile, which
`contacts_status` reports. When the call's own save did not happen, the call fails and
Contacts.app is quit without saving. That discards only that edit, since nothing else was
pending, and it is the only way out: a failed edit left in place blocks every later write
until Contacts.app is quit by hand.

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

That survives rebuilds: same identity, same requirement, no second consent dialog. `pack.sh` prints the requirement on
every build, so a silent regression to ad-hoc is visible immediately.

**Changing certificate re-prompts once.** The requirement quotes the certificate, so
moving between ad-hoc, Apple Development and Developer ID each costs one fresh round of
consent. Notarisation requires a Developer ID Application certificate. Check a
certificate's expiry date in Keychain Access rather than assuming how long it lasts.

### Preparing something to distribute

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="<Developer ID Application hash>" ./scripts/pack.sh
```

That adds the hardened runtime and a secure timestamp, which notarisation requires.
Contacts itself is reached directly through its framework and needs no entitlements, but
the hardened runtime blocks Apple events — which is how notes are read — so `pack.sh`
also passes `Resources/entitlements.plist`, holding
`com.apple.security.automation.apple-events`. That one is not restricted: no request to
Apple, no profile.

## Tool switches

One setting: `disable_photo_writes`, offered as a `user_config` in the bundle and passed as
`--disable-photo-writes`. With it on, a write that would replace a contact's photo is
refused. Every tool can also be turned on and off
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
- **Unsaved changes in Contacts.app block notes.** The check above cannot tell whose
  pending edits they are, so while Contacts.app holds any, notes are neither read nor
  written, and neither are the fields or List membership of a contact that has one.
- **A contact Screen Time allows during downtime cannot be changed through Contacts.app.**
  That covers its note, and any field or List change on it when it has a note. The call
  fails and says so, and Contacts.app is quit to discard the edit. Take the contact off
  the allowed list for the change, or edit it by hand in Contacts.app or on iCloud.com.
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
  and phone only, so a company search falls back to scanning the address book. The scan
  stops after 20 seconds and the result then says it is partial.
- **The photo is returned reduced.** `include_photo` gives a JPEG of at most 1568 pixels a
  side and 1.5 MB, never the stored original, which can be many times that. A stored photo
  that cannot be decoded is reported, not returned.
- **macOS has no partial Contacts access.** `CNAuthorizationStatus.limited` is iOS-only;
  here it is all or nothing.

## Development

```bash
swift build
swift test
```

The tests run entirely against an in-memory fake. They need no permissions and never touch a real
address book — see `CLAUDE.md`, whose first section is the rule that makes that
non-negotiable.

Manual verification against a live address book is the owner's job.

## Licence

MIT.
