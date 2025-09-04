defmodule Context do
  @moduledoc """
  A process-scoped hierarchical data storage library for Elixir.

  `Context` enables seamless data sharing between processes and their children through
  process dictionaries. It implements a hierarchical lookup mechanism where child processes
  can transparently access and inherit data from their parent processes.

  ## Key Features

  - **Hierarchical Access**: Child processes automatically inherit context from ancestors
  - **Process Isolation**: Each process maintains its own copy of accessed data for performance
  - **Single Initialization**: Enforces one context initialization per process hierarchy
  - **Safe Operations**: Type-safe operations with comprehensive error handling

  ## Architecture

  Context uses the Erlang process dictionary as storage and process links to traverse
  the process hierarchy. When a value is accessed from a parent process, it's automatically
  copied to the current process for subsequent fast access.

  ## Initialization Rules

  - Context can only be initialized **once** per process hierarchy
  - If any ancestor process has context initialized, descendants cannot initialize their own
  - Child processes can access and modify ancestor context using `get/1` and `unsafe_*` functions

  ## Basic Usage

      # Initialize context in your main process
      Context.init(user: %{id: 1, name: "Alice"}, tenant: "acme_corp")

      # Access values from any child process
      user = Context.get(:user)    # %{id: 1, name: "Alice"}
      tenant = Context.get(:tenant) # "acme_corp"

      # Update context data (bypasses initialization requirements)
      Context.unsafe_put(session_id: "abc123", debug: true)
      Context.unsafe_update(:user, &Map.put(&1, :last_seen, DateTime.utc_now()))

  ## Process Hierarchy Example

      # Main process
      Context.init(config: %{env: :prod, version: "1.0"})

      # Spawn worker processes that inherit context
      Task.async(fn ->
        config = Context.get(:config)  # Inherits from parent
        # ... do work with config
      end)

  ## Error Handling

  All functions are designed to handle edge cases gracefully:
  - `get/1` returns `nil` for missing keys
  - `init/1` raises clear errors for invalid initialization attempts
  - Process crashes are handled safely during hierarchy traversal
  """

  @context_key :__context__

  @typedoc """
  Context data stored as a map with atom keys and any values.
  """
  @type context_data :: %{atom() => any()}

  @typedoc """
  Initial data that can be provided as keyword list, map, or enumerable.
  """
  @type initial_data :: keyword() | context_data() | Enumerable.t()

  @typedoc """
  Context key used for lookups.
  """
  @type context_key :: atom()

  @doc """
  Initialize the context with initial data.

  Establishes the context for the current process with the provided data. This function
  enforces the single initialization rule and validates that no ancestor processes
  already have context initialized.

  ## Parameters

  - `initial_data` - Data to initialize the context with. Can be a keyword list,
    map, or any enumerable that can be converted to a map.

  ## Examples

      # Initialize with keyword list
      Context.init(user: %{id: 1}, tenant: "acme")

      # Initialize with map
      Context.init(%{user: %{id: 1}, tenant: "acme"})

      # Initialize empty context
      Context.init([])

  ## Returns

  Returns `:ok` on successful initialization.

  ## Raises

  - `RuntimeError` if context is already initialized in the current process
  - `RuntimeError` if any ancestor process has context initialized

  ## See Also

  - `get/1` for retrieving context values
  - `unsafe_put/1` for adding data after initialization
  """
  @spec init(initial_data()) :: :ok
  def init(initial_data) do
    case Process.get(@context_key) do
      nil ->
        case check_ancestors_for_context() do
          :no_ancestor_context ->
            Process.put(@context_key, Map.new(initial_data))
            :ok

          :ancestor_has_context ->
            raise "Cannot initialize context: ancestor process already has context initialized"
        end

      _ ->
        raise "Context already initialized in this process"
    end
  end

  @doc """
  Retrieve a value from the hierarchical context.

  Performs a hierarchical lookup starting with the current process, then traversing
  up through parent processes until the value is found. When a value is located in
  an ancestor process, it's automatically copied to the current process dictionary
  for optimized subsequent access.

  ## Lookup Strategy

  1. Check the current process's context
  2. If not found, traverse parent processes via process links
  3. Copy found values to current process for caching
  4. Return `nil` if key doesn't exist anywhere in the hierarchy

  ## Parameters

  - `key` - The atom key to look up in the context

  ## Examples

      # Basic retrieval
      user = Context.get(:user)

      # Handle missing keys gracefully
      config = Context.get(:config) || %{default: true}

      # Non-existent keys return nil
      Context.get(:nonexistent_key)  # => nil

  ## Returns

  Returns the value associated with the key, or `nil` if not found.

  ## Performance

  - First access may traverse the process hierarchy
  - Subsequent accesses are fast (local process dictionary lookup)
  - Safe to call frequently without performance concerns
  """
  @spec get(context_key()) :: any()
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
  Insert or update multiple values in the context without initialization checks.

  This function bypasses the initialization requirement and directly merges the
  provided data into the current process's context. It's useful for emergency
  scenarios, debugging, or when working with child processes that cannot initialize
  their own context.

  ## Parameters

  - `keyword_list` - A keyword list of key-value pairs to merge into the context

  ## Examples

      # Add debugging information
      Context.unsafe_put(debug_mode: true, trace_level: :verbose)

      # Emergency context setup
      Context.unsafe_put(
        emergency_flag: true,
        fallback_config: %{timeout: 1000},
        admin_mode: true
      )

      # Override existing values
      Context.unsafe_put(user: %{id: 999, admin: true})

  ## Behavior

  - Creates context if it doesn't exist
  - Merges new data with existing context
  - Overwrites existing keys with new values
  - Always succeeds (no validation or checks)

  ## Returns

  Returns `:ok` on successful update.

  ## Safety Considerations

  Use with caution as this bypasses all safety checks. Prefer `init/1` for
  initial context setup when possible.
  """
  @spec unsafe_put(keyword()) :: :ok
  def unsafe_put(keyword_list) when is_list(keyword_list) do
    current_data = Process.get(@context_key) || %{}
    new_data = Enum.into(keyword_list, current_data)
    Process.put(@context_key, new_data)
    :ok
  end

  @doc """
  Update a single context value using a transformation function.

  Applies the provided function to the current value of the specified key,
  bypassing initialization checks. The function receives the current value
  (or `nil` if the key doesn't exist) and should return the new value.

  ## Parameters

  - `key` - The atom key to update
  - `update_fn` - A function that takes the current value and returns the new value

  ## Examples

      # Increment a counter (handles nil gracefully)
      Context.unsafe_update(:counter, fn
        nil -> 1
        count -> count + 1
      end)

      # Update a map structure
      Context.unsafe_update(:user, &Map.put(&1, :last_seen, DateTime.utc_now()))

      # Add item to a list
      Context.unsafe_update(:items, fn
        nil -> ["new_item"]
        list -> ["new_item" | list]
      end)

      # Complex state transformation
      Context.unsafe_update(:session, fn session ->
        session
        |> Map.put(:last_activity, System.system_time(:second))
        |> Map.update(:request_count, 1, &(&1 + 1))
      end)

  ## Behavior

  - Creates context if it doesn't exist
  - Passes `nil` to the function if the key doesn't exist
  - Replaces the key's value with the function's return value
  - Always succeeds (no validation)

  ## Returns

  Returns `:ok` on successful update.

  ## Safety Considerations

  The update function should handle `nil` inputs gracefully when the key
  might not exist in the context.
  """
  @spec unsafe_update(context_key(), (any() -> any())) :: :ok
  def unsafe_update(key, update_fn) when is_function(update_fn, 1) do
    current_data = Process.get(@context_key) || %{}
    current_value = Map.get(current_data, key)
    new_value = update_fn.(current_value)
    new_data = Map.put(current_data, key, new_value)
    Process.put(@context_key, new_data)
    :ok
  end

  # Private functions

  defp get_local(key) do
    case Process.get(@context_key) do
      nil -> nil
      data_map when is_map(data_map) -> Map.get(data_map, key)
      _ -> nil
    end
  end

  defp put_local(key, value) do
    current_data = Process.get(@context_key) || %{}
    new_data = Map.put(current_data, key, value)
    Process.put(@context_key, new_data)
    :ok
  end

  defp check_ancestors_for_context do
    case :erlang.process_info(self(), :links) do
      {:links, links} -> check_links_for_context(links, [self()])
      _ -> :no_ancestor_context
    end
  end

  defp check_links_for_context([], _visited), do: :no_ancestor_context

  defp check_links_for_context([link | rest], visited) do
    if link in visited do
      check_links_for_context(rest, visited)
    else
      case has_context(link) do
        true ->
          :ancestor_has_context

        false ->
          # Recursively check the links of this process
          case :erlang.process_info(link, :links) do
            {:links, parent_links} ->
              parent_links_filtered = parent_links -- visited

              case check_links_for_context(parent_links_filtered, [link | visited]) do
                :ancestor_has_context -> :ancestor_has_context
                :no_ancestor_context -> check_links_for_context(rest, visited)
              end

            _ ->
              check_links_for_context(rest, visited)
          end
      end
    end
  end

  defp has_context(pid) when is_pid(pid) do
    case Process.alive?(pid) do
      true ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} ->
            case Keyword.get(dict, @context_key) do
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

  defp has_context(_not_pid), do: false

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
            case Keyword.get(dict, @context_key) do
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
