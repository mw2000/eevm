defmodule Devx.Errors do
  @moduledoc """
  Task 7: handle errors. A call or transaction that executes but fails
  reports it in `status` (`:revert`, `{:halt, reason}`), with the revert
  payload decoded by `EEVM.revert_reason/1`. A transaction that fails
  validation returns `{:error, reason}` before executing.
  """

  alias EEVM.Transaction.{FeeMarket, Signer}

  @doc "Calls `signature` on `token` with `args` from `from`; returns `{status, revert_reason, gas_used}`."
  def call(db, token, from, signature, args, opts \\ []) do
    calldata = EEVM.ABI.encode_call(signature, args)
    {:ok, result} = EEVM.call(db, token, calldata, Keyword.merge([caller: from], opts))
    {result.status, EEVM.revert_reason(result), result.gas_used}
  end

  @doc "Sends `signature(args)` to `to` as a signed EIP-1559 transaction from `Devx.sender/0`."
  def transact(db, to, signature, args, overrides \\ [], opts \\ []) do
    tx =
      struct!(
        %FeeMarket{
          max_fee_per_gas: 3 * Devx.gwei(),
          max_priority_fee_per_gas: Devx.gwei(),
          gas_limit: 100_000,
          to: to,
          data: EEVM.ABI.encode_call(signature, args)
        },
        overrides
      )

    {:ok, signed} = Signer.sign(tx, Devx.private_key(), Devx.config())

    case EEVM.transact(signed, Devx.block_env(), db, [config: Devx.config()] ++ opts) do
      {:ok, result} -> {:ok, result.status, EEVM.revert_reason(result), result.receipt.status}
      {:error, reason} -> {:error, reason, EEVM.Error.message(reason)}
    end
  end

  @doc """
  Like `transact/5`, with `details: true`: a rejection comes back as an
  `EEVM.TransactionError` carrying the values the rule compared, returned
  here as `{:error, reason, details, message}`.
  """
  def transact_with_details(db, to, signature, args, overrides) do
    case transact(db, to, signature, args, overrides, details: true) do
      {:error, %EEVM.TransactionError{} = error, _message} ->
        {:error, error.reason, error.details, Exception.message(error)}

      other ->
        other
    end
  end

  @doc "Submits raw bytes as a transaction."
  def transact_raw(db, bytes) do
    case EEVM.transact(bytes, Devx.block_env(), db, config: Devx.config()) do
      {:ok, result} -> {:ok, result.status}
      {:error, reason} -> {:error, reason, EEVM.Error.message(reason)}
    end
  end
end
