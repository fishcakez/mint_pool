defmodule MintPool.HTTP do
  @moduledoc """
  Mint.HTTP compatible API using MintPool cluster pool.  
  """

  alias Mint.Types
  alias MintPool.{Connection, HTTP}

  defstruct [:cluster, state: :open, requests: %{}, private: %{}]

  @opaque t() :: %HTTP{
            cluster: {pid, reference},
            state: :open | :closed,
            requests: %{reference => pid},
            private: %{atom => term}
          }

  @spec connect(Types.scheme(), String.t(), :inet.port_number(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def connect(scheme, host, port, _opts \\ []) do
    cluster = {scheme, host, port}

    try do
      Registry.lookup(MintPool.Registry, cluster)
    rescue
      ArgumentError ->
        {:error, :noproc}
    else
      [{pid, _}] ->
        {:ok, %HTTP{cluster: {pid, Process.monitor(pid)}}}

      [] ->
        {:error, :noproc}
    end
  end

  @spec close(t()) :: {:ok, t()}
  def close(%HTTP{cluster: {_, mon}, requests: requests} = conn) do
    Process.demonitor(mon, [:flush])

    for {ref, pid} <- requests do
      Connection.cancel_request(pid, ref)
    end

    {:ok, %HTTP{conn | state: :closed, requests: %{}}}
  end

  @spec open?(t()) :: boolean
  def open?(%HTTP{state: :closed}), do: false
  def open?(%HTTP{state: _}), do: true

  @spec request(t(), String.t(), String.t(), Types.headers(), iodata() | nil | :stream) ::
          {:ok, t(), Types.request_ref()} | {:error, t(), term()}
  def request(
        %HTTP{cluster: {pid, mon}, requests: requests} = conn,
        method,
        path,
        headers,
        body \\ nil
      )
      when is_binary(method) and is_binary(path) and is_list(headers) do
    case Connection.request(pid, mon, method, path, headers, body) do
      {:ok, ref} ->
        {:ok, %HTTP{conn | requests: Map.put(requests, ref, pid)}, ref}

      {:error, reason} ->
        {:error, conn, reason}
    end
  end

  @spec stream_request_body(t(), Types.request_ref(), iodata() | :eof) ::
          {:ok, t()} | {:error, t(), term()}
  def stream_request_body(%HTTP{requests: requests} = conn, ref, body) do
    pid = Map.fetch!(requests, ref)

    case Connection.stream_request_body(pid, ref, body) do
      :ok ->
        {:ok, conn}

      {:error, reason} ->
        {:error, %HTTP{conn | requests: Map.delete(requests, ref)}, reason}
    end
  end

  def stream(%HTTP{cluster: {_, mon}} = conn, {:DOWN, mon, _, _, reason}),
    do: {:error, %{conn | state: :closed}, reason}

  def stream(
        %HTTP{cluster: {_, mon}, requests: requests} = conn,
        {:mint_responses, mon, responses}
      ) do
    {responses, requests} = handle_responses(responses, requests, [])
    {:ok, %HTTP{conn | requests: requests}, responses}
  end

  defp handle_responses([response | rest], requests, acc) do
    ref = elem(response, 1)

    case requests do
      %{^ref => _} when elem(response, 0) == :done ->
        handle_responses(rest, Map.delete(requests, ref), [response | acc])

      %{^ref => _} ->
        handle_responses(rest, requests, [response | acc])

      _ ->
        handle_responses(rest, requests, acc)
    end
  end

  defp handle_responses([], requests, acc) do
    {Enum.reverse(acc), requests}
  end

  @spec put_private(t(), atom(), term()) :: t()
  def put_private(%HTTP{private: private} = conn, key, value) when is_atom(key) do
    %HTTP{conn | private: Map.put(private, key, value)}
  end

  @spec get_private(t(), atom(), term()) :: term()
  def get_private(%HTTP{private: private}, key, default \\ nil) when is_atom(key) do
    Map.get(private, key, default)
  end

  @spec delete_private(t(), atom()) :: t()
  def delete_private(%HTTP{private: private} = conn, key) when is_atom(key) do
    %HTTP{conn | private: Map.delete(private, key)}
  end

  @spec get_socket(t()) :: reference()
  def get_socket(%HTTP{cluster: {_, ref}}) do
    ref
  end
end
