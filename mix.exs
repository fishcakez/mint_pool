defmodule MintPool.MixProject do
  use Mix.Project

  def project do
    [
      app: :mint_pool,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MintPool.Application, []}
    ]
  end

  defp deps do
    [
      {:mint, "~> 0.1", github: "ericmj/mint", ref: "9e6746643defcc25c1c79d30c478b5f4e81ff1c6"}
    ]
  end
end
