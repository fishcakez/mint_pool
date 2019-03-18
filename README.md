# MintPool

Work in progress pool abstraction for `Mint` targetting a dynamic cluster of
H2 servers that can be addressed as a single entity. For example a group of
hosts representing a service in service orientiated architecture. The API is
intended to match `Mint.HTTP` and `Mint.HTTP2` except that requests are load
balanced across the cluster. Behind the scene there is one process per host,
with hosts being added and removed dynamically at runtime via a service
discovery adapter.

Before handling dynamic clusters, work is in progress to create the process
abstractions to be compatible with `Mint`. If this library is useful to you
today it may not be in future, and vice versa.

## Installation

Avaliable via git, the package can be installed by adding `mint_pool` to your
list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mint_pool, "~> 0.1.0", github: "fishcakez/mint_pool"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/mint_pool](https://hexdocs.pm/mint_pool).

