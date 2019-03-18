defmodule MintPool do
  @moduledoc """
  Cluster pool abstraction for Mint HTTP2 Client.
  """

  @doc false
  def child_spec({scheme, host, port, opts}) do
    %{
      id: {scheme, host, port},
      start: {__MODULE__, :start_link, [scheme, host, port, opts]},
      type: :supervisor
    }
  end

  @spec start_link(Types.scheme(), String.t(), :inet.port_number(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_link(scheme, host, port, opts \\ []) do
    connection = MintPool.Connection.child_spec({scheme, host, port, opts})
    Supervisor.start_link([connection], strategy: :one_for_one, max_restarts: 0)
  end
end
