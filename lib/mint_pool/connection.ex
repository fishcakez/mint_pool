defmodule MintPool.Connection do
  @moduledoc false

  alias MintPool.Backoff
  @behaviour :gen_statem

  @backoff_opts [:min_backoff, :max_backoff]

  defmodule Data do
    defstruct [:conn, monitors: %{}, requests: %{}]
  end

  def request(pid, tag, method, path, headers, body) do
    :gen_statem.call(pid, {:request, self(), tag, method, path, headers, body}, :infinity)
  catch
    :exit, {reason, _} ->
      {:error, reason}
  end

  def stream_request_body(pid, ref, body) do
    :gen_statem.call(pid, {:stream_request_body, ref, body}, :infinity)
  catch
    :exit, {reason, _} ->
      {:error, reason}
  end

  def cancel_request(pid, ref) do
    :gen_statem.cast(pid, {:cancel_request, ref})
  end

  def child_spec({scheme, host, port, opts}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [scheme, host, port, opts]},
      type: :worker
    }
  end

  def start_link(scheme, host, port, opts \\ []) do
    {start_opts, mint_opts} = Keyword.split(opts, [:debug, :hibernate_after, :spawn_opt])
    name = {:via, Registry, {MintPool.Registry, {scheme, host, port}}}
    :gen_statem.start_link(name, __MODULE__, {scheme, host, port, mint_opts}, start_opts)
  end

  def callback_mode() do
    :handle_event_function
  end

  def init(config) do
    {:next_state, state, data, actions} = handle_closed(config)
    {:ok, state, data, actions}
  end

  def handle_event(type, :connect, {:closed, config}, backoff)
      when type in [:internal, :state_timeout] do
    {scheme, host, port, opts} = config
    mint_opts = Keyword.drop(opts, @backoff_opts)

    case Mint.HTTP2.connect(scheme, host, port, mint_opts) do
      {:ok, conn} ->
        {:next_state, {:open, config}, %Data{conn: conn}}

      {:error, _} ->
        {timeout, backoff} = Backoff.backoff(backoff)
        {:keep_state, backoff, [{:state_timeout, timeout, :connect}]}
    end
  end

  def handle_event(
        {:call, from},
        {:request, pid, tag, method, path, headers, body},
        {:open, _},
        data
      ) do
    %Data{conn: conn, requests: requests, monitors: monitors} = data

    case Mint.HTTP2.request(conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        mon = Process.monitor(pid)
        monitors = Map.put(monitors, mon, ref)
        requests = Map.put(requests, ref, {pid, tag, mon})
        data = %Data{data | conn: conn, requests: requests, monitors: monitors}
        {:keep_state, data, [{:reply, from, {:ok, ref}}]}

      {:error, conn, reason} ->
        actions = [{:reply, from, {:error, reason}}, {:next_event, :interval, :close}]
        {:keep_state, %Data{data | conn: conn}, actions}
    end
  end

  def handle_event({:call, from}, {:stream_request_body, ref, body}, {:open, _}, data) do
    %Data{requests: requests} = data

    case requests do
      %{^ref => _} ->
        handle_body(data, from, ref, body)

      _ ->
        {:keep_state_and_data, [{:reply, from, {:error, :request_not_found}}]}
    end
  end

  def handle_event(:cast, {:cancel_request, ref}, {:open, _}, data) do
    %Data{requests: requests, monitors: monitors} = data

    case requests do
      %{^ref => {_pid, _tag, mon}} ->
        Process.demonitor(mon, [:flush])
        monitors = Map.delete(monitors, mon)
        requests = Map.delete(requests, ref)
        handle_cancel(%Data{data | requests: requests, monitors: monitors}, ref)

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:DOWN, mon, _, _pid, _}, {:open, _}, data) do
    %Data{requests: requests, monitors: monitors} = data
    {ref, monitors} = Map.pop(monitors, mon)
    requests = Map.delete(requests, ref)
    handle_cancel(%Data{data | requests: requests, monitors: monitors}, ref)
  end

  def handle_event(:info, info, {:open, _}, %Data{conn: conn} = data) do
    case Mint.HTTP2.stream(conn, info) do
      {:ok, conn, responses} ->
        handle_responses(%Data{data | conn: conn}, responses)

      {:error, conn, _error, responses} ->
        {:keep_state, data} = handle_responses(%Data{data | conn: conn}, responses)
        {:keep_state, data, [{:next_event, :internal, :close}]}

      :unknown ->
        :keep_state_and_data
    end
  end

  def handle_event(:internal, :close, {:open, config}, data) do
    %Data{conn: conn, requests: requests} = data

    for {ref, {pid, tag, mon}} <- requests do
      Process.demonitor(mon, [:flush])
      send(pid, {:mint_responses, tag, [{:error, ref, :closed}]})
    end

    {:ok, conn} = Mint.HTTP2.close(conn)
    send(self(), :flushed)
    {:next_state, {:flush, config}, conn}
  end

  def handle_event(:info, :flushed, {:flush, config}, _) do
    handle_closed(config)
  end

  def handle_event({:call, from}, _, _, _) do
    {:keep_state_and_data, {:reply, from, {:error, :closed}}}
  end

  def handle_event(async, _, _, _) when async in [:cast, :info] do
    :keep_state_and_data
  end

  defp handle_responses(data, responses) do
    {:keep_state, send_responses(responses, data, [])}
  end

  defp send_responses([next | rest], data, [prev | _] = acc)
       when elem(next, 1) == elem(prev, 1) do
    send_responses(rest, data, [next | acc])
  end

  defp send_responses(rest, data, [_ | _] = acc) do
    send_responses(rest, send_batch(data, acc), [])
  end

  defp send_responses([next | rest], data, []) do
    send_responses(rest, data, [next])
  end

  defp send_responses([], data, []) do
    data
  end

  defp send_batch(data, [last | _] = acc) do
    %Data{requests: requests, monitors: monitors} = data
    ref = elem(last, 1)

    case requests do
      %{^ref => {pid, tag, mon}} when elem(last, 0) in [:done, :error] ->
        send(pid, {:mint_responses, tag, Enum.reverse(acc)})
        Process.demonitor(mon, [:flush])
        monitors = Map.delete(monitors, mon)
        requests = Map.delete(requests, ref)
        %Data{data | requests: requests, monitors: monitors}

      %{^ref => {pid, tag, _mon}} ->
        send(pid, {:mint_responses, tag, Enum.reverse(acc)})
        data

      _ ->
        data
    end
  end

  defp handle_body(data, from, ref, body) do
    %Data{conn: conn} = data

    case Mint.HTTP2.stream_request_body(conn, ref, body) do
      {:ok, conn} ->
        {:keep_state, %Data{data | conn: conn}, {:reply, from, :ok}}

      {:error, conn, reason} ->
        actions = [{:reply, from, {:error, reason}}, {:next_event, :internal, :close}]
        {:keep_state, %Data{data | conn: conn}, actions}
    end
  end

  defp handle_cancel(%Data{conn: conn} = data, ref) do
    case Mint.HTTP2.cancel_request(conn, ref) do
      {:ok, conn} ->
        {:keep_state, %Data{data | conn: conn}}

      {:error, conn, _error} ->
        {:keep_state, %Data{data | conn: conn}, [{:next_event, :internal, :close}]}
    end
  end

  defp handle_closed(config) do
    {_, _, _, opts} = config

    backoff =
      opts
      |> Keyword.take(@backoff_opts)
      |> Backoff.new()

    {:next_state, {:closed, config}, backoff, [{:next_event, :internal, :connect}]}
  end
end
