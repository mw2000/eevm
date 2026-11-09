defmodule EEVM.ErrorTest do
  use ExUnit.Case, async: true

  doctest EEVM.Error

  test "every reason catalogued in the moduledoc has a message" do
    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(EEVM.Error)

    reasons =
      ~r/^\| `:([a-z0-9_]+)` \|/m
      |> Regex.scan(moduledoc, capture: :all_but_first)
      |> Enum.map(fn [name] -> String.to_existing_atom(name) end)

    # The tables cover execution, precompile, decoding, transaction, header, and block errors.
    assert length(reasons) > 60

    for reason <- reasons do
      refute EEVM.Error.message(reason) == inspect(reason), "no message for #{inspect(reason)}"
    end
  end

  test "an unknown reason falls back to inspect" do
    assert EEVM.Error.message({:database, :timeout}) == "{:database, :timeout}"
  end
end
