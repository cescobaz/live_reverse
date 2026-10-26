# Prior art

Research notes (2026-10-26) on whether something like LiveReverse
already exists in the Elixir/Phoenix ecosystem.

## The idea being compared

LiveReverse turns the LiveView programming model around. Instead of
one LiveView module that groups code by callback type (all `handle_params`
clauses, then all `handle_info` clauses, then all `handle_event` clauses),
code is grouped **by feature**: each feature is a module that implements the
LiveView callbacks it needs and is plugged into any LiveView with `on_mount`.

```elixir
defmodule MyAppWeb.Cart do
  use LiveReverse

  @impl true
  def mount(_arg, _params, _session, socket), do: {:cont, assign(socket, cart: nil)}

  @impl true
  def handle_info({:cart_updated, cart}, socket), do: {:halt, assign(socket, :cart, cart)}
  def handle_info(_msg, socket), do: {:cont, socket}
end

# in any LiveView
on_mount MyAppWeb.Cart
```

Key properties:

- A **behaviour** whose callbacks mirror the LiveView ones (`mount/4`,
  `handle_params/3`, `handle_info/2`, `handle_event/3`, `handle_async/3`),
  returning `{:cont, socket}` / `{:halt, socket}`.
- Only the callbacks a module defines are attached, decided at compile time.
  A feature module without `handle_params/3` therefore works in a nested LiveView.
- `use LiveReverse, attach: :once | :each` decides whether several
  `on_mount` entries of the same module share one set of hooks (`:once`, with
  the module merging its own config, see `GardenWeb.Hooks.Params`\*) or each
  attach their own (`:each`, hook id `{module, arg}`).

The closest mental model outside Elixir is a **React custom hook**
(`useSearch()`, `useParams()`): one feature, its own state and handlers,
plugged into the host. Rails' `ActiveSupport::Concern` is a similar idea on
the server side.

\* LiveReverse started as `GardenWeb.Reducer` in Garden, an experimental
Phoenix app. Names marked with \* (`GardenWeb.Hooks.Params`,
`Binding.Assigns`) are Garden modules built on it; they are not part of
this library.

## Summary

No published Hex library does what LiveReverse does: a behaviour with
LiveView-parity callbacks, one module per feature, mounted with `on_mount`
and attached once or per entry. LiveView ships the building blocks
(`on_mount` + `attach_hook/4`), and the community answer to "how do I share
logic between LiveViews" is to use them directly.

The closest prior art is a **pattern**, not a library: Curiosum's "hooked
function components", described below in detail.

| What | Kind | Similar | Different |
|---|---|---|---|
| Curiosum hooked widgets | pattern (blog post + ElixirConf EU 2026 talk) | One module per feature; `attach_hook` on event/info/params; hooks attached once for all instances; several instances per LiveView | No behaviour; started from `mount` instead of `on_mount`; ships its own render; instance routing through event payloads |
| Livex | library | Calls the `handle_*` stage the "reducer"; dependency-aware derived assigns (like Garden's `Binding.Assigns`\*) | Still one big LiveView module; no feature modules |
| Cartograph.LiveViewParams | library | Params to assigns through an `on_mount` hook (like Garden's `Hooks.Params`\*) | Params only; wired in with `use` inside the LiveView |
| LiveEvent | library | Adds lifecycle hooks through `use` | Only messaging between LiveViews and components |
| LiveViewEvents | library | — | Only messaging between components |
| LifeCycleHook | library | Hooks every lifecycle stage | Only logs the lifecycle; a teaching tool |

## Curiosum: hooked function components

- **Article:** "Hooking up with LiveView: stateful widgets with function
  components", Jakub Lambrych, Curiosum blog, 16 April 2026.
- **Talk:** "Hooked on Widgets: A Better Pattern for Reusable LiveView
  Components", Jakub Lambrych, ElixirConf EU 2026. No slides, video or code
  repository were linked at the time of writing.
- **Status:** a pattern explained with a chat widget example. Not published
  as a library.

### The problem it solves

The goal is reusable, self-contained, stateful **widgets** (a chat window, a
notification pane, a booking calendar) that keep their own state, handle
their own events, react to PubSub messages, read URL params, need no wiring
in the parent, and can appear several times on the same page.

The article argues that the two built-in options each miss something:

- **LiveComponents** have no `handle_info` (the parent must subscribe and
  forward with `send_update/3`) and no `handle_params` (the parent must
  forward URL state). Their state is also kept apart from `socket.assigns`,
  which makes debugging harder.
- **Embedded LiveViews** (`live_render/3`) can receive messages, but run in
  their own process, cannot see the parent's URL params, only get string
  session data, and talk to each other through PIDs. The author mentions
  inheriting a page with five embedded LiveViews coordinated this way, which
  motivated the pattern.

### The pattern

One widget module bundles three things, with the parent LiveView's socket as
the single source of truth:

1. **State:** a `%Widget{}` struct stored directly in `socket.assigns` under
   a key the parent chooses.
2. **Hooks:** shared `attach_hook/4` callbacks on `:handle_event`,
   `:handle_info` and `:handle_params` that run before the LiveView's own.
3. **Render:** a pure function component that turns the struct into HTML.

Its public surface is two functions: `assign_component/3` (called by the
parent in `mount/3`: builds the struct, subscribes to PubSub, attaches the
hooks) and `render/1`. The hook functions (`hooked_event/3`,
`hooked_info/2`, `hooked_params/3`) are private to the module.

```elixir
# parent LiveView
def mount(_params, _session, socket) do
  {:ok, ChatWidget.assign_component(socket, :chat, topic: "chat:global")}
end

# parent template
<ChatWidget.render state={@chat} />
```

### Multiple instances

This is where it goes further than the first versions of LiveReverse.

- **Attach once:** every `assign_component/3` call goes through a helper
  that attaches the three hooks only when the widget struct it just
  assigned is the **only** one in `socket.assigns` (it counts the
  `%ChatWidget{}` values). Further instances reuse the same hooks. Hook ids
  are namespaced strings such as `"chat_widget:event"`.
- **Detach last:** `detach_component/2` detaches the hooks when the last
  instance is removed. It does so before clearing the assign, so the count
  still sees that instance.
- **Routing events to an instance:** each event carries its instance key.
  The widget's form has a hidden input (`chat-widget-key`, or a `phx-value-*`
  attribute), and the event hook turns it back into an atom with
  `String.to_existing_atom/1` and looks up the struct under that key. Event
  names are namespaced (`"chat-widget:send"`) so they don't collide with the
  parent's.
- **Messages and params fan out:** `hooked_info/2` and `hooked_params/3`
  loop over every `%ChatWidget{}` in the assigns and update those it applies
  to, for example only the instances whose topic matches the message.

This is the same problem LiveReverse solves with `attach: :once` plus
`Hooks.Params` merging its own config: one set of hooks, with each instance
described by data the hook can find in the socket. Curiosum keeps one struct
per instance under its own assign key; `Hooks.Params` merges every entry
into one config in `socket.private`.

### Halt vs. cont

- `hooked_event/3` returns `{:halt, socket}` for the widget's own events, so
  the parent never sees them, and `{:cont, socket}` for everything else
  through a catch-all clause.
- `hooked_info/2` and `hooked_params/3` always return `{:cont, socket}`.
  Process messages and URL changes may matter to other widgets or to the
  parent, so they should never be swallowed.

LiveReverse leaves this choice to each callback, but this rule is a good
default to state in its docs.

### Streams caveat

The first version copied the LiveView stream into the widget struct. That
copy is never pruned after render, so stream items stay in memory. Pruning
it in an `:after_render` hook was rejected because it would run on every
render. The fix was to pass the stream as a separate attribute:

```heex
<ChatWidget.render state={@chat} message_stream={@streams.chat} />
```

The cost is that the parent template now references `@streams.chat`
directly. A feature module that owns a stream has the same issue.

### Debugging and testing

- Widget state is a plain struct in `socket.assigns`, so `dbg/1`, IEx and
  LiveDebugger show it directly.
- Tests are plain LiveView tests: mount a LiveView that uses the widget, then
  drive it with `render_click/2` and `render_submit/2`. For PubSub, broadcast
  inside the test; the hook handles it as in production.

### Trade-offs the article lists

- Hooks loop over all assigns (to count instances, and to fan out messages
  and params). The cost is linear, and negligible on typical pages.
- Nothing stops a hook from changing assigns of the parent or other widgets.
  Keeping hooks to their own instances is up to the author.
- Event names must be namespaced by hand.
- The streams issue above.

### Curiosum vs. LiveReverse

| | Curiosum hooked widgets | LiveReverse |
|---|---|---|
| Unit of reuse | widget module (state + hooks + render) | feature module (hooks only, no render) |
| Contract | convention (`hooked_*` function names) | behaviour with `@impl` checks, LiveView-parity names |
| Mounted by | parent's `mount/3` calls `assign_component/3` | `on_mount Module` / `on_mount {Module, arg}` |
| Which hooks attach | all three, always | only the callbacks the module defines, picked at compile time |
| Config | keyword opts at runtime, stored in the struct | `on_mount` arg (compile time), merged by the module, or a generated module per config |
| Several instances | one shared set of hooks, attached once by counting structs; instance key in each event | `attach: :once` (one set of hooks, merged config) or `attach: :each` (hooks per arg; callbacks can't tell instances apart) |
| Detach | yes, when the last instance goes (counted by the widget) | yes, `detach/3`; the module's `unmount/2` decides whether the hooks go (`{:keep, _}` / `{:detach, _}`) |
| Where state lives | struct in `socket.assigns` | wherever the module puts it (assigns, `socket.private`) |
| Nested LiveView | attaches `:handle_params` always, so it would fail there (our reading of `attach_hook/4`; the article doesn't cover it) | works when the module has no `handle_params/3` |

Ideas worth borrowing:

- **Instance key in event payloads:** a way to make `attach: :each` useful
  without changing the callback signatures. The event itself says which
  instance it is for.
- **Halt only your own events, always continue messages and params:** a
  default to document.
- **Detaching:** for features added or removed after mount (now `install/4` and `detach/3`).
- **Streams:** don't keep a copy of a stream in a feature's state.

## Other libraries

### Livex

Declarative state on top of LiveView: `state :name, :type, url?: true`
persists state to the query string, values are cast to the declared type,
and `assign_new/4` / `stream_new/4` recompute only when their dependencies
change. `mount/3` and `handle_params/3` are largely replaced by a
`pre_render/1` callback; the flow is render → event → reducer
(`handle_event`, `handle_info`, `handle_async`) → `pre_render` → render.
It improves the single LiveView module rather than splitting it into
features.

### Cartograph.LiveViewParams

A `use` macro that parses URL params into assigns through an `on_mount`
hook and can add a default `handle_params/3`. It must be `use`d after
`use Phoenix.LiveView`. Similar to Garden's `GardenWeb.Hooks.Params`\*, but limited to
params.

### LiveEvent and LiveViewEvents

Both cover messaging between LiveViews and LiveComponents. LiveEvent replaces
`send/2`, `send_update/2`, `handle_info/2` and `update/2` with `emit/3` and
`handle_event/4`, adding lifecycle hooks with `use LiveEvent.LiveView` or
`use LiveEvent.LiveComponent`.

### LifeCycleHook

A small library that logs each lifecycle stage of a LiveView, wired in with
`use`. Useful for learning, not for composing features.

### phoenix_live_view_ext

Describes itself as "functional extensions" for LiveView. Its recent activity
could not be confirmed.

## What the community recommends

When someone asks how to share logic between LiveViews, the answer is
consistently "use `on_mount`, optionally through `live_session`" (Elixir
Forum, "LiveView 'plug' for shared logic?", November 2025). Nobody in that
thread pointed to a library, and no core team member replied. The LiveView
docs describe `attach_hook/4` as the way to "inject common functionality",
and warn that a hook needs a catch-all clause because it runs for every
event and message.

## Takeaway

LiveReverse fills a real gap. Its distinctive parts compared with what
exists:

1. A behaviour with LiveView-parity callbacks and compile-time checks.
2. Attaching only the callbacks a module defines.
3. An explicit `attach: :once | :each` choice, with the module owning its
   config merge.
4. Generated modules for config that holds closures (Garden's `Binding.Assigns`\*).

The Curiosum pattern is the best reference for the open question of running
several independent instances of one feature module.

## Sources

- [Phoenix.LiveView docs (attach_hook, on_mount)](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html)
- [Curiosum: Hooking up with LiveView: stateful widgets with function components](https://curiosum.com/blog/hooking-up-with-liveview-stateful-widgets-with-function-components)
- [ElixirConf EU 2026: Hooked on Widgets](https://www.elixirconf.eu/talks/hooked-on-widgets-a-better-pattern-for-reusable-liveview-components/)
- [Livex.LivexView](https://livex.hexdocs.pm/Livex.LivexView.html)
- [Cartograph.LiveViewParams](https://cartograph.hexdocs.pm/Cartograph.LiveViewParams.html)
- [LiveEvent](https://readme.hex.pm/live_event/0.1.0)
- [LiveViewEvents](https://hexdocs.pm/live_view_events/readme.html)
- [LifeCycleHook (Elixir Forum)](https://elixirforum.com/t/lifecyclehook-a-hook-that-logging-life-cycle-of-phoenix-liveview/46008)
- [phoenix_live_view_ext on Hex](https://hex.pm/packages/phoenix_live_view_ext)
- [Elixir Forum: LiveView "plug" for shared logic?](https://forum.elixirforum.com/t/liveview-plug-for-shared-logic/73170)
- [Elixir Streams: LiveView's lifecycle hooks](https://www.elixirstreams.com/tips/liveview-lifecycle-hooks)
- [Fly.io: Live sessions in action](https://fly.io/phoenix-files/live-session/)
