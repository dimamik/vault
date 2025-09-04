
# Vault

A process-scoped hierarchical data storage library for Elixir applications. `Vault` enables seamless data sharing between processes and their children, making it ideal for request-scoped data, configuration propagation, and user session management.

## Features

- **Hierarchical Inheritance**: Child processes automatically access parent vault
- **Process Isolation**: Fast local caching with automatic data copying
- **Single Initialization**: Enforced once-per-hierarchy initialization prevents conflicts
- **Safe Operations**: Comprehensive error handling and type safety
- **Zero Dependencies**: Lightweight library using only Erlang/OTP primitives

## Installation

Add `vault` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:vault, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Initialize vault in your main process
Vault.init(
  user: %{id: 123, name: "Alice", role: :admin},
  tenant: "acme_corp",
  request_id: "req_abc123"
)

# Access data from any child process
Task.async(fn ->
  user = Vault.get(:user)        # %{id: 123, name: "Alice", role: :admin}
  tenant = Vault.get(:tenant)    # "acme_corp"
  request_id = Vault.get(:request_id)  # "req_abc123"

  # Data is automatically cached locally for fast subsequent access
  user_again = Vault.get(:user)  # Fast local lookup
end)
```

## Documentation

Full documentation is available at <https://hexdocs.pm/vault> or can be generated locally with `mix docs`.
