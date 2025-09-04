defmodule Vault do
  @moduledoc """
  A process-scoped hierarchical data storage library for Elixir.

  `Vault` enables seamless data sharing between processes and their children through
  process dictionaries. It implements a hierarchical lookup mechanism where child processes
  can transparently access and inherit data from their parent processes.

  ## Key Features

  - **Hierarchical Access**: Child processes automatically inherit vault from ancestors
  - **Process Isolation**: Each process maintains its own copy of accessed data for performance
  - **Single Initialization**: Enforces one vault initialization per process hierarchy
  - **Safe Operations**: Type-safe operations with comprehensive error handling

  ## Architecture

  Vault uses the Erlang process dictionary as storage and process links to traverse
  the process hierarchy. When a value is accessed from a parent process, it's automatically
  copied to the current process for subsequent fast access.

  ## Initialization Rules

  - Vault can only be initialized **once** per process hierarchy
  - If any ancestor process has vault initialized, descendants cannot initialize their own
  - Child processes can access and modify ancestor vault using `get/1` and `unsafe_*` functions

  ## Basic Usage

      # Initialize vault in your main process
      Vault.init(user: %{id: 1, name: "Alice"}, tenant: "acme_corp")

      # Access values from any child process
      user = Vault.get(:user)    # %{id: 1, name: "Alice"}
      tenant = Vault.get(:tenant) # "acme_corp"

      # Update vault data (bypasses initialization requirements)
      Vault.unsafe_put(session_id: "abc123", debug: true)
      Vault.unsafe_update(:user, &Map.put(&1, :last_seen, DateTime.utc_now()))

  ## Process Hierarchy Example

      # Main process
      Vault.init(config: %{env: :prod, version: "1.0"})

      # Spawn worker processes that inherit vault
      Task.async(fn ->
        config = Vault.get(:config)  # Inherits from parent
        # ... do work with config
      end)

  ## Error Handling

  All functions are designed to handle edge cases gracefully:
  - `get/1` returns `nil` for missing keys
  - `init/1` raises clear errors for invalid initialization attempts
  - Process crashes are handled safely during hierarchy traversal
  """

  @vault_key :__vault__

  @typedoc """
  Vault data stored as a map with atom keys and any values.
  """
  @type vault_data :: %{atom() => any()}

  @typedoc """
  Initial data that can be provided as keyword list, map, or enumerable.
  """
  @type initial_data :: keyword() | vault_data() | Enumerable.t()

  @typedoc """
  Vault key used for lookups.
  """
  @type vault_key :: atom()

  @doc """
  Initialize the vault with initial data.

  Establishes the vault for the current process with the provided data. This function
  enforces the single initialization rule and validates that no ancestor processes
  already have context initialized.

  ## Parameters

  - `initial_data` - Data to initialize the vault with. Can be a keyword list,
    map, or any enumerable that can be converted to a map.

  ## Examples

  # Initialize with keyword list
  Vault.init(user: %{id: 1}, tenant: "acme")

  # Initialize with map
  Vault.init(%{user: %{id: 1}, tenant: "acme"})

  # Initialize empty vault
  Vault.init([])

  ## Returns

  Returns `:ok` on successful initialization.

  ## Raises

  - `RuntimeError` if vault is already initialized in the current process
  - `RuntimeError` if any ancestor process has vault initialized

  ## See Also

  - `get/1` for retrieving vault values
  - `unsafe_put/1` for adding data after initialization
  """
  @spec init(initial_data()) :: :ok
  def init(initial_data) do
    case Process.get(@vault_key) do
      nil ->
        case check_ancestors_for_vault() do
          :no_ancestor_vault ->
            Process.put(@vault_key, Map.new(initial_data))
            :ok

          :ancestor_has_vault ->
            raise "Cannot initialize vault: ancestor process already has vault initialized"
        end

      _ ->
        raise "Vault already initialized in this process"
    end
  end

  @doc """
  Retrieve a value from the hierarchical vault.

  Performs a hierarchical lookup starting with the current process, then traversing
  up through parent processes until the value is found. When a value is located in
  an ancestor process, it's automatically copied to the current process dictionary
  for optimized subsequent access.

  ## Lookup Strategy

  1. Check the current process's vault
  2. If not found, traverse parent processes via process links
  3. Copy found values to current process for caching
  4. Return `nil` if key doesn't exist anywhere in the hierarchy

  ## Parameters

  - `key` - The atom key to look up in the vault

  ## Examples

  # Basic retrieval
  user = Vault.get(:user)

  # Handle missing keys gracefully
  config = Vault.get(:config) || %{default: true}

  # Non-existent keys return nil
  Vault.get(:nonexistent_key)  # => nil

  ## Returns

  Returns the value associated with the key, or `nil` if not found.

  ## Performance

  - First access may traverse the process hierarchy
  - Subsequent accesses are fast (local process dictionary lookup)
  - Safe to call frequently without performance concerns
  """
  @spec get(vault_key()) :: any()
  def get(key) do
    case get_local(key) do
      nil ->
        case find_in_parents(key) do
          nil ->
            nil

          value ->
            # Copy to local process dict for faster future access
            put_local(key, value)
            value
        end

      value ->
        value
    end
  end

  @doc """
  Insert or update multiple values in the vault without initialization checks.

  This function bypasses the initialization requirement and directly merges the
  provided data into the current process's vault. It's useful for emergency
  scenarios, debugging, or when working with child processes that cannot initialize
  their own vault.

  ## Parameters

  - `keyword_list` - A keyword list of key-value pairs to merge into the vault

  ## Examples

      # Add debugging information
      Vault.unsafe_put(debug_mode: true, trace_level: :verbose)

      # Emergency vault setup
      Vault.unsafe_put(
        emergency_flag: true,
        fallback_config: %{timeout: 1000},
        admin_mode: true
      )

      # Override existing values
      Vault.unsafe_put(user: %{id: 999, admin: true})

  ## Behavior

  - Creates vault if it doesn't exist
  - Merges new data with existing vault
  - Overwrites existing keys with new values
  - Always succeeds (no validation or checks)

  ## Returns

  Returns `:ok` on successful update.

  ## Safety Considerations

  Use with caution as this bypasses all safety checks. Prefer `init/1` for
  initial vault setup when possible.
  """
  @spec unsafe_put(keyword()) :: :ok
  def unsafe_put(keyword_list) when is_list(keyword_list) do
    current_data = Process.get(@vault_key) || %{}
    new_data = Enum.into(keyword_list, current_data)
    Process.put(@vault_key, new_data)
    :ok
  end

  @doc """
  Update a single vault value using a transformation function.

  Applies the provided function to the current value of the specified key,
  bypassing initialization checks. The function receives the current value
  (or `nil` if the key doesn't exist) and should return the new value.

  ## Parameters

  - `key` - The atom key to update
  - `update_fn` - A function that takes the current value and returns the new value

  ## Examples

      # Increment a counter (handles nil gracefully)
      Vault.unsafe_update(:counter, fn
        nil -> 1
        count -> count + 1
      end)

      # Update a map structure
      Vault.unsafe_update(:user, &Map.put(&1, :last_seen, DateTime.utc_now()))

      # Add item to a list
      Vault.unsafe_update(:items, fn
        nil -> ["new_item"]
        list -> ["new_item" | list]
      end)

      # Complex state transformation
      Vault.unsafe_update(:session, fn session ->
        session
        |> Map.put(:last_activity, System.system_time(:second))
        |> Map.update(:request_count, 1, &(&1 + 1))
      end)

  ## Behavior

  - Creates vault if it doesn't exist
  - Passes `nil` to the function if the key doesn't exist
  - Replaces the key's value with the function's return value
  - Always succeeds (no validation)

  ## Returns

  Returns `:ok` on successful update.

  ## Safety Considerations

  The update function should handle `nil` inputs gracefully when the key
  might not exist in the vault.
  """
  @spec unsafe_update(vault_key(), (any() -> any())) :: :ok
  def unsafe_update(key, update_fn) when is_function(update_fn, 1) do
    current_data = Process.get(@vault_key) || %{}
    current_value = Map.get(current_data, key)
    new_value = update_fn.(current_value)
    new_data = Map.put(current_data, key, new_value)
    Process.put(@vault_key, new_data)
    :ok
  end

  # Private functions

  defp get_local(key) do
    case Process.get(@vault_key) do
      nil -> nil
      data_map when is_map(data_map) -> Map.get(data_map, key)
      _ -> nil
    end
  end

  defp put_local(key, value) do
    current_data = Process.get(@vault_key) || %{}
    new_data = Map.put(current_data, key, value)
    Process.put(@vault_key, new_data)
    :ok
  end

  defp check_ancestors_for_vault do
    case :erlang.process_info(self(), :links) do
      {:links, links} -> check_links_for_vault(links, [self()])
      _ -> :no_ancestor_vault
    end
  end

  defp check_links_for_vault([], _visited), do: :no_ancestor_vault

  defp check_links_for_vault([link | rest], visited) do
    if link in visited do
      check_links_for_vault(rest, visited)
    else
      case has_vault(link) do
        true ->
          :ancestor_has_vault

        false ->
          # Recursively check the links of this process
          case :erlang.process_info(link, :links) do
            {:links, parent_links} ->
              parent_links_filtered = parent_links -- visited

              case check_links_for_vault(parent_links_filtered, [link | visited]) do
                :ancestor_has_vault -> :ancestor_has_vault
                :no_ancestor_vault -> check_links_for_vault(rest, visited)
              end

            _ ->
              check_links_for_vault(rest, visited)
          end
      end
    end
  end

  defp has_vault(pid) when is_pid(pid) do
    case Process.alive?(pid) do
      true ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} ->
            case Keyword.get(dict, @vault_key) do
              nil -> false
              _ -> true
            end

          nil ->
            false
        end

      false ->
        false
    end
  end

  defp has_vault(_not_pid), do: false

  defp find_in_parents(key) do
    case :erlang.process_info(self(), :links) do
      {:links, links} -> search_links(links, key, [self()])
      _ -> nil
    end
  end

  defp search_links([], _key, _visited), do: nil

  defp search_links([link | rest], key, visited) do
    if link in visited do
      search_links(rest, key, visited)
    else
      case get_from_process(link, key) do
        nil ->
          # Recursively search the links of this process
          case :erlang.process_info(link, :links) do
            {:links, parent_links} ->
              parent_links_filtered = parent_links -- visited

              case search_links(parent_links_filtered, key, [link | visited]) do
                nil -> search_links(rest, key, visited)
                value -> value
              end

            _ ->
              search_links(rest, key, visited)
          end

        value ->
          value
      end
    end
  end

  defp get_from_process(pid, key) when is_pid(pid) do
    case Process.alive?(pid) do
      true ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} ->
            case Keyword.get(dict, @vault_key) do
              nil -> nil
              data_map when is_map(data_map) -> Map.get(data_map, key)
              _ -> nil
            end

          nil ->
            nil
        end

      false ->
        nil
    end
  end

  defp get_from_process(_not_pid, _key), do: nil
end
