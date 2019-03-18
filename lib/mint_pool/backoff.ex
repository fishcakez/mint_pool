defmodule MintPool.Backoff do
  @moduledoc false
  alias MintPool.Backoff
  use Bitwise
  defstruct [:state, :interval, :max]

  def new(opts) do
    state = :rand.seed_s(:exsp)
    min = opts[:min_backoff] || 100
    max = opts[:max_backoff] || 1000

    cond do
      min < 0 or not is_integer(min) ->
        raise ArgumentError, "min backoff must be non negative integer, got: #{inspect(min)}"

      max < 1 or not is_integer(max) ->
        raise ArgumentError, "max backoff must be positive integer, got: #{inspect(max)}"

      min >= max ->
        raise ArgumentError, "min backoff #{min}ms must be less than max backoff #{max}ms"

      true ->
        %Backoff{state: state, interval: min, max: max}
    end
  end

  def backoff(%Backoff{interval: interval} = backoff) do
    {interval, handle_backoff(backoff)}
  end

  defp handle_backoff(%Backoff{state: state, interval: interval, max: max} = backoff) do
    case div(max, 3) do
      0 ->
        {next, state} = :rand.uniform_s(max, state)
        %Backoff{backoff | state: state, interval: next}

      bound when interval > bound ->
        handle_backoff(backoff, bound)

      _ ->
        handle_backoff(backoff, interval)
    end
  end

  defp handle_backoff(%Backoff{state: state} = backoff, interval) do
    {rand, state} = :rand.uniform_s((interval <<< 1) + 1, state)
    next = interval + rand - 1
    %Backoff{backoff | state: state, interval: next}
  end
end
