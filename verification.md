# Manual verification

Everything below runs against **your real address book** and proves what the automated
checks cannot: that the *packaged extension* is installed, signed and permitted. Work
through it yourself, in order — each step assumes the previous one passed.

Use MCP Inspector, or Claude Desktop with only the tool under test enabled.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-contacts-mcp
```

**Run the automated live check first.** It covers the framework layer — every writable
field one at a time, the photo, and List membership — against records it creates and
deletes itself, so anything it catches is not worth finding by hand:

```bash
scripts/live-check.sh
```

That script is also the only thing an agent may point at a live address book, and only
because it builds its own subjects. See the hard rule in `CLAUDE.md`.

## 0 — Before you start

Create two throwaway things by hand in Contacts.app, and nothing in this script should
touch anything else:

- a contact: given name `ZZTest`, family name `Verification`, one phone, one email;
- a List called `ZZTest List`, empty.

Steps 4–9 operate on them, and steps 9 and 10 clean them up.

> **Known failure to expect at step 5.** `update_contact` fails with Cocoa error 134092
> on any contact that carries a **note** — the search index Contacts rebuilds on save
> reads the note, and `CNContactNoteKey` is unfetchable by this binary. So do step 5's
> note tests *last*: once `ZZTest Verification` has a note, every later `update_contact`
> against it will fail until that defect is fixed. Contacts without notes are unaffected,
> and so are `create_contact`, `delete_contact` and `update_contact_lists`.

## 1 — Permission plumbing

There are two permissions, in two different panes. Contacts covers everything; Automation
covers the note field and nothing else.

| Step | Call | Expected |
|---|---|---|
| 1.1 | `contacts_status` | Before granting: `not requested yet` or `DENIED`, with the System Settings path. The Automation line reports separately. |
| 1.2 | `contacts_search {"query":"ZZTest"}` | The consent dialog appears, quoting `NSContactsUsageDescription` from `Info.plist`. |
| 1.3 | Approve, then `contacts_status` | `GRANTED`, and `binary` is the path you registered. |

If no dialog ever appears, an embedded usage description is missing:

```bash
otool -P .build/release/apple-contacts-mcp | grep -E 'NSContactsUsageDescription|NSAppleEventsUsageDescription'
```

Both must print. The second one governs notes; without it macOS denies the automation
with no dialog at all.

## 2 — Search shape

| Step | Call | Expected |
|---|---|---|
| 2.1 | `contacts_search {"query":"ZZTest"}` | One line, ending in `id=<uuid>:ABPerson`. |
| 2.2 | `contacts_search {"query":"zztest"}` | Same hit — matching is case-insensitive. |
| 2.3 | Search a company name you know | Hits found via the scan fallback, since Contacts has no organization predicate. |
| 2.4 | Search a term with many matches, `"limit":2` | Two lines plus `…N more · call again with offset=2`. |
| 2.5 | Repeat 2.4 with `"offset":2` | The next two, no repeats. |
| 2.6 | `contacts_search {"query":"qqzzxx"}` | `No contacts match 'qqzzxx'.` |

## 3 — Enumeration and Lists

| Step | Call | Expected |
|---|---|---|
| 3.1 | `contacts_all {"limit":5}` | Five lines, headed by the **total** number of contacts, then `…N more`. |
| 3.2 | `contacts_all {"limit":5,"compact":true}` | Names and ids only — no phone, email or company column. |
| 3.3 | `contacts_lists` | Every List you have, each with a member count and the account in brackets, then an Accounts block with one marked `(new contacts go here)`. |
| 3.4 | Compare 3.3 to the sidebar in Contacts.app | Same lists, same counts. A missing list means the container walk did not reach it. |
| 3.5 | `contacts_all {"list":"ZZTest List"}` | `No contacts are in 'ZZTest List'.` |
| 3.6 | `contacts_all {"list":"Nonexistent"}` | Error naming `contacts_lists`. |
| 3.7 | `contacts_all {"list":"<a real list>"}` | Exactly the people that list holds. |

Step 3.4 is the one worth being fussy about. Membership is derived by asking each list who
belongs to it, and a mismatch in fetch mode makes memberships vanish silently rather than
fail.

## 4 — Detail

| Step | Call | Expected |
|---|---|---|
| 4.1 | `contacts_get` with the id from 2.1 | Labelled block; labels localised (`home`, `work`), not raw `_$!<Home>!$_`. |
| 4.2 | `contacts_get {"id":"made-up"}` | Error explaining ids go stale and to search again. |
| 4.3 | `contacts_get` on a contact with a birthday | Rendered `14 Mar 1990`; no invented year if the record has none. |
| 4.4 | `contacts_get` on a contact in a List | A `lists` row naming it. |
| 4.5 | `contacts_get` on a contact with a photo | `photo yes · thumbnail N KB`, and no image blob in the text. |
| 4.6 | Same, with `"include_photo":true` | The photo comes back as an image. |
| 4.7 | `contacts_get` on a company record | A `type organization` row. Person records must **not** show one. |

## 5 — The note, and the second permission

This is the part no automated test can reach.

| Step | Call | Expected |
|---|---|---|
| 5.1 | Add a note to `ZZTest` by hand in Contacts.app | — |
| 5.2 | `contacts_get {"id":"<ZZTest>"}` | The Automation consent dialog appears, quoting `NSAppleEventsUsageDescription`. |
| 5.3 | Approve it | The note appears in the output. |
| 5.4 | `contacts_status` | `Contacts.app automation granted`. |
| 5.5 | `update_contact {"id":"<ZZTest>","note":"line one\nline \"two\""}` | Saved. Check in Contacts.app that the quotes and the line break survived exactly. |
| 5.6 | `update_contact {"id":"<ZZTest>","note":""}` | Note cleared. |
| 5.7 | Deny Automation in System Settings, restart, `contacts_get` | The **whole record still returns**, with a footnote explaining the missing permission. It must not fail the call. |
| 5.8 | With it still denied, `update_contact {"id":"<ZZTest>","note":"x"}` | Refused, and **nothing else changed** — the note is written first precisely so a failure leaves the record alone. |
| 5.9 | Re-grant Automation | — |

Step 5.5 is the escaping test. A note containing a quote is what a bad escaper turns into
executable script.

## 6 — Create

| Step | Call | Expected |
|---|---|---|
| 6.1 | `create_contact {"job_title":"Engineer"}` | Refused: needs a name, company, phone or email. |
| 6.2 | `create_contact {"given_name":"ZZTemp","phones":["+34600000123"]}` | Created; check Contacts.app shows it. |
| 6.3 | Same with `"phones":[{"value":"+34600000124","label":"home"}]` | Label lands on the number, and Contacts shows its **own** Home label, not a custom one spelled "home". |
| 6.4 | Compare the returned phone to what you sent | Contacts normalises formatting — the response is re-read from the store, so it shows the stored form. |
| 6.5 | `create_contact {"given_name":"ZZTemp2","note":"hello"}` | Contact created **with** the note. This used to lose the note and, before that, the whole contact. |
| 6.6 | `create_contact` with an address, a social profile, an instant message, a relation and a date | Every one of them appears in Contacts.app under the right heading. |
| 6.7 | `create_contact {"given_name":"ZZTemp3","photo_path":"/path/to/some.jpg"}` | The photo is set. |

Delete every `ZZTemp*` by hand afterwards.

## 7 — Update

| Step | Call | Expected |
|---|---|---|
| 7.1 | `update_contact {"id":"<ZZTest>"}` | Refused: no field named. |
| 7.2 | `update_contact {"id":"<ZZTest>","job_title":"Tester"}` | Updated; `Fields changed: job_title`. |
| 7.3 | `update_contact {"id":"<ZZTest>","job_title":""}` | Job title cleared. |
| 7.4 | `update_contact {"id":"<ZZTest>","nickname":"Zed"}` | Nickname set **and the phone is still there** — omitted fields untouched. |
| 7.5 | `update_contact {"id":"<ZZTest>","phones":["+34600000999"]}` | The old number is **gone**. Value lists replace wholesale. |
| 7.6 | `contacts_get`, then feed its `phones` straight back to `update_contact` | The labels are unchanged. A round-trip must not demote Contacts' own Home label to a custom one. |
| 7.7 | `update_contact {"id":"<ZZTest>","addresses":[]}` | Addresses emptied. |

Steps 7.5 and 7.6 are the ones that surprise people. Confirm both behave as documented.

## 8 — List membership

| Step | Call | Expected |
|---|---|---|
| 8.1 | `update_contact_lists {"id":"<ZZTest>"}` | Refused: nothing to add or remove. |
| 8.2 | `update_contact_lists {"id":"<ZZTest>","add":["ZZTest List"]}` | Added; the output shows the resulting membership and says the contact itself was not changed. |
| 8.3 | Check Contacts.app | `ZZTest` appears in `ZZTest List`. |
| 8.4 | `contacts_get {"id":"<ZZTest>"}` | A `lists` row naming `ZZTest List`. |
| 8.5 | `contacts_all {"list":"ZZTest List"}` | One contact. |
| 8.6 | `update_contact_lists {"id":"<ZZTest>","remove":["ZZTest List"]}` | Removed from the list, **and still present in Contacts.app**. |
| 8.7 | `update_contact_lists {"id":"<ZZTest>","add":["Nonexistent"]}` | Error naming `contacts_lists`. |

Step 8.6 is the one that matters: `CNSaveRequest.removeMember` reads like a deletion and
is not one.

## 9 — Delete

| Step | Call | Expected |
|---|---|---|
| 9.1 | `update_contact_lists {"id":"<ZZTest>","add":["ZZTest List"]}` | Put it back in the list first, so 9.3 has membership to report. |
| 9.2 | `delete_contact {"id":"<ZZTest>"}` | Refused; nothing removed. Confirm in Contacts.app. |
| 9.3 | `delete_contact {"id":"<ZZTest>","confirm":true}` | Deleted, with the full record, its lists, its note, and a `create_contact(...)` line followed by an `update_contact_lists(...)` line. |
| 9.4 | Paste that `create_contact` call back | The contact returns with the same fields. |
| 9.5 | Paste the `update_contact_lists` call, using the new id | Membership restored. |
| 9.6 | Delete it again to clean up, and delete `ZZTest List` by hand | — |

Step 9.4 is the real test of the recreate block: if it does not round-trip, the delete
output is not the audit record it claims to be. Step 9.5 exists because recreating a
contact does not restore its lists — a new record is a new record.

## 10 — Restart behaviour

| Step | Action | Expected |
|---|---|---|
| 10.1 | Quit and reopen Claude Desktop, call `contacts_status` | Still `GRANTED` for both — no second prompt. |
| 10.2 | `swift build -c release`, restart, call `contacts_status` | With ad-hoc signing, macOS prompts **again**: the cdhash changed. Confirms the signing note in the README. |

## Record the result

Note the date and the macOS version you verified on. A tool that passed six months ago
on a different OS release is not evidence about today.
