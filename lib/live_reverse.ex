defmodule LiveReverse do
  @moduledoc """
  Write LiveView code by feature instead of by callback.

  A LiveView groups its code by callback type: every `handle_params/3`
  clause together, then every `handle_info/2`, then every `handle_event/3`.
  LiveReverse turns that around. A feature lives in its own module that
  implements the callbacks it needs, and any LiveView plugs it in with
  `on_mount`. The same feature can be reused across LiveViews.

  A feature module implements the LiveView callbacks with one extra first
  argument, the `on_mount` argument (`:default` for a bare module). Each
  returns `{:cont, socket}` to let the LiveView (and later hooks) run, or
  `{:halt, socket}` to stop there. Only the callbacks the module defines
  are attached, so a feature without `handle_params/4` can be mounted in
  a nested LiveView.

      defmodule MyAppWeb.Chat do
        use LiveReverse
        import Phoenix.Component, only: [update: 3]
        import Phoenix.LiveView, only: [connected?: 1]

        @impl true
        def mount(topic, _params, _session, socket) do
          if connected?(socket), do: Phoenix.PubSub.subscribe(MyApp.PubSub, topic)
          {:cont, assign(socket, :messages, [])}
        end

        @impl true
        def handle_info(topic, {:message, topic, message}, socket),
          do: {:halt, update(socket, :messages, &[message | &1])}

        def handle_info(_topic, _msg, socket), do: {:cont, socket}
      end

      # in the LiveView
      on_mount {MyAppWeb.Chat, "chat:lobby"}

  Like a LiveView, every implemented `handle_*` callback needs a
  catch-all clause: it runs for every params change, message or event,
  not only the ones the feature cares about.

  `mount/4` runs before the hooks are attached, during both the static
  and the connected render. Use it for default assigns, session data and
  `connected?/1`-guarded subscriptions. A router-mounted LiveView already
  gets the initial params in `handle_params/4`; in a nested LiveView
  `params` is `:not_mounted_at_router`. Halting here needs a redirect,
  and then no hooks are attached.

  ## Mounting more than once

  A feature can be listed in several `on_mount` entries with different
  arguments; `mount/4` runs once per entry, with that entry's argument.
  What the `handle_*` callbacks get depends on the `:attach` option given
  to `use`:

    * `:each` (default) - every entry attaches its own hooks, with
      `{module, arg}` as the hook id, and each hook passes its own `arg`.
      Mounting the same module twice with the same argument raises.

    * `:once` - the entries share one set of hooks, and the callbacks get
      the list of every entry's argument, in mount order. `args/2`
      returns that list, e.g. for `mount/4` to check a new argument
      against the earlier ones.

  For example, a feature that assigns URL params, listed once per group
  of params:

      defmodule MyAppWeb.Params do
        use LiveReverse, attach: :once

        @impl true
        def handle_params(groups, params, _uri, socket) do
          socket =
            for bindings <- groups, {key, param} <- bindings, reduce: socket do
              socket -> assign(socket, key, params[param])
            end

          {:cont, socket}
        end
      end

      # in the LiveView: one handle_params hook, which gets
      # [[garden_id: "garden_id"], [search: "search"]]
      on_mount {MyAppWeb.Params, garden_id: "garden_id"}
      on_mount {MyAppWeb.Params, search: "search"}

  ## Installing and detaching at runtime

  `install/4` does at runtime what an `on_mount` entry does at mount, for
  example from a `handle_event/4`; `detach/3` undoes it:

      {:cont, socket} = LiveReverse.install(socket, MyAppWeb.Chat, "chat:lobby")
      socket = LiveReverse.detach(socket, MyAppWeb.Chat, "chat:lobby")

  `detach/3` first calls the optional `unmount/2` callback, which undoes
  what `mount/4` did:

      @impl true
      def unmount(topic, socket) do
        Phoenix.PubSub.unsubscribe(MyApp.PubSub, topic)
        socket
      end

  Then, with `attach: :each`, it removes that argument's hooks; with
  `attach: :once`, it removes the argument from the list and the hooks
  go with the last one. LiveView itself has no `unmount` callback:
  `terminate/2` only runs when the whole process stops.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, detach_hook: 3, put_private: 3]
  alias Phoenix.LiveView.Socket

  @type result :: {:cont, Socket.t()} | {:halt, Socket.t()}

  @typedoc """
  The `on_mount` argument with `attach: :each`, or the list of every
  entry's argument with `attach: :once`.
  """
  @type args :: term | [term]

  @callback mount(
              arg :: term,
              params :: map | :not_mounted_at_router | :installed,
              session :: map,
              Socket.t()
            ) :: result
  @callback unmount(arg :: term, Socket.t()) :: Socket.t()
  @callback handle_params(args, params :: map, uri :: String.t(), Socket.t()) :: result
  @callback handle_info(args, msg :: term, Socket.t()) :: result
  @callback handle_event(args, event :: String.t(), payload :: map, Socket.t()) ::
              result | {:halt, reply :: map, Socket.t()}
  @callback handle_async(args, name :: term, result :: {:ok, term} | {:exit, term}, Socket.t()) ::
              result

  @optional_callbacks mount: 4,
                      unmount: 2,
                      handle_params: 4,
                      handle_info: 3,
                      handle_event: 4,
                      handle_async: 4

  @callbacks [handle_params: 4, handle_info: 3, handle_event: 4, handle_async: 4]
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
          def __live_reverse_unmount__(_arg, socket), do: socket
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
  Defines a feature module in place and mounts it, so a LiveView can list
  its hooks inline, in pipeline order.

      defmodule MyAppWeb.GardenLive do
        use MyAppWeb, :live_view
        require LiveReverse

        LiveReverse.inline MakeQuery do
          @impl true
          def handle_params(_arg, params, _uri, socket),
            do: {:cont, assign(socket, :query, params["q"])}
        end

        LiveReverse.inline Search, arg: :products do
          @impl true
          def handle_params(:products, _params, _uri, socket),
            do: {:cont, assign(socket, :results, search(socket.assigns.query))}
        end
      end

  This defines `MyAppWeb.GardenLive.MakeQuery` with `use LiveReverse`
  and adds `on_mount MakeQuery` to the LiveView, then does the same for
  `Search` with `on_mount {Search, :products}`.

  The block is the body of a separate module: it sees the LiveView's
  aliases and imports, but not its functions: private ones are out of
  reach, public ones need the full module name.

  The mount part relies on `Phoenix.LiveView.on_mount/1`, so it only
  takes effect in a LiveView (`use Phoenix.LiveView`, directly or through
  `use MyAppWeb, :live_view`). Anywhere else, such as a LiveComponent or
  a plain module, the feature module is still defined but nothing mounts
  it, and no error is raised.

  `module` is the module name, nested under the caller like a nested
  `defmodule`.

  ## Options

    * `:arg` - the `on_mount` argument; without it the module is mounted
      bare and its callbacks get `:default`
    * `:attach` - passed to `use LiveReverse`
  """
  defmacro inline(module, opts, block \\ []) do
    opts = Keyword.merge(opts, block)

    {body, opts} =
      case Keyword.pop(opts, :do) do
        {nil, _opts} -> raise ArgumentError, "LiveReverse.inline/3 expects a do block"
        found -> found
      end

    {use_opts, opts} = Keyword.split(opts, [:attach])

    mod_or_mod_arg =
      case Keyword.fetch(opts, :arg) do
        {:ok, arg} -> {module, arg}
        :error -> module
      end

    case Keyword.keys(opts) -- [:arg] do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown LiveReverse.inline/3 options: #{inspect(unknown)}"
    end

    quote do
      defmodule unquote(module) do
        use LiveReverse, unquote(use_opts)
        unquote(body)
      end

      require Phoenix.LiveView
      Phoenix.LiveView.on_mount(unquote(mod_or_mod_arg))
    end
  end

  @doc """
  Runs `module`'s `mount/4` with `arg` and, unless it halts, attaches its
  hooks, the same way an `on_mount {module, arg}` entry does.

  Called after mount, e.g. from `handle_event/4`, `mount/4` gets `:installed`
  as params and an empty session; pass `:params` or `:session` to override
  them. Hooks attached this way only see later events: `handle_params/4`
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

  Calls `module`'s `unmount/2`, then removes the hooks of `arg`. With
  `attach: :once` it removes `arg` from the list instead, and the hooks
  only go with the last argument. Detaching something that is not
  attached only runs `unmount/2`.
  """
  def detach(socket, module, arg \\ :default) do
    socket =
      case module.__live_reverse_unmount__(arg, socket) do
        %Socket{} = socket ->
          socket

        other ->
          raise ArgumentError,
                "expected #{inspect(module)}.unmount/2 to return a socket, got: #{inspect(other)}"
      end

    case module.__live_reverse_attach__() do
      :each -> detach_stages(socket, module, {module, arg})
      :once -> detach_once(socket, module, arg)
    end
  end

  @doc """
  Returns the arguments of every `on_mount` entry (or `install/4`) of an
  `attach: :once` `module` attached to `socket`, in mount order.
  """
  def args(socket, module) do
    socket.private
    |> Map.get(:live_reverse, %{})
    |> Map.get(module, [])
  end

  defp attach(socket, module, arg) do
    case module.__live_reverse_attach__() do
      :each -> attach_stages(socket, module, {module, arg}, fn _socket -> arg end)
      :once -> attach_once(socket, module, arg)
    end
  end

  defp attach_once(socket, module, arg) do
    args = args(socket, module)
    socket = put_args(socket, module, args ++ [arg])

    if args == [] do
      attach_stages(socket, module, module, &args(&1, module))
    else
      socket
    end
  end

  defp detach_once(socket, module, arg) do
    case List.delete(args(socket, module), arg) do
      [] -> socket |> put_args(module, []) |> detach_stages(module, module)
      args -> put_args(socket, module, args)
    end
  end

  defp put_args(socket, module, []) do
    put_private(
      socket,
      :live_reverse,
      Map.delete(Map.get(socket.private, :live_reverse, %{}), module)
    )
  end

  defp put_args(socket, module, args) do
    put_private(
      socket,
      :live_reverse,
      Map.put(Map.get(socket.private, :live_reverse, %{}), module, args)
    )
  end

  defp attach_stages(socket, module, id, args),
    do:
      Enum.reduce(
        module.__live_reverse_stages__(),
        socket,
        &attach_stage(&2, module, id, args, &1)
      )

  defp detach_stages(socket, module, id),
    do: Enum.reduce(module.__live_reverse_stages__(), socket, &detach_hook(&2, id, &1))

  defp attach_stage(socket, module, id, args, :handle_params) do
    attach_hook(socket, id, :handle_params, fn params, uri, socket ->
      module.handle_params(args.(socket), params, uri, socket)
    end)
  end

  defp attach_stage(socket, module, id, args, :handle_info) do
    attach_hook(socket, id, :handle_info, fn msg, socket ->
      module.handle_info(args.(socket), msg, socket)
    end)
  end

  defp attach_stage(socket, module, id, args, :handle_event) do
    attach_hook(socket, id, :handle_event, fn event, payload, socket ->
      module.handle_event(args.(socket), event, payload, socket)
    end)
  end

  defp attach_stage(socket, module, id, args, :handle_async) do
    attach_hook(socket, id, :handle_async, fn name, result, socket ->
      module.handle_async(args.(socket), name, result, socket)
    end)
  end
end
