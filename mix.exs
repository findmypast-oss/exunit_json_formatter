defmodule ExUnitJsonFormatter.Mixfile do
  use Mix.Project

  def project do
    [app: :exunit_json_formatter,
     version: "0.1.0",
     description: "ExUnit formatter that outputs a stream of JSON objects",
     package: package(),
     elixir: "~> 1.4",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps()]
  end

  def package do
    [files: ["lib", "mix.exs", "README.md", "LICENSE"],
     maintainers: ["Jae Bach Hardie"],
     licenses: ["Apache 2.0"],
     links: %{"GitHub" => "https://github.com/findmypast-oss/exunit_json_formatter"},
     source_url: "https://github.com/findmypast-oss/exunit_json_formatter"]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [{:poison, "~> 3.1"},
     {:ex_doc, ">= 0.0.0", only: :dev}]
  end
end
