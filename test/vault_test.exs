defmodule VaultTest do
  use ExUnit.Case
  doctest Vault

  setup do
    Process.put(:__vault__, nil)
    :ok
  end

  describe "init/1" do
    test "initializes with empty data" do
      assert :ok = Vault.init([])
      assert %{} = Process.get(:__vault__)
    end

    test "initializes with keyword list" do
      data = [user: %{id: 1, name: "Alice"}, tenant: "acme"]
      assert :ok = Vault.init(data)

      expected = %{user: %{id: 1, name: "Alice"}, tenant: "acme"}
      assert ^expected = Process.get(:__vault__)
    end

    test "initializes with map" do
      data = %{user: %{id: 1, name: "Bob"}, tenant: "example"}
      assert :ok = Vault.init(data)
      assert ^data = Process.get(:__vault__)
    end

    test "keyword list and map produce equivalent results" do
      Process.put(:__vault__, nil)
      Vault.init(user: %{id: 1}, tenant: "test")
      keyword_result = Process.get(:__vault__)

      Process.put(:__vault__, nil)
      Vault.init(%{user: %{id: 1}, tenant: "test"})
      map_result = Process.get(:__vault__)

      assert keyword_result == map_result
    end

    test "prevents double initialization" do
      Vault.init([])

      assert_raise RuntimeError,
                   "Vault already initialized in this process",
                   fn -> Vault.init([]) end
    end

    test "prevents child initialization when ancestor has vault" do
      Vault.init(parent_data: "test")
      test_pid = self()

      spawn_link(fn ->
        assert_raise RuntimeError,
                     "Cannot initialize vault: ancestor process already has vault initialized",
                     fn -> Vault.init(child_data: "should_fail") end

        send(test_pid, :done)
      end)

      assert_receive :done, 1000
    end
  end

  describe "get/1" do
    test "returns nil when vault not initialized" do
      assert nil == Vault.get(:user)
    end

    test "returns nil for non-existent key" do
      Vault.init([])
      assert nil == Vault.get(:nonexistent)
    end

    test "returns value for existing key" do
      Vault.init(user: %{id: 1, name: "Alice"})
      assert %{id: 1, name: "Alice"} = Vault.get(:user)
    end

    test "inherits from parent and caches locally" do
      Vault.init(shared_value: "from_parent")
      test_pid = self()

      spawn_link(fn ->
        value = Vault.get(:shared_value)
        send(test_pid, {:value, value})

        # Check local cache
        local_vault = Process.get(:__vault__, %{})
        send(test_pid, {:cached, Map.get(local_vault, :shared_value)})
      end)

      assert_receive {:value, "from_parent"}, 1000
      assert_receive {:cached, "from_parent"}, 1000
    end
  end

  describe "unsafe_put/1" do
    test "works without initialization" do
      assert :ok = Vault.unsafe_put(emergency: true, debug: false)
      assert true == Vault.get(:emergency)
      assert false == Vault.get(:debug)
    end

    test "merges with existing data" do
      Vault.init(existing: "value")
      assert :ok = Vault.unsafe_put(new_key: "new_value")

      assert "value" == Vault.get(:existing)
      assert "new_value" == Vault.get(:new_key)
    end

    test "overwrites existing keys" do
      Vault.init(key: "old_value")
      Vault.unsafe_put(key: "new_value")
      assert "new_value" == Vault.get(:key)
    end
  end

  describe "unsafe_update/2" do
    test "works without initialization" do
      assert :ok = Vault.unsafe_update(:counter, fn nil -> 1 end)
      assert 1 == Vault.get(:counter)
    end

    test "updates existing values" do
      Vault.init(counter: 5)
      Vault.unsafe_update(:counter, &(&1 + 10))
      assert 15 == Vault.get(:counter)
    end

    test "handles nil gracefully" do
      Vault.init([])
      Vault.unsafe_update(:new_key, fn nil -> "initialized" end)
      assert "initialized" == Vault.get(:new_key)
    end

    test "updates complex structures" do
      Vault.init(user: %{id: 1, name: "Alice", last_seen: nil})

      now = DateTime.utc_now()
      Vault.unsafe_update(:user, &Map.put(&1, :last_seen, now))

      user = Vault.get(:user)
      assert user.last_seen == now
      assert user.name == "Alice"
    end
  end

  describe "hierarchical lookup" do
    test "multi-level inheritance works correctly" do
      Vault.init(level: "root", shared: "from_root")

      result =
        Task.async(fn ->
          parent_data = %{
            shared: Vault.get(:shared),
            level: Vault.get(:level)
          }

          child_result =
            Task.async(fn ->
              %{
                shared: Vault.get(:shared),
                level: Vault.get(:level),
                missing: Vault.get(:nonexistent)
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
