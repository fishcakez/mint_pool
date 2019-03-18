defmodule MintPool.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      {Registry, [keys: :unique, name: MintPool.Registry, partitions: 1]}
    ]

    opts = [strategy: :one_for_one, name: MintPool.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
