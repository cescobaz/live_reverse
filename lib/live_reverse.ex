defmodule LiveReverse do
  @moduledoc """
  Write LiveView code by feature instead of by callback.

  A LiveView groups its code by callback type: every `handle_params/3`
  clause together, then every `handle_info/2`, then every `handle_event/3`.
  LiveReverse turns that around. A feature lives in its own module that
  implements the callbacks it needs, and any LiveView plugs it in with
  `on_mount`. The same feature can be reused across LiveViews.

  A feature module implements the same callbacks a LiveView does, but each one
  returns `{:cont, socket}` to let the LiveView (and later hooks) run, or
  `{:halt, socket}` to stop there. Only the callbacks the module defines
  are attached, so a feature without `handle_params/3` can be mounted in
  a nested LiveView.

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

      # in the LiveView
      on_mount MyAppWeb.Cart

  Like a LiveView, every implemented `handle_*` callback needs a
  catch-all clause: it runs for every params change, message or event,
  not only the ones the feature cares about.

  `mount/4` gets the `on_mount` argument first (`:default` for a bare
  module) and runs before the hooks are attached, during both the static
  and the connected render. Use it for default assigns, session data and
  `connected?/1`-guarded subscriptions. A router-mounted LiveView already
  gets the initial params in `handle_params/3`; in a nested LiveView
  `params` is `:not_mounted_at_router`. Halting here needs a redirect,
  and then no hooks are attached.

  ## Mounting more than once

  A feature can be listed in several `on_mount` entries with different
  arguments; `mount/4` runs once per entry. What happens to the hooks
  depends on the `:attach` option given to `use`:

    * `:each` (default) - every entry attaches its own hooks, with
      `{module, arg}` as the hook id, so mounting the same module twice
      with the same argument raises. The callbacks don't get the
      argument, so every copy runs the same code.

    * `:once` - only the first entry attaches the hooks. `mount/4`
      should merge each argument into one config the module keeps
      itself, e.g. in `socket.private`, and the callbacks read it back
      from there.

  For example, a feature that assigns URL params, listed once per group
  of params:

      defmodule MyAppWeb.Params do
        use LiveReverse, attach: :once
        import Phoenix.LiveView, only: [put_private: 3]

        @impl true
        def mount(bindings, _params, _session, socket) do
          current = Map.get(socket.private, __MODULE__, [])
          {:cont, put_private(socket, __MODULE__, current ++ bindings)}
        end

        @impl true
        def handle_params(params, _uri, socket) do
          socket =
            Enum.reduce(socket.private[__MODULE__], socket, fn {key, param}, socket ->
              assign(socket, key, params[param])
            end)

          {:cont, socket}
        end
      end

      # in the LiveView: one handle_params hook, reading both groups
      on_mount {MyAppWeb.Params, garden_id: "garden_id"}
      on_mount {MyAppWeb.Params, search: "search"}

  ## Installing and detaching at runtime

  `install/4` does at runtime what an `on_mount` entry does at mount, for
  example from a `handle_event/3`; `detach/3` undoes it:

      {:cont, socket} = LiveReverse.install(socket, Chat, "chat:lobby")
      socket = LiveReverse.detach(socket, Chat, "chat:lobby")

  `detach/3` first calls the optional `unmount/2` callback, which undoes
  what `mount/4` did (unsubscribe, drop config) and answers whether the
  hooks should go: `{:detach, socket}` removes them, `{:keep, socket}`
  leaves them in place. With `attach: :once` that lets a module keep its
  hooks while other entries still use them:

      @impl true
      def unmount(topic, socket) do
        Phoenix.PubSub.unsubscribe(MyApp.PubSub, topic)
        topics = List.delete(socket.private[__MODULE__], topic)
        socket = put_private(socket, __MODULE__, topics)
        if topics == [], do: {:detach, socket}, else: {:keep, socket}
      end

  Without `unmount/2` the hooks are always removed. LiveView itself has no
  such callback: `terminate/2` only runs when the whole process stops.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, detach_hook: 3, put_private: 3]
  alias Phoenix.LiveView.Socket

  @type result :: {:cont, Socket.t()} | {:halt, Socket.t()}

  @callback mount(
              arg :: term,
              params :: map | :not_mounted_at_router | :installed,
              session :: map,
              Socket.t()
            ) :: result
  @callback unmount(arg :: term, Socket.t()) :: {:keep, Socket.t()} | {:detach, Socket.t()}
  @callback handle_params(params :: map, uri :: String.t(), Socket.t()) :: result
  @callback handle_info(msg :: term, Socket.t()) :: result
  @callback handle_event(event :: String.t(), payload :: map, Socket.t()) ::
              result | {:halt, reply :: map, Socket.t()}
  @callback handle_async(name :: term, result :: {:ok, term} | {:exit, term}, Socket.t()) ::
              result

  @optional_callbacks mount: 4,
                      unmount: 2,
                      handle_params: 3,
                      handle_info: 2,
                      handle_event: 3,
                      handle_async: 3

  @callbacks [handle_params: 3, handle_info: 2, handle_event: 3, handle_async: 3]
  @attach_modes [:once, :each]

  defmacro __using__(opts) do
    attach = Keyword.get(opts, :attach, :each)

    if attach not in @attach_modes do
      raise ArgumentError,
            "expected :attach to be one of #{inspect(@attach_modes)}, got: #{inspect(attach)}"
    end

    quote do
      @behaviour LiveReverse
      import Phoenix.Component, only: [assign: 2, assign: 3, assign_new: 3]
      @before_compile LiveReverse

      @doc false
      def __live_reverse_attach__, do: unquote(attach)
    end
  end

  defmacro __before_compile__(env) do
    stages = for {name, arity} <- @callbacks, Module.defines?(env.module, {name, arity}), do: name
    mount? = Module.defines?(env.module, {:mount, 4})
    unmount? = Module.defines?(env.module, {:unmount, 2})

    if stages == [] and not mount? do
      IO.warn("#{inspect(env.module)} uses LiveReverse but defines no callbacks", env)
    end

    mount =
      if mount? do
        quote do
          def __live_reverse_mount__(arg, params, session, socket),
            do: mount(arg, params, session, socket)
        end
      else
        quote do
          def __live_reverse_mount__(_arg, _params, _session, socket), do: {:cont, socket}
        end
      end

    unmount =
      if unmount? do
        quote do
          def __live_reverse_unmount__(arg, socket), do: unmount(arg, socket)
        end
      else
        quote do
          def __live_reverse_unmount__(_arg, socket), do: {:detach, socket}
        end
      end

    quote do
      @doc false
      def __live_reverse_stages__, do: unquote(stages)

      @doc false
      unquote(mount)

      @doc false
      unquote(unmount)

      def on_mount(arg, params, session, socket),
        do: LiveReverse.install(socket, __MODULE__, arg, params: params, session: session)
    end
  end

  @doc """
  Runs `module`'s `mount/4` with `arg` and, unless it halts, attaches its
  hooks, the same way an `on_mount {module, arg}` entry does.

  Called after mount, e.g. from `handle_event/3`, `mount/4` gets `:installed`
  as params and an empty session; pass `:params` or `:session` to override
  them. Hooks attached this way only see later events: `handle_params/3`
  runs on the next patch, not for the current URL.
  """
  def install(socket, module, arg \\ :default, opts \\ []) do
    params = Keyword.get(opts, :params, :installed)
    session = Keyword.get(opts, :session, %{})

    case module.__live_reverse_mount__(arg, params, session, socket) do
      {:cont, socket} -> {:cont, attach(socket, module, arg)}
      {:halt, socket} -> {:halt, socket}
    end
  end

  @doc """
  Undoes `install/4` (or an `on_mount` entry) for `module` and `arg`.

  Calls `module`'s `unmount/2`, then removes the hooks unless it returned
  `{:keep, socket}`. Detaching something that is not attached is a no-op.
  """
  def detach(socket, module, arg \\ :default) do
    case module.__live_reverse_unmount__(arg, socket) do
      {:detach, socket} ->
        detach_hooks(socket, module, arg)

      {:keep, socket} ->
        socket

      other ->
        raise ArgumentError,
              "expected #{inspect(module)}.unmount/2 to return {:keep, socket} or " <>
                "{:detach, socket}, got: #{inspect(other)}"
    end
  end

  defp attach(socket, module, arg) do
    case module.__live_reverse_attach__() do
      :each -> attach_stages(socket, module, {module, arg})
      :once -> attach_once(socket, module)
    end
  end

  defp attach_once(socket, module) do
    attached = Map.get(socket.private, :live_reverse, MapSet.new())

    if MapSet.member?(attached, module) do
      socket
    else
      socket
      |> put_private(:live_reverse, MapSet.put(attached, module))
      |> attach_stages(module, module)
    end
  end

  defp detach_hooks(socket, module, arg) do
    case module.__live_reverse_attach__() do
      :each ->
        detach_stages(socket, module, {module, arg})

      :once ->
        attached = Map.get(socket.private, :live_reverse, MapSet.new())

        socket
        |> put_private(:live_reverse, MapSet.delete(attached, module))
        |> detach_stages(module, module)
    end
  end

  defp attach_stages(socket, module, id),
    do: Enum.reduce(module.__live_reverse_stages__(), socket, &attach_stage(&2, module, id, &1))

  defp detach_stages(socket, module, id),
    do: Enum.reduce(module.__live_reverse_stages__(), socket, &detach_hook(&2, id, &1))

  defp attach_stage(socket, module, id, :handle_params),
    do: attach_hook(socket, id, :handle_params, &module.handle_params/3)

  defp attach_stage(socket, module, id, :handle_info),
    do: attach_hook(socket, id, :handle_info, &module.handle_info/2)

  defp attach_stage(socket, module, id, :handle_event),
    do: attach_hook(socket, id, :handle_event, &module.handle_event/3)

  defp attach_stage(socket, module, id, :handle_async),
    do: attach_hook(socket, id, :handle_async, &module.handle_async/3)
end
