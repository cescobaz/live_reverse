defmodule LiveReverseTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.{Lifecycle, Socket}

  defmodule Each do
    use LiveReverse

    @impl true
    def handle_info(arg, {:ping, arg}, socket), do: {:halt, assign(socket, :pong, arg)}
    def handle_info(_arg, _msg, socket), do: {:cont, socket}
  end

  defmodule Once do
    use LiveReverse, attach: :once

    @impl true
    def handle_info(args, :ping, socket), do: {:cont, assign(socket, :pong, args)}
    def handle_info(_args, _msg, socket), do: {:cont, socket}
  end

  defmodule Unmounted do
    use LiveReverse

    @impl true
    def mount(arg, params, _session, socket),
      do: {:cont, put_private(socket, __MODULE__, {arg, params})}

    @impl true
    def unmount(:bad, _socket), do: :bad
    def unmount(_arg, socket), do: put_private(socket, __MODULE__, :unmounted)

    @impl true
    def handle_info(_arg, _msg, socket), do: {:cont, socket}

    defp put_private(socket, key, value), do: Phoenix.LiveView.put_private(socket, key, value)
  end

  defmodule InlineLive do
    use Phoenix.LiveView
    require LiveReverse

    LiveReverse.inline MakeQuery do
      @impl true
      def handle_info(_arg, _msg, socket), do: {:cont, socket}
    end

    LiveReverse.inline Search, arg: :products, attach: :once do
      @impl true
      def handle_info(_args, _msg, socket), do: {:cont, socket}
    end

    def render(assigns), do: ~H""
  end

  defp socket, do: %Socket{private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}

  defp mount(socket, module, arg) do
    {:cont, socket} = module.on_mount(arg, %{}, %{}, socket)
    socket
  end

  defp hook_ids(socket), do: Enum.map(socket.private.lifecycle.handle_info, & &1.id)

  defp send_info(socket, msg) do
    Enum.reduce_while(socket.private.lifecycle.handle_info, socket, fn hook, socket ->
      hook.function.(msg, socket)
    end)
  end

  test "attach: :each attaches the hooks once per argument and passes it" do
    socket = socket() |> mount(Each, :a) |> mount(Each, :b)

    assert hook_ids(socket) == [{Each, :a}, {Each, :b}]
    assert send_info(socket, {:ping, :b}).assigns.pong == :b
  end

  test "attach: :each raises when mounted twice with the same argument" do
    socket = mount(socket(), Each, :a)

    assert_raise ArgumentError, ~r/already attached/, fn -> mount(socket, Each, :a) end
  end

  test "attach: :once attaches the hooks once and passes every argument" do
    socket = socket() |> mount(Once, :a) |> mount(Once, :b)

    assert hook_ids(socket) == [Once]
    assert LiveReverse.args(socket, Once) == [:a, :b]
    assert send_info(socket, :ping).assigns.pong == [:a, :b]
  end

  test "attach: :once sees arguments installed after the hooks" do
    socket = mount(socket(), Once, :a)
    {:cont, socket} = LiveReverse.install(socket, Once, :b)

    assert send_info(socket, :ping).assigns.pong == [:a, :b]
  end

  test "attach: :once keeps the hooks until the last argument is detached" do
    socket = socket() |> mount(Once, :a) |> mount(Once, :b)

    socket = LiveReverse.detach(socket, Once, :a)
    assert hook_ids(socket) == [Once]
    assert LiveReverse.args(socket, Once) == [:b]

    socket = LiveReverse.detach(socket, Once, :b)
    assert hook_ids(socket) == []
    assert LiveReverse.args(socket, Once) == []

    assert hook_ids(mount(socket, Once, :c)) == [Once]
  end

  test "install/4 mounts with :installed params and attaches the hooks" do
    assert {:cont, socket} = LiveReverse.install(socket(), Unmounted, :a)

    assert socket.private[Unmounted] == {:a, :installed}
    assert hook_ids(socket) == [{Unmounted, :a}]
  end

  test "detach/3 calls unmount/2 and removes only that argument's hooks" do
    socket = socket() |> mount(Unmounted, :a) |> mount(Unmounted, :b)
    socket = LiveReverse.detach(socket, Unmounted, :a)

    assert socket.private[Unmounted] == :unmounted
    assert hook_ids(socket) == [{Unmounted, :b}]
  end

  test "detach/3 raises when unmount/2 does not return a socket" do
    socket = mount(socket(), Unmounted, :bad)

    assert_raise ArgumentError, ~r/to return a socket, got: :bad/, fn ->
      LiveReverse.detach(socket, Unmounted, :bad)
    end
  end

  test "inline/3 defines nested modules and mounts them in order" do
    assert InlineLive.MakeQuery.__live_reverse_attach__() == :each
    assert InlineLive.Search.__live_reverse_attach__() == :once

    assert Enum.map(InlineLive.__live__().lifecycle.mount, & &1.id) ==
             [{InlineLive.MakeQuery, :default}, {InlineLive.Search, :products}]
  end

  test "inline/3 rejects unknown options" do
    assert_raise ArgumentError, ~r/unknown LiveReverse.inline\/3 options: \[:key\]/, fn ->
      Code.compile_quoted(
        quote do
          require LiveReverse
          LiveReverse.inline(Bad, key: "x", do: :ok)
        end
      )
    end
  end

  test "rejects an unknown :attach value" do
    assert_raise ArgumentError, ~r/expected :attach/, fn ->
      Code.compile_quoted(
        quote do
          defmodule BadAttach do
            use LiveReverse, attach: :twice
          end
        end
      )
    end
  end
end
