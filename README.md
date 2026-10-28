# PrismExtensionKit

The Swift package for writing [Prism](https://github.com/natsustan/prism)
extensions, and the protocol they speak.

Extensions run outside Prism and talk to it over stdio: one JSON message per
line. Prism draws every view; an extension only returns data. An extension can
be a script with no build step, or a Swift program built with this package,
which handles the protocol so you never touch the JSON.

Extensions are published from
[prism-extensions](https://github.com/natsustan/prism-extensions), which also
has the templates, examples, and the `check` script. This repository is a
read-only copy of `Packages/PrismExtensionKit` in the Prism repository, synced
on each release; open issues and pull requests there.

## Products

| Product | For |
| --- | --- |
| `PrismExtensionKit` | Your extension: conform one `@main` type to `PrismExtension`. |
| `PrismExtensionTesting` | Your extension's tests: `PrismTestHost` plays Prism in memory. |
| `PrismExtensionProtocol` | The message and manifest types, shared with Prism. |

```swift
.package(url: "https://github.com/natsustan/prism-extension-kit.git", from: "0.1.0")
```

## Writing an extension

```swift
import PrismExtensionKit

@main
struct Hello: PrismExtension {
    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
        let count = (await context.state("count")?.numberValue ?? 0) + 1
        await context.setState(.number(count), for: "count")
        return .keepOpen(message: "Hello #\(Int(count))")
    }
}
```

Each method answers one part of `manifest.json`: `run` for commands,
`list` / `detail` / `perform` for `list` commands, `status` for rows declared
with `"liveStatus": true`, `widget` for widgets, and `preferenceItems` for
`orderedList` preferences. `print` goes to stderr, which Prism keeps for
diagnostics. Keep anything that must last in Prism (`context.setState`);
Prism stops idle extensions. A write made after the request replied, or after
Prism canceled it, is ignored on both sides.

## Testing an extension

```swift
import PrismExtensionTesting
import Testing
@testable import Hello

@Test func counts() async throws {
    let prism = try await PrismTestHost(Hello(), preferences: ["excited": .bool(true)])
    #expect(try await prism.run("hello") == .keepOpen(message: "Hello #1"))
    #expect(await prism.state["count"] == .number(1))
}
```

`PrismTestHost` sends the same messages Prism does through the same runtime,
and records what the extension asked of Prism: `state`, `startedTasks`,
`changedLists`, and `logs`. `setPreferences` hands the running extension new
values the way Prism does when a preference changes.

## Protocol v1

| Direction | Method | Reply |
| --- | --- | --- |
| Prism → extension | `initialize` `{protocol, prismVersion, extensionID, preferences, state, dataDirectory}` | `{"updatesPreferences": true}`, or `{}` |
| Prism → extension | `preferences.update` `{preferences}` | none; only to an extension that replied `updatesPreferences` |
| Prism → extension | `command.run` `{commandID}` | `{"kind": "completed" \| "keepOpen" \| "failed", "message", "restoreFocus", "hud", "paste"}` |
| Prism → extension | `status.subscribe` `{commandID, session}` | `{}`, then `status.update` notifications |
| Prism → extension | `status.unsubscribe` `{session}` | none |
| Prism → extension | `widget.load` `{widgetID}` | the template's fields plus `"template"` |
| Prism → extension | `list.load` `{commandID, query, filter}` | `{"items": [...], "filtering", "searchPlaceholder", "filters", "emptyMessage", "showsDetail", "fetchedAt", "error"}` |
| Prism → extension | `detail.load` `{commandID, itemID}` | `{"markdown", "metadata": [{"label", "value"}]}` |
| Prism → extension | `action.perform` `{commandID, itemID, actionID}` | a command result, plus `"reload": true` to reload the list |
| Prism → extension | `preferences.items` `{preferenceID}` | `{"items": [{"id", "title", "icon", "badge", "isOn"}]}` for an `orderedList` preference |
| Prism → extension | `cancel` `{id}`, `willTerminate` | none |
| Extension → Prism | `status.update` `{session, status}` | none |
| Extension → Prism | `state.write` `{requestID, key, value}` | none; only while that request is in flight, within 1 MB per extension |
| Extension → Prism | `task.start` `{requestID, taskID, arguments}` | none; only tasks the manifest declares |
| Extension → Prism | `list.changed` `{commandID}` | none; an open list of that command reloads |
| Extension → Prism | `log` `{message}` | none |

A list item is `{"id", "title", "subtitle", "icon", "accessories", "keywords",
"section", "detail", "actions"}`; only `id` and `title` are required, and IDs
must stay the same across reloads. An action is `{"id", "title", "symbol",
"kind": "perform" | "copy" | "open" | "grantFolder", "text" | "url" | "folder",
"style": "destructive", "shortcut": "cmd+shift+c", "confirmationMessage"}`;
destructive actions, and any action with a `confirmationMessage`, ask before
they run. The first action runs on Return. An action with `"actions": [...]`
is a submenu, such as Copy… or Kill…: choosing it, by Return, its shortcut, or
in ⌘K, shows those actions in the ⌘K panel under its title, and Esc steps
back. Submenus nest one level; every action ID is unique across the item,
submenus included, and a submenu's actions answer to their shortcuts from the
list too. An older Prism shows a submenu as a plain action that performs its
own ID, so handle that ID or set `minPrism`.

An accessory is `{"text", "symbol", "tint", "help", "meter", "style"}`;
`"style": "tag"` draws the text in a capsule tinted like it, as a label or a
port number, and an older Prism draws it as plain tinted text. A row shows
its accessories in order and leaves out the last ones that don't fit beside
the title, so put the most telling one first and say the rest in `help` or
the detail. `query` is empty unless the list sets `"filtering": "extension"`;
`filter` is `null` until the user picks one of `filters` with ⌘P.

Gauges use a meter, `{"fraction": 0...1, "tone": "normal" | "warning" |
"critical", "resetsAt": <unix seconds>}`: on a list accessory it draws a ring,
on a detail row a bar with a live reset countdown, and on the quota widget
templates (`quotaRings`, `quotaNumbers`, `quotaBars`, `quotaRing`,
`quotaNumber`) a ring or bar. A detail can carry a header (`title`,
`subtitle`, `icon`, `updatedAt`), a `notice`, `markdown`, `sections` of rows
(`label`, `value`, `style: "badge"`, `meter`, `date`), and the pinned
`metadata` block. Dates are Unix seconds. An item with `"isLoading": true`
shows a spinner.

Some folders are protected by macOS, such as another app's library under
`~/Library/Group Containers`. Declare each one the extension reads in the
manifest, `"folders": [{"id", "path": "~/…" | "/…", "reason"}]`, and when a
read fails with a permission error, offer an item whose action is
`{"kind": "grantFolder", "folder": "<id>"}`. Prism opens a panel at that
folder with the `reason`; once the user chooses it, Prism and the extensions
it runs can read it, the extension restarts, and the list reloads. No Full
Disk Access is needed. A grant lapses when its folder moves or goes away,
or when a new version stops declaring it at the same path, so offer the
action again whenever the read fails.

A `no-view` command that works with the user outside Prism, such as a screen
color sampler, sets `"interactive": true`. Prism closes the launcher before it
runs, waits up to five minutes for the result instead of the usual 15
seconds, and shows a `keepOpen` or `failed` message in a HUD, or in the
launcher if the user has opened it again. Only a `no-view` command can be
interactive.

A `completed` result with a `message` and `"hud": true` (`.hud(message:)` in
Swift) closes the launcher, returns focus, and shows the message briefly in a
HUD near the bottom of the screen, for a result worth confirming once the
launcher is gone, such as “Copied #FF6363”. It works from root search, a
hotkey, a widget, and a list action; an empty message closes without a HUD,
and an older Prism closes without it.

A `completed` result with a `"paste": "<text>"` string (`.paste(text:)` in
Swift) closes the launcher and pastes the text into the app the launcher was
opened over, or, from a hotkey or an interactive command with the launcher
closed, into the frontmost app, as Clipboard History pastes. The text stays on
the clipboard. Pasting needs Prism to have Accessibility access; without it,
or when that app has gone, Prism copies the text and says so, so the text is
never lost. `paste` wins over `hud`, and works from root search, a hotkey, a
widget, and a list action. An older Prism closes without pasting, so an
extension whose main job is pasting sets `minPrism`.

A `list` command that searches an app can say which one with
`"searchesApp": "<bundle id>"` (`"com.apple.Notes"`, matched ignoring case).
When that app's row is selected in root search, it offers the command, and
Tab opens the list with the app named beside the search field, as Spotlight
searches inside an app; Backspace in the empty field returns to the app's
row. The command keeps its own row too.

A preference may name a `section`; settings shows each section as its own
group, in the order sections first appear, and puts the rest under
"Options". Preferences of type `secret` are kept in the Keychain and arrive in
`initialize` like the others. An `orderedList` value is the user's
arrangement as strings, one per item, with a leading `-` for an item that is
off (`["codex", "-grok"]`); items it does not mention keep their `isOn` from
`preferences.items`.

An icon is `{"symbol", "tint", "image", "app"}`: an SF Symbol on a tinted
tile; with `image`, a path inside the extension's folder to an SVG, PDF, or
PNG of at most 512 KB, drawn as a template in the surrounding color
(`"icons/mark.svg"`); or, with `app`, an installed app's bundle identifier
(`"com.apple.Notes"`), drawn as that app's own icon. `app` comes before
`image`. A path that leaves the folder or names another kind of file, or an
app that is not installed, falls back to the symbol. With `swatch`, an sRGB
color as `#RRGGBB` or `#RRGGBBAA`, a row that is a color draws that color as a
solid tile, ahead of `app` and `image` (`ExtensionIcon.swatch("#FF6363")` in
Swift). Only the extension's own views draw swatches; root search, an older
Prism, and a value it cannot read draw the rest of the icon instead.

`"style"` chooses how the symbol or image is drawn. `"tile"` puts it on the
tinted tile, as the launcher's command icons, so a brand mark can be the
extension's icon in root search and settings
(`{"symbol": "star", "tint": "graphite", "image": "icons/mark.svg", "style": "tile"}`).
`"glyph"` draws it alone in the tint, for list rows whose color says something,
such as a pull request's state; `"gray"` then follows the text's secondary
color. Without a style, a symbol sits on a tile and an image is drawn alone in
the surrounding color. Tints are `blue`, `teal`, `cyan`, `green`, `gold`,
`orange`, `red`, `pink`, `violet`, `indigo`, `brown`, `gray`, and `graphite`
(near-black, for brand marks).

Prism starts the extension on demand and ends it after a minute idle or when
its process tree uses more than 150 MB. When a preference changes, Prism sends
the running extension `preferences.update` with every value, then reloads its
open lists and visible widgets; the Swift runtime replies `updatesPreferences`
and hands later requests the new values in `context.preferences`, so read
preferences per request rather than once per process. It also sends a fresh
`status.update` for every subscribed row; an extension in another language
that replies `updatesPreferences` should do the same. An extension that does
not reply it is restarted instead. Keep
small values in Prism (`state.write`), not in the process: Prism refuses a
write that would take the extension's state past 1 MB of JSON (a `null`
value removes a key and is always accepted). The Swift runtime checks the
same limit (`ExtensionStateQuota`) before sending, so a refused
`context.setState` leaves `context.state` unchanged and logs why. For caches,
`initialize` names a `dataDirectory` the extension owns (`context.dataDirectory`
in Swift): Prism keeps one per extension and deletes it on uninstall.
