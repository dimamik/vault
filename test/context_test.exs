defmodule ContextTest do
  use ExUnit.Case
  doctest Context

  setup do
    Process.put(:__context__, nil)
    :ok
  end

  describe "init/1" do
    test "initializes with empty data" do
      assert :ok = Context.init([])
      assert %{} = Process.get(:__context__)
    end

    test "initializes with keyword list" do
      data = [user: %{id: 1, name: "Alice"}, tenant: "acme"]
      assert :ok = Context.init(data)

      expected = %{user: %{id: 1, name: "Alice"}, tenant: "acme"}
      assert ^expected = Process.get(:__context__)
    end

    test "initializes with map" do
      data = %{user: %{id: 1, name: "Bob"}, tenant: "example"}
      assert :ok = Context.init(data)
      assert ^data = Process.get(:__context__)
    end

    test "keyword list and map produce equivalent results" do
      Process.put(:__context__, nil)
      Context.init(user: %{id: 1}, tenant: "test")
      keyword_result = Process.get(:__context__)

      Process.put(:__context__, nil)
      Context.init(%{user: %{id: 1}, tenant: "test"})
      map_result = Process.get(:__context__)

      assert keyword_result == map_result
    end

    test "prevents double initialization" do
      Context.init([])

      assert_raise RuntimeError,
                   "Context already initialized in this process",
                   fn -> Context.init([]) end
    end

    test "prevents child initialization when ancestor has context" do
      Context.init(parent_data: "test")
      test_pid = self()

      spawn_link(fn ->
        assert_raise RuntimeError,
                     "Cannot initialize context: ancestor process already has context initialized",
                     fn -> Context.init(child_data: "should_fail") end

        send(test_pid, :done)
      end)

      assert_receive :done, 1000
    end
  end

  describe "get/1" do
    test "returns nil when context not initialized" do
      assert nil == Context.get(:user)
    end

    test "returns nil for non-existent key" do
      Context.init([])
      assert nil == Context.get(:nonexistent)
    end

    test "returns value for existing key" do
      Context.init(user: %{id: 1, name: "Alice"})
      assert %{id: 1, name: "Alice"} = Context.get(:user)
    end

    test "inherits from parent and caches locally" do
      Context.init(shared_value: "from_parent")
      test_pid = self()

      spawn_link(fn ->
        value = Context.get(:shared_value)
        send(test_pid, {:value, value})

        # Check local cache
        local_context = Process.get(:__context__, %{})
        send(test_pid, {:cached, Map.get(local_context, :shared_value)})
      end)

      assert_receive {:value, "from_parent"}, 1000
      assert_receive {:cached, "from_parent"}, 1000
    end
  end

  describe "unsafe_put/1" do
    test "works without initialization" do
      assert :ok = Context.unsafe_put(emergency: true, debug: false)
      assert true == Context.get(:emergency)
      assert false == Context.get(:debug)
    end

    test "merges with existing data" do
      Context.init(existing: "value")
      assert :ok = Context.unsafe_put(new_key: "new_value")

      assert "value" == Context.get(:existing)
      assert "new_value" == Context.get(:new_key)
    end

    test "overwrites existing keys" do
      Context.init(key: "old_value")
      Context.unsafe_put(key: "new_value")
      assert "new_value" == Context.get(:key)
    end
  end

  describe "unsafe_update/2" do
    test "works without initialization" do
      assert :ok = Context.unsafe_update(:counter, fn nil -> 1 end)
      assert 1 == Context.get(:counter)
    end

    test "updates existing values" do
      Context.init(counter: 5)
      Context.unsafe_update(:counter, &(&1 + 10))
      assert 15 == Context.get(:counter)
    end

    test "handles nil gracefully" do
      Context.init([])
      Context.unsafe_update(:new_key, fn nil -> "initialized" end)
      assert "initialized" == Context.get(:new_key)
    end

    test "updates complex structures" do
      Context.init(user: %{id: 1, name: "Alice", last_seen: nil})

      now = DateTime.utc_now()
      Context.unsafe_update(:user, &Map.put(&1, :last_seen, now))

      user = Context.get(:user)
      assert user.last_seen == now
      assert user.name == "Alice"
    end
  end

  describe "hierarchical lookup" do
    test "multi-level inheritance works correctly" do
      Context.init(level: "root", shared: "from_root")

      result =
        Task.async(fn ->
          parent_data = %{
            shared: Context.get(:shared),
            level: Context.get(:level)
          }

          child_result =
            Task.async(fn ->
              %{
                shared: Context.get(:shared),
                level: Context.get(:level),
                missing: Context.get(:nonexistent)
              }
            end)
            |> Task.await()

          %{parent: parent_data, child: child_result}
        end)
        |> Task.await()

      assert "from_root" == result.parent.shared
      assert "root" == result.parent.level
      assert "from_root" == result.child.shared
      assert "root" == result.child.level
      assert nil == result.child.missing
    end
  end
end
