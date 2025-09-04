# Context

A process-scoped hierarchical data storage library for Elixir applications. `Context` enables seamless data sharing between processes and their children, making it ideal for request-scoped data, configuration propagation, and user session management.

## Features

- **Hierarchical Inheritance**: Child processes automatically access parent context
- **Process Isolation**: Fast local caching with automatic data copying
- **Single Initialization**: Enforced once-per-hierarchy initialization prevents conflicts
- **Safe Operations**: Comprehensive error handling and type safety
- **Zero Dependencies**: Lightweight library using only Erlang/OTP primitives

## Installation

Add `context` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:context, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Initialize context in your main process
Context.init(
  user: %{id: 123, name: "Alice", role: :admin},
  tenant: "acme_corp",
  request_id: "req_abc123"
)

# Access data from any child process
Task.async(fn ->
  user = Context.get(:user)        # %{id: 123, name: "Alice", role: :admin}
  tenant = Context.get(:tenant)    # "acme_corp"
  request_id = Context.get(:request_id)  # "req_abc123"

  # Data is automatically cached locally for fast subsequent access
  user_again = Context.get(:user)  # Fast local lookup
end)
```

## Documentation

Full documentation is available at <https://hexdocs.pm/context> or can be generated locally with `mix docs`.
