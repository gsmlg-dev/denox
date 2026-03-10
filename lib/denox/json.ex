defmodule Denox.JSON do
  @moduledoc """
  Configurable JSON encoder/decoder for Denox.

  By default uses Elixir's built-in `JSON` module (requires Elixir 1.18+).
  Can be configured to use `Jason` or any module that implements
  `encode!/1` and `decode/1`.

  ## Configuration

      # Use built-in JSON (default)
      config :denox, :json_module, JSON

      # Use Jason
      config :denox, :json_module, Jason

  """

  @doc false
  def module do
    Application.get_env(:denox, :json_module, JSON)
  end

  @doc false
  def encode!(term) do
    module().encode!(term)
  end

  @doc false
  def decode(binary) do
    module().decode(binary)
  end

  @doc false
  def decode!(binary) do
    module().decode!(binary)
  end

  @doc false
  def encode_pretty!(term) do
    case module() do
      Jason -> Jason.encode!(term, pretty: true)
      _ -> encode!(term) |> pretty_print()
    end
  end

  defp pretty_print(json) when is_binary(json) do
    json
    |> decode!()
    |> do_pretty(0)
  end

  defp do_pretty(map, indent) when is_map(map) do
    if map_size(map) == 0 do
      "{}"
    else
      pad = String.duplicate("  ", indent + 1)
      end_pad = String.duplicate("  ", indent)

      entries =
        map
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.map_join(",\n", fn {k, v} ->
          "#{pad}#{encode!(k)}: #{do_pretty(v, indent + 1)}"
        end)

      "{\n#{entries}\n#{end_pad}}"
    end
  end

  defp do_pretty(list, indent) when is_list(list) do
    if list == [] do
      "[]"
    else
      pad = String.duplicate("  ", indent + 1)
      end_pad = String.duplicate("  ", indent)

      entries =
        Enum.map_join(list, ",\n", fn v ->
          "#{pad}#{do_pretty(v, indent + 1)}"
        end)

      "[\n#{entries}\n#{end_pad}]"
    end
  end

  defp do_pretty(value, _indent), do: encode!(value)
end
