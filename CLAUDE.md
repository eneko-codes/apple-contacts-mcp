# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## HARD RULE — READING IS FREE; CHANGING A REAL RECORD NEEDS THE OWNER'S WORD

**Reading the address book is allowed.** This is a contacts server; reading contacts,
Lists and accounts — all of them, in full — is the job, not a transgression. Search it,
page it, read any record. No permission beyond macOS's own is needed to *look*.

**Changing a real record requires the owner's explicit approval, per change.** Creating,
updating, deleting a contact the owner made, or moving one in or out of a List, is only
allowed when the owner asked for that specific change in that session. Contacts has no
undo and keeps no copy, so the standard is a clear instruction to make *this* change —
not a general "sort out my contacts", not approval carried over from an earlier change,
and not the agent's own judgement that a record would be better a different way.

Never, with or without approval:

- change a record the owner did not ask you to change, however small the improvement;
- treat one approval as standing permission for the next change;
- edit the Contacts store directly on disk, going around the framework;
- leave anything behind that was not there when the session started.

When in doubt about whether a change was approved, ask. A refusal costs a message; a
wrong edit to somebody's address book is silent and permanent.

### Automated verification always builds its own subjects

Approval covers changes the owner *asked for*. It does not cover a test suite writing
twenty-four fields at whatever record happened to be handy — nobody reviewed that record
case by case, and a test is not a decision. So verification creates its own data, always,
and that rule does not relax even when write approval has been given.

Some defects live below the `ContactStore` seam and **no fake can reach them**. Three
have already shipped from exactly there: the note entitlement destroying an entire
`create_contact` save; the schema union that made `update_contact` reject every list;
and the Core Data faulting failure that made every `update_contact` and
`update_contact_lists` call fail while `create_contact` succeeded. Not one of them was
catchable by any test in this repository, and each cost a round trip through the owner
to diagnose. So live verification is a supported workflow here, not a grudging
exception — and it is safe because of *what it is allowed to touch*, never because of
how careful the agent intends to be.

Five rules make it safe. None is optional and none may be relaxed for convenience:

1. **Create your own subject. Never borrow one.** Every contact and every List the live
   check touches must have been created by that same run. A real record is never the
   subject of a test, not even a read-only one — however freely the agent may read that
   record elsewhere.
2. **Mark it disposable at a glance.** `ZZTest` prefix on every name, so a leftover is
   unmistakable in Contacts.app and can never be taken for a real person or List.
3. **Delete it in the same run, including on failure.**
4. **Address only what you created, by the identifier the create returned.** The live
   check never searches or enumerates: if it cannot find its own subject by that
   identifier, it fails rather than going looking.
5. **Tell the owner** what was created and that it is gone.

```bash
swift test                # fake-only; never opens the address book
scripts/live-check.sh     # the live check, against its own ZZTest records
```

**The live check is an executable, not a test target, and that is forced.** `swift test`
loads an `.xctest` bundle whose host binary is linker-signed and carries no
`NSContactsUsageDescription`, so macOS denies Contacts access **without ever prompting**
and `authorizationStatus` stays `notDetermined` forever — the same trap documented in the
TCC notes below. It was written as a Swift Testing suite first and could never run once.
`Sources/contacts-live-check` gets the embedded Info.plist and `scripts/live-check.sh`
re-signs it, which is the only reason a prompt appears at all. Do not move it back into
the test target.

**Fixtures still come first.** `FakeContactStore` drives the entire tool layer with
invented names and numbers, and that is where a change is proven. The live check is for
what the fake genuinely cannot reach — `SystemContactStore` talking to Apple, and
`ContactsAppScripting` talking to Contacts.app — not for re-proving logic that already has
a fake-driven test.

Allowed without asking:

| Action | Why it is safe |
|---|---|
| `swift build`, `swift test` | Tests run against the in-memory fake |
| `scripts/live-check.sh` | Creates its own `ZZTest` records and deletes them; changes no other record |
| Reading contacts, Lists and accounts | Reading is the job; only changes need approval |
| `initialize`, `tools/list` over stdio | Protocol only; no store is opened |
| `otool -P` on the built binary | Inspects the embedded Info.plist |

End-to-end verification through a real MCP client remains the **owner's** job, by hand,
with MCP Inspector: `verification.md` is the script for it. The live check proves
the framework layer works; it does not prove the packaged extension is installed,
signed and permitted, which is what that script is for.

## Language

**Everything in this repository is written in English** — code, comments, tool
descriptions, error messages, documentation and commit messages. The one exception is
literal macOS UI strings quoted inside permission instructions, which must match what
is on screen (for example the System Settings pane name in the user's locale).

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Contacts app through
`Contacts.framework`. It reads and writes the address book on this Mac. There is no
network, no credential and no cloud API: iCloud is only the sync engine that fills the
local store, and the gate is TCC consent rather than authentication.

## Commands

```bash
swift build                      # debug
swift build -c release           # what Claude Desktop should run
swift test                       # 79 tests, all against the fake store
```

Protocol smoke test without touching any contact. Note the trailing delay: the server
exits on stdin EOF, and without it the process can terminate before flushing replies.

```bash
{ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; perl -e 'select undef,undef,undef,3'; } | ./.build/release/apple-contacts-mcp
```

Confirm the Info.plist survived linking — if either line is missing, TCC denies that
permission without ever showing a prompt:

```bash
otool -P .build/release/apple-contacts-mcp | grep -E 'NSContactsUsageDescription|NSAppleEventsUsageDescription'
```

## Architecture

`Sources/ContactsMCPCore` holds everything; `Sources/apple-contacts-mcp/main.swift` is
a launcher that exists only because a Swift executable target cannot be imported by a
test target.

**`ContactStore` is the seam.** `ContactTools` (dispatch), `Format` (output) and
`Arguments` (decoding) never touch `Contacts.framework` — they go through the protocol.
That is what lets the whole tool layer be tested against `FakeContactStore` with no
permissions and no address book, and it is a direct consequence of the hard rule above.
Only `SystemContactStore` talks to Apple, and it is deliberately the thinnest file that
can do the job, because it is the one part no test can reach.

**`ContactsAppScripting` is the second thing below the seam** — named for what it is
rather than for the note, because it now carries two things Contacts.framework cannot
do from here: the note field, and removing a contact from a group. It is the only part
of this
server that is not `Contacts.framework` at all. It drives Contacts.app over Apple events
because the note field cannot be reached any other way (see TCC notes). It is used only
by `SystemContactStore`; nothing above the seam knows it exists. One piece of it *is*
testable and must stay that way: `AppleScriptString.literal`, which escapes note text
before it is placed into script source. An unescaped quote there is a script-injection
bug in a file no other test covers.

**`ToolCatalog` is the authorisation surface.** A tool absent from `ToolCatalog.all`
cannot be called. The name it is listed under is the label on the permission switch in
Claude Desktop, so renaming a tool silently revokes whatever the owner had toggled.

## Invariants worth protecting

- **Reads carry no verb prefix; writes always start with `create_`/`update_`/
  `delete_`.** Claude Desktop sorts the switches alphabetically, so this groups the
  destructive tools together. A test enforces the convention.
- **Annotations must stay honest.** A client treats an unannotated tool as
  write-capable and destructive. `readOnlyHint` on a tool that writes would be a lie the
  client acts on.
- **`delete_contact` requires `confirm: true` and returns a recreate call.** Contacts
  has no undo and keeps no copy; the response is the only record that the contact
  existed.
- **The absent/empty distinction in `update_contact`.** Omitting a field leaves it
  alone; passing `""` for a text field or `[]` for a list clears it. Collapsing the two
  would make removing a job title impossible to express. `FieldEdit` exists solely for
  this. An explicit `null` still clears, and a test pins that, but it is no longer what
  the schema advertises — see below.
- **No property may declare a union `type`.** Claude Desktop's schema sanitiser drops a
  property whose `type` is `["string", "null"]` or `["array", "null"]` and hands the
  model a bare `{}` in its place; `anyOf` inside `items` is flattened the same way.
  Observed live: `update_contact` reached the model with every nullable field emptied to
  `{}`, so an array argument was serialised to a string and `Arguments` rejected it with
  "an array was expected". Text fields hid the fault because an untyped string still
  arrives as a string. `create_contact` was unaffected only because its lists never
  carried `null` in the union. Every schema therefore stays in the scalar-`type` subset,
  and a test walks the whole catalogue to enforce it. Anything `items` needs to say must
  also appear in the tool's own description, which does survive.
- **A truncated search must say what it withheld.** Silence reads as "that was
  everything". `contacts_all` carries the same duty, and more sharply: a page of the
  address book that does not name the total reads as the whole address book.
- **List membership must be compared like for like.** Contacts keeps no reverse index —
  `CNContact` has no `groups` property — so membership is derived by asking every group
  who belongs to it and inverting the answer. Both sides must be fetched *unified*;
  mixing unified and individual fetches makes the identifiers stop comparing equal and
  every membership silently disappears. `isUnifiedWithContactWithIdentifier:` is the
  documented fallback for when unification picked a different linked record as primary.
  Apple states the same hazard outright for
  `CNContainer.predicateForContainerOfContactWithIdentifier:`, which returns an empty
  array for a unified identifier.
- **Group membership names an INDIVIDUAL contact, never the unified one — and getting
  this wrong fails silently.** A membership row points at one of the linked records that
  a unified contact aggregates. Hand `CNSaveRequest` a unified contact and the two
  operations behave differently: `addMember` resolves it to a primary record and works,
  while `removeMember` looks for a row naming exactly that object, finds none, removes
  nothing, and **does not throw**. Observed live: a remove that reported "removed from
  ZZTest List" while three separate reads — including a `predicateForContactsInGroup`
  query — still showed the contact as a member. `changeMembership` therefore resolves
  the identifier to its individual records with `unifyResults = false` and operates on
  all of them, falling back to the unified contact only if that lookup is empty.
- **`CNSaveRequest` cannot save a contact that carries a note**, so those updates go
  through Contacts.app instead. Measured by controlled comparison, two contacts identical
  but for the note: with a note, 134092; without one, the same update succeeds. The stack
  is unambiguous — `_PF_FulfillDeferredFault` → `-[CNCDContact _newStringForIndexing]` →
  `-[CNCDContact willSave]`. Contacts rebuilds the search index on save and the index
  includes the note; `CNContactNoteKey` cannot be fetched by this binary at any price (see
  the TCC notes), so that one property is always an unresolvable fault. **Widening
  `mutationKeys` cannot fix it** — the key it would need is the one key that is
  unreachable — so do not try. `delete_contact` is unaffected: deletion does not reindex.
  `ContactsAppScripting.update` is the fallback, entered only after the framework has
  actually refused, because the framework path covers more fields and needs no Automation
  consent. Retrying there is safe: Core Data rejects during validation, before any change
  is pushed, so the failed save applied nothing.
- **The Contacts.app fallback is narrower than `CNContact`, and says so rather than
  half-writing.** `unsupportedFields(in:)` is checked *before* anything is applied, and
  names what it cannot do: `phonetic_organization_name` (no such property on `person`),
  `photo_path`, a birthday or custom date with **no year** (`birth date` is a date, while
  the framework allows the year to be absent), and an instant message whose service is
  **custom** — Contacts.app keys those off a fixed ten-value enum and its `service name`
  is read-only. Social profiles have no such limit: `service name` is writable text, so a
  custom service goes through either route. Clearing the note to get the framework path
  working was considered and rejected: it opens a window in which the owner's note exists
  nowhere.
- **A service name is localised on the way out and must be reversed on the way in**, the
  same hazard as `canonicalLabel` and missed for years because most services survive
  unchanged. `SinaWeibo` reads back as "Sina Weibo" and `GoogleTalk` as "Google Talk", so
  a read-modify-write stored a *custom* service that merely looked built-in — and value
  lists replace wholesale, so it eroded them. `canonicalService` reverses it per class.
  Anything matching no known service is passed through untouched, which is what makes a
  genuinely custom service ("GitHub", "Signal") work at all: both `CNSocialProfile.service`
  and `CNInstantMessageAddress.service` are free-form strings, not enumerations.
- **Group membership on a noted contact hits the same wall `update_contact` does, and
  for a long time had no fallback for it.** `willSave` reindexes the whole contact on
  *any* save that touches it — `addMember`/`removeMember` included, whether or not a
  field is changing — so a noted contact failed `update_contact_lists` with the bare
  134092 in both directions, with no attempt at the Contacts.app route `update` already
  had. Found in production: every `update_contact_lists` call failed in a real
  enrichment session because every contact touched had been given a note moments
  earlier by `create_contact`. `changeMembership` now captures a framework failure
  rather than throwing it immediately, and reaches the same Contacts.app fallback
  whether the save threw outright or (the separate defect below) silently did nothing.
- **`CNSaveRequest.removeMember` does not work on an iCloud group, and does not say so.**
  Measured directly on this system: the save is accepted, nothing throws, and the
  membership survives three separate reads — while Contacts.app removes the same person
  from the same group seconds later without complaint. `addMember` looked unaffected at
  the time, which is exactly what hid it: adding worked, so the pair looked healthy. Both
  directions now share one `ContactsAppScripting.changeMembership` fallback — framework
  first, so no Automation consent is needed where the framework works, Contacts.app only
  on proof that the record does not yet show what was asked for. Do not "simplify" that
  fallback away.
- **`create_contact` accepts `lists` and applies membership in the *same* `CNSaveRequest`
  as the creation, not as a follow-up `changeMembership` call.** This is not only
  convenience: a just-created `CNMutableContact` has no Core Data faults to resolve, so
  folding membership into the same save sidesteps the reindex failure above entirely — a
  brand-new contact can join a List even while it still carries a note. A bad list name
  is resolved and refused *before* anything is created, so a typo cannot leave an
  orphaned contact behind.
- **A response that omits an empty field must not be trusted to mean "not relevant" when
  the caller just asked for that field.** `detail`'s block renderer drops an empty
  `lists` row like any other absent field, which is correct for a read but was silently
  wrong for `create_contact`: a caller could not tell "born into no list" from "the
  `lists` argument was dropped", and the second of those was a real, undetected failure
  mode before `create_contact` accepted the argument at all. `Format.created` states
  `lists: (none — …)` explicitly rather than omitting the row.
- **`CNContactStore.authorizationStatus(for:)` was observed reporting `.notDetermined`
  after a real read and a real write had both already succeeded in the same process.**
  This server holds no cache of its own to explain that; whatever produces the staleness
  is inside Apple's TCC caching. `authorization()` now latches the first observed
  `.authorized` answer and never lets a later disagreeing read override it — a real
  reversal is not in the picture, since revoking access takes effect on this server's
  next launch, not mid-process (see the `.denied` message). The tradeoff is explicit in
  the code: a genuine mid-session revocation would keep reporting `.authorized` until an
  operation hits the OS's own permission error, which is judged better than sending
  someone to audit `codesign` for a signing problem that does not exist.
- **A value-list update reports the count before and after, for every touched field.**
  These fields replace wholesale — one `relations` entry silently discards the other
  three — and the response looked identical to an add until this was reported.
  `Format.updated` computes it from a `before`/`after` pair the store now returns
  (`ContactUpdateResult`), not from a second fetch: `update`'s own `existing` is
  snapshotted before mutation, at no extra Contacts.framework I/O.
- **A relation naming the contact itself is flagged, never refused.** This server cannot
  know who anyone really is — it can only compare one string to another — so a
  self-relation (seen in production, from duplicating a sibling's card) gets a note in
  the response, not a rejected write. Value lists replace wholesale, so an unflagged one
  would otherwise survive indefinitely.
- **`execute(saveRequest)` not throwing is not proof the change happened.** A save that
  succeeds having done nothing is the worst failure available here, because the caller is
  told it landed and only discovers otherwise by reading the record back. That is exactly
  how the defect above survived. `changeMembership` re-reads membership from the group
  and compares it against what was asked for, and reports a failure when they disagree.
  Any future write that can no-op must do the same.
- **The note is written before anything else in an update.** It is the one field that
  goes through another process, so it is the one that can fail on its own. Doing it first
  means a failure leaves the record exactly as it was and the error is the whole truth;
  doing it last would mean reporting success for a change that half happened.
- **An AppleScript write must end with `save`.** Contacts.app buffers the change in its
  own document, and a script that stops without saving loses it with no error to say so.
- **Writing a label reverses the localisation reading applied.** Reads turn
  `_$!<Home>!$_` into "home" — or "casa" on a Spanish Mac — so a caller that reads a
  contact and writes it back hands that string straight back. Storing it verbatim
  demotes a standard label to a custom one that merely looks the same, and since value
  lists replace wholesale, every read-modify-write would erode them.
- **stdout carries JSON-RPC and nothing else.** The StdioTransport logger defaults to a
  no-op handler; giving it a stdout logger would corrupt every response after the first
  log line.
- **Static properties of non-`Sendable` Apple types must be computed, not stored.**
  Swift 6 rejects a `static let [CNKeyDescriptor]` as shared mutable state.
- **A contact fetched to be mutated is fetched by its own identifier, not by a
  one-element predicate array.** `fetchContact` calls
  `unifiedContact(withIdentifier:keysToFetch:)`, never
  `unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers:))`. Apple's
  own header comment calls the predicate form the *batch* fetch; the singular form is
  the one built for "one identifier in, one contact out", with a documented failure
  (`CNErrorCodeRecordDoesNotExist`) when the id is unknown, which `fetchContact` maps
  back to `nil` the way every caller already expected. Observed live: `update_contact`
  and `update_contact_lists` failed on **every** call — any field, not only ones
  touching a note — with the identical unhelpful "Cocoa error 134092.", while
  `create_contact` (which never fetches anything) and a note-only update (which never
  reaches `CNSaveRequest` at all — see below) both worked. Both broken paths shared
  exactly one thing: a contact fetched through the predicate array and handed straight
  to `CNSaveRequest`. Switching the fetch is the fix; it is not merely a style
  preference for the singular case this server always has.
- **A `CNSaveRequest`/Contacts.framework failure is never reported as
  `error.localizedDescription` alone.** That string was observed to collapse two
  completely unrelated failures — the missing note entitlement, and, separately, every
  `update_contact` call — into the identical useless "The operation couldn't be
  completed. (Cocoa error 134092.)", naming no field and no cause. `SystemContactStore`
  has a `describe(_:)`/`diagnostic(for:)` pair that expands the full `NSError`:
  domain, code, `NSUnderlyingErrorKey`, and Contacts' own
  `CNErrorUserInfoKeyPathsKey`, `CNErrorUserInfoAffectedRecordsKey`,
  `CNErrorUserInfoAffectedRecordIdentifiersKey` and `CNErrorUserInfoValidationErrorsKey`
  — every catch block from `Contacts.framework` and from `ContactsAppScripting` must keep
  routing through it rather than reverting to the bare description.
- **`CNSaveRequest.update(_:)` applies one `CNMutableContact` as a single transaction:**
  every field on it commits together or none does. There is no per-field partial
  success to report *inside* one save. The one genuine partial-failure case in
  `update_contact` is the note, because it is written through a **separate** process
  (`ContactsAppScripting`, before the save) — `update`'s catch block names every field
  `changes` touched other than `note` as "not applied" and says explicitly when the
  note already went through before the save failed.
- **The photo-writes hardening switch is enforced in `Dispatch`, before the store is
  ever called — not inside `SystemContactStore`.** `disablePhotoWrites` has to be
  provable false-cost to a caller: the fake store used by every test above the seam
  never sees `photo_path` at all when it is refused, which is also what makes this the
  one behaviour in this list that CAN be pinned by a normal test rather than only by
  the owner's hand-run verification.

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce `dist/apple-contacts-mcp.mcpb`,
a zip with `manifest.json` at its root. `server.type` is `"binary"` — no Node, no Python,
just the Swift binary.

One thing in the manifest is load-bearing:

- **The `tools` array is what creates the per-tool switches.** Claude Desktop lists and
  toggles tools from the manifest, before the server has ever run. A tool missing from
  that array has no switch. Keep it in step with `ToolCatalog`.

The search-limit default that used to be a connector setting is now a constant in
`Configuration`, per the owner's plug-and-play rule, and the per-tool permission switch
is still the primary place a person changes this server's behaviour. `user_config` holds
exactly one deliberate exception: `disable_photo_writes`, a checkbox substituted into
`mcp_config.args` as `--disable-photo-writes`. It is a hardening switch, not a
preference — the same category as `apple-filesystem-mcp`'s `read_roots`/`write_roots` —
so it did not go the way of `search_limit`.

`pack.sh` checks everything here that fails silently otherwise: that **both** usage
descriptions survived linking and signing — checked by name, because a loose grep for
`UsageDescription` would pass on a plist carrying only the Contacts one and leave every
note unreadable with no dialog to explain it — that the signature is not `linker-signed`,
that a designated requirement exists at all, and that the executable bit survived the
zip. The MCPB
spec does not promise the installer preserves file modes; if a future Claude release
drops it, the symptom is a server that never starts and the fix is `chmod +x` on the
installed copy under `~/Library/Application Support/Claude/Claude Extensions/`.

## TCC notes

Claude Desktop spawns MCP servers through `Contents/Helpers/disclaimer`, which calls
`responsibility_spawnattrs_setdisclaim`. The child is therefore **its own TCC subject**
and cannot borrow the host app's usage descriptions — Claude.app declares none for
Contacts. Hence the embedded `Resources/Info.plist`.

**A linker-signed binary gets no TCC prompt at all.** `swift build` leaves exactly that,
and it produces no designated requirement, so nothing is ever logged and the status stays
"not determined". `pack.sh` re-signs and prints the requirement; if that line is empty the
build is broken in a way nothing else will show.
A stable self-signed certificate avoids it; that decision is the owner's.

**The note entitlement is unobtainable for this binary, permanently.** Reading or writing
`CNContactNoteKey` needs `com.apple.developer.contacts.notes`, which is a *managed
capability*: a paid developer account, Apple's written approval, **and** a provisioning
profile. Apple DTS, answering this exact question for a SwiftPM command-line tool, states
that an executable has nowhere to put a profile for the trusted execution system to find,
so `codesign --sign -` can never satisfy it — and recommends scripting Contacts.app
instead, which owns the data and needs no entitlement to reach it. Do not spend time
trying to make the entitlement work; it is not a build problem.

So the note comes from Contacts.app over Apple events, via `ContactsAppScripting`. Three
consequences worth knowing before touching that file:

- **It is a second TCC gate,** under Privacy & Security → Automation rather than →
  Contacts, with its own `NSAppleEventsUsageDescription`. Everything except the note works
  without it, and every failure degrades to "the note could not be read" rather than
  failing the call.
- **The script goes to `osascript` on stdin, never in `arguments`.** A note passed on the
  command line is readable in `ps` by every process on the machine. It is a subprocess
  rather than in-process `NSAppleScript` so that a hung Contacts.app can be killed;
  a wedged call is the worst failure mode for a server speaking a synchronous protocol
  over stdio. TCC still attributes the events to this binary — a disclaimed process is
  responsible for itself and its children inherit it as their responsible process.
- **The note never enters a `CNSaveRequest`.** It used to, and Contacts refused the
  **entire save** without the entitlement: `create_contact(note:)` failed with a bare
  "Cocoa error 134092" that named no field, and no contact was created. Keeping the note
  out of the save request entirely is what makes that impossible rather than merely
  unlikely.

The hardened runtime blocks Apple events, so `Resources/entitlements.plist` carries
`com.apple.security.automation.apple-events` for `MCPB_HARDENED=1` builds. That one is
not restricted — no request to Apple, no profile.
