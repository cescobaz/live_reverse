defmodule LiveReverseTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.{Lifecycle, Socket}

  defmodule Each do
    use LiveReverse

    @impl true
    def handle_info(_msg, socket), do: {:cont, socket}
  end

  defmodule Once do
    use LiveReverse, attach: :once

    @impl true
    def handle_info(_msg, socket), do: {:cont, socket}
  end

  defmodule Unmounted do
    use LiveReverse

    @impl true
    def mount(arg, params, _session, socket),
      do: {:cont, put_private(socket, __MODULE__, {arg, params})}

    @impl true
    def unmount(:keep, socket), do: {:keep, socket}
    def unmount(:bad, socket), do: socket
    def unmount(_arg, socket), do: {:detach, put_private(socket, __MODULE__, :unmounted)}

    @impl true
    def handle_info(_msg, socket), do: {:cont, socket}

    defp put_private(socket, key, value), do: Phoenix.LiveView.put_private(socket, key, value)
  end

  defp socket, do: %Socket{private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}

  defp mount(socket, module, arg) do
    {:cont, socket} = module.on_mount(arg, %{}, %{}, socket)
    socket
  end

  defp hook_ids(socket), do: Enum.map(socket.private.lifecycle.handle_info, & &1.id)

  test "attach: :each attaches the hooks once per argument" do
    socket = socket() |> mount(Each, :a) |> mount(Each, :b)

    assert hook_ids(socket) == [{Each, :a}, {Each, :b}]
  end

  test "attach: :each raises when mounted twice with the same argument" do
    socket = mount(socket(), Each, :a)

    assert_raise ArgumentError, ~r/already attached/, fn -> mount(socket, Each, :a) end
  end

  test "attach: :once attaches the hooks only once" do
    socket = socket() |> mount(Once, :a) |> mount(Once, :b)

    assert hook_ids(socket) == [Once]
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

  test "detach/3 keeps the hooks when unmount/2 says so" do
    socket = mount(socket(), Unmounted, :keep)

    assert hook_ids(LiveReverse.detach(socket, Unmounted, :keep)) == [{Unmounted, :keep}]
  end

  test "detach/3 raises on a bad unmount/2 return" do
    socket = mount(socket(), Unmounted, :bad)

    assert_raise ArgumentError, ~r/to return {:keep, socket} or {:detach, socket}/, fn ->
      LiveReverse.detach(socket, Unmounted, :bad)
    end
  end

  test "attach: :once detaches without unmount/2 and can attach again" do
    socket = socket() |> mount(Once, :a) |> LiveReverse.detach(Once, :a)
    assert hook_ids(socket) == []

    assert hook_ids(mount(socket, Once, :b)) == [Once]
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
