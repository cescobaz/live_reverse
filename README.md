# LiveReverse

Write Phoenix LiveView code **by feature** instead of by callback.

A LiveView groups its code by callback type: every `handle_params/3` clause
together, then every `handle_info/2`, then every `handle_event/3`. A feature
such as "search", "pagination" or "live cart updates" ends up spread across
all of them, and reusing it in another LiveView means copying clauses.

LiveReverse turns that around. Each feature is a module that implements the
LiveView callbacks it needs, and any LiveView plugs it in with `on_mount`:

```elixir
defmodule MyAppWeb.Cart do
  use LiveReverse

  @impl true
  def mount(_arg, _params, _session, socket),
    do: {:cont, assign(socket, cart_id: nil, cart: nil)}

  @impl true
  def handle_params(%{"cart_id" => id}, _uri, socket),
    do: {:cont, assign(socket, :cart_id, id)}

  def handle_params(_params, _uri, socket), do: {:cont, socket}

  @impl true
  def handle_info({:cart_updated, cart}, socket),
    do: {:halt, assign(socket, :cart, cart)}

  def handle_info(_msg, socket), do: {:cont, socket}
end

defmodule MyAppWeb.ShopLive do
  use MyAppWeb, :live_view

  on_mount MyAppWeb.Cart
  # ...
end
```

If you know React, a feature module plays the role of a custom hook.

## Features

- **LiveView-style callbacks:** `mount/4`, `handle_params/3`,
  `handle_info/2`, `handle_event/3` and `handle_async/3`, checked with
  `@impl`. Each returns `{:cont, socket}` to let the LiveView (and the next
  hooks) run, or `{:halt, socket}` to stop there.
- **Only what you define is attached.** The callbacks a module implements
  are picked at compile time. A module without `handle_params/3` works in a
  nested LiveView.
- **Mount more than once:** with `use LiveReverse, attach: :each` (the
  default) every `on_mount {Module, arg}` entry gets its own hooks; with
  `attach: :once` the entries share one set of hooks and the module merges
  their config.
- **Install and detach at runtime:** `LiveReverse.install/4` adds a feature
  after mount, for example from a `handle_event/3`, and
  `LiveReverse.detach/3` removes it again, calling the optional `unmount/2`
  callback for cleanup.

Like a LiveView's own callbacks, every `handle_*` callback needs a catch-all
clause: it runs for every params change, message and event, not only the
ones the feature cares about.

See the `LiveReverse` module docs for the details.

## Installation

Add `live_reverse` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:live_reverse, "~> 0.1.0"}
  ]
end
```

LiveReverse requires Phoenix LiveView 1.0 or later.

## Prior art

LiveReverse is built on LiveView's own `on_mount` and `attach_hook/4`. See
[PRIOR_ART.md](PRIOR_ART.md) for a comparison with similar libraries and
patterns.

## License

MIT, see the `LICENSE` file.
