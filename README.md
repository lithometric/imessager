<p align="center"><img src="Support/Brand/AppIcon-1024.png" width="128" alt="imessager"></p>

# iMessager

A native macOS app that answers your iMessages with an OpenRouter model. You switch it on per contact; everyone starts off.

- **Per-contact switch, off by default.** Flip auto-reply on for the conversations you choose, with optional instructions for each ("my sister, keep it playful").
- **Reads Messages' own `chat.db`.** No second database and no message cache. Every read is a live, read-only query against `~/Library/Messages/chat.db`.
- **New-contact greeter.** When a number that isn't in your Contacts texts you and says who they are ("hey it's Sarah from the gym"), it replies ("Great to meet you, Sarah!"). It can also save them to Contacts and switch auto-reply on for them. Spam and texts without a name are ignored.
- **Integrations for context.** About Me, Calendar, Contacts lookup, a notes folder, any webhook/API, any MCP server, and web search.
- **Fast harness.** See [How it stays fast](#how-it-stays-fast).
- **Looks and works like Messages.** Conversations in the floating sidebar with your pins (groups too), contact and group photos, unread dots, and Messages' filters (Unread, Known/Unknown Senders, Group Chats). Delivered, Read, Sent as Text Message, Edited and unsent messages show under bubbles, and links are clickable with previews.
- **Undo send, Try Again, Send as Text Message, Delete.** Messages has no scripting for unsend or delete, so iMessager holds each text for a few seconds (Settings › Behavior) before handing it to Messages; Undo pulls it back. Delete removes a message from iMessager and from what the AI sees; it stays in Messages on your devices. Failed texts get the red "!" with Try Again and Send as Text Message.
- **Notifications and ads stay out of the way.** Payment alerts, login codes, deliveries and "reply STOP" marketing are sorted into Transactions and Promotions automatically. Right-click a chat to move it.
- **Use your Claude plan.** Settings › AI › Claude plan runs your own Claude Code (`claude -p`) for each reply, the way Anthropic supports subscription use. iMessager never sees your Claude login, and each call runs with Claude Code's tools, MCP servers, hooks and settings switched off, in an empty folder, so a text can't make it touch your Mac. (Tools such as calendar search need OpenRouter.)
- **New Message (⌘N).** Search your Contacts or type a number or email; if you already have a conversation with them it opens.
- **Photos, videos and files.** Send them from Photos, Finder, paste (⌘V) or drag-and-drop; received ones show inline. Right-click to open, copy or show in Finder, or drag them out.
- **Unread summaries and notifications.** A one-line AI summary for conversations with several unread texts, and notifications when the AI replies, greets someone, or a text fails (with Try Again).
- **Home overview.** Delivery and read rates, sent and received volume, AI replies, response time, AI spend (from OpenRouter's per-call cost) and your OpenRouter credits.
- **Liquid Glass** on macOS 26 for the composer, search, toolbar, modals and stat tiles, with material fallbacks on macOS 14–15. Light, Dark or Automatic in Settings.

## Run it

Requires macOS 14+ and Xcode (or the Swift toolchain).

```bash
scripts/build-app.sh --run       # build build/iMessager.app and launch it
scripts/build-app.sh --install   # or copy it to /Applications and launch
```

Then, once. If anything is missing, the app opens a **setup checklist** on launch and shows a notification card. Both re-check live (every 2 s while something is blocked, and whenever you switch back to the app). They also say exactly why chat.db can't be read: blocked by macOS privacy, no database yet, or a database error. You can reopen the checklist from the toolbar's Setup button.

1. **Full Disk Access.** System Settings › Privacy & Security › Full Disk Access › **+** › iMessager. If it's already on but still blocked, remove it with − and add it again (macOS ties the switch to one build).
2. **OpenRouter key.** Settings › paste your key › Verify. The default model is `anthropic/claude-haiku-5.5` (fast); change it under Presets or Browse.
3. **Contacts and Messages control.** macOS asks the first time. Messages control is what lets it send.
4. **Turn on a contact.** Conversations › flip the switch. Use **Draft** in a conversation to see exactly what it would send without sending, or turn on **Dry run** in Settings.

The build script signs with your Apple Development identity when one is available, so macOS remembers these permissions across rebuilds.

## How it works

```
chat.db ──FSEvents──▶ Agent ──▶ debounce per chat ──▶ context (history + integrations, in parallel)
                                                    ──▶ OpenRouter (tool loop, ≤4 steps)
                                                    ──▶ Messages.app (compiled AppleScript)
```

- **New messages:** FSEvents fires on writes to `chat.db`/`chat.db-wal`, and a `ROWID > cursor` query reads only what's new. A 2-second heartbeat is the backstop. On launch the cursor starts at the newest message, so nothing from before launch gets answered.
- **Message text:** newer macOS stores text only in `attributedBody`; it's decoded from the typedstream directly.
- **Bursts:** a new text from the same person cancels an in-flight reply and restarts it, so the reply covers everything they said.
- **You take over:** if you text that person yourself (from the Mac or your phone), the pending AI reply is cancelled and the AI pauses for that chat (10 min by default).
- **Guardrails:** a per-chat hourly reply cap, `NO_REPLY` when nothing needs saying, the master switch (Agent menu, menu bar icon, Home), and dry-run mode.
- **Messaging tools for the AI**, scoped to the conversation it's answering: `message_status` (sent/delivered/read/failed), `send_message` (optionally as SMS), `retry_failed_message`, `undo_send` (while a text is still in the undo window) and `delete_message` (its own texts only). Draft previews never get the tools that send.

### How it stays fast

- Native Swift with SQLite prepared statements, using one primary-key range scan per change.
- The OpenRouter connection is pre-warmed, and requests ask for the lowest-latency provider.
- Small local context (About Me, today's calendar, small notes folders) goes straight into the prompt, which saves a tool round trip.
- Tool calls run in parallel.
- The send script is compiled once and called in-process, so no `osascript` is spawned.

## Integrations

| Integration | What the AI gets |
|---|---|
| About Me | Your notes, added to every prompt |
| Calendar | The next N days of events in the prompt, plus a `calendar_events` tool for other dates |
| Contacts | A `lookup_contact` tool: birthdays, companies, cities |
| Notes Folder | `.md`/`.txt` files: the whole folder if it's small, otherwise a search tool |
| Webhook / API | A tool that sends `{"query": …}` to your URL (Zapier, n8n, your server) |
| MCP Server | Every tool from any stdio MCP server, e.g. `npx -y @modelcontextprotocol/server-memory` |
| Web Search | A `web_search` tool through OpenRouter's web plugin |

Every conversation also gets `search_conversation_history`, which searches older messages in `chat.db`.

Tools run in response to what people text you, so only connect tools that are safe to run on behalf of the contacts you've switched on. The new-contact greeter gets no tools.

## Where things live

- Messages: `~/Library/Messages/chat.db`, read-only and never copied.
- Settings, deleted-message ids, your Transactions/Promotions corrections and the AI totals on Home: `~/Library/Application Support/iMessager/config.json`.
- Pins: read from Messages' own `~/Library/Preferences/com.apple.messages.pinning.plist`.
- OpenRouter key: Keychain.
- Activity log, the undo-send queue and unread summaries: memory only.
- Caches (contact names, avatars, photos being sent): `~/Library/Caches/com.lithometric.imessager/`.

## Layout

```
Sources/iMessager/
  Core/          ChatDB (chat.db reader), ChatWatcher (FSEvents), Agent (harness), OpenRouter,
                 MessageSender (AppleScript), Outbox (undo send / retry), Classifier (transactions, promotions),
                 Pins, ContactsIndex, Config, AppState
  Integrations/  IntegrationHub, local integrations, MCP client
  UI/            SwiftUI views
Support/         Info.plist, AppIcon.icns, Brand/ (logo sheet and generated assets)
scripts/         build-app.sh, make-brand.py (regenerates the icon and logo assets from the brand sheet)
```
