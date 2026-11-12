defmodule EEVM.Handler.PreExecution do
  @moduledoc """
  Steps 4-7 of the transaction pipeline (Yellow Paper §6):

  - **Charge upfront** — check that the sender can afford the maximum fee,
    then debit `gas_limit * effective_price` plus the EIP-4844 blob gas fee,
    which is burned and never refunded. The `value` portion is *not* debited
    here; it is moved by `Execution` when the call frame is set up so the
    same wei is not deducted twice.
  - **Intrinsic gas** — verify `tx.gas_limit >= IntrinsicGas.calculate(tx, hardfork)`
    and compute the gas available to the EVM as the difference.
  - **Bump nonce** — increment the sender's nonce.
  - **Apply authorizations** (EIP-7702) — write delegation designators for
    each valid authorization tuple. These writes happen before execution and
    persist even if the call reverts.
  - **Pre-warm access set** — seed `accessed_addresses` and
    `accessed_storage_keys` with EIP-2929 / EIP-3651 entries plus the
    transaction's access list.

  Also exposes `effective_gas_price/2`, which `PostExecution` settlement
  shares, and `blob_gas_fee/2` for runners that settle fees themselves.
  """

  alias EEVM.{BlockEnv, Config, Database, Delegation, HardforkConfig, Precompiles, TxEnv}
  alias EEVM.Context.Contract
  alias EEVM.Gas.Blob
  alias EEVM.HardforkConfig
  alias EEVM.Transaction.{Authorization, IntrinsicGas, Signer}

  # EIP-7702: refund for an authority that already exists, since the
  # intrinsic charge assumed a new account (25,000 - 12,500).
  @existing_authority_refund 12_500
  @max_uint64 0xFFFFFFFFFFFFFFFF

  @typedoc """
  Result of applying an EIP-7702 authorization list: every authority whose
  signature recovered (warm for the rest of the transaction) and the gas
  refund owed for authorities that already existed.
  """
  @type authorization_outcome :: %{
          authorities: MapSet.t(non_neg_integer()),
          refund: non_neg_integer()
        }

  @doc """
  Debit `gas_limit * effective_gas_price` and the blob gas fee from the
  sender, after checking that the effective gas price meets the basefee and
  that the balance covers the maximum fee plus `tx.value`.

  The maximum fee prices gas at `max_fee_per_gas` (EIP-1559) and blob gas at
  `max_fee_per_blob_gas` (EIP-4844), but only the effective fee is debited,
  so BALANCE of the sender during execution already excludes the unspent
  fee cap (execution-specs `process_transaction`).

  `config`'s `disable_balance_check` and `disable_base_fee` simulation
  switches skip the matching check. With the balance check off, the sender
  keeps at least `tx.value` and pays the gas charge only as far as its
  balance allows, as revm's `CfgEnv` does.
  """
  @spec charge_upfront(Database.t(), TxEnv.t(), BlockEnv.t(), Config.t()) ::
          {:ok, Database.t()} | {:error, atom()}
  def charge_upfront(%Database{} = db, %TxEnv{} = tx, %BlockEnv{} = block, %Config{} = config) do
    sender_balance = Database.get_balance(db, tx.origin)
    effective_price = effective_gas_price(tx, block)
    gas_charge = tx.gas_limit * effective_price + blob_gas_fee(tx, block)

    cond do
      sender_balance < max_fee(tx) + tx.value and not config.disable_balance_check ->
        {:error, :insufficient_balance}

      effective_price < block.base_fee and not config.disable_base_fee ->
        {:error, :effective_gas_price_below_basefee}

      config.disable_balance_check ->
        {:ok, Database.set_balance(db, tx.origin, max(sender_balance - gas_charge, tx.value))}

      true ->
        {:ok, Database.set_balance(db, tx.origin, sender_balance - gas_charge)}
    end
  end

  @doc """
  Verify intrinsic gas, bump the sender nonce, and return the gas available
  to the EVM.
  """
  @spec prepare_execution(Database.t(), TxEnv.t(), HardforkConfig.t()) ::
          {:ok, Database.t(), non_neg_integer()} | {:error, :intrinsic_gas_too_low}
  def prepare_execution(%Database{} = db, %TxEnv{} = tx, %HardforkConfig{} = hardfork) do
    intrinsic = IntrinsicGas.calculate(tx, hardfork)

    if tx.gas_limit < intrinsic do
      {:error, :intrinsic_gas_too_low}
    else
      execution_gas = tx.gas_limit - intrinsic
      db_nonce_bumped = Database.increment_nonce(db, tx.origin)
      {:ok, db_nonce_bumped, execution_gas}
    end
  end

  @doc """
  Apply the EIP-7702 authorization list of `tx` to `db`, after the sender's
  nonce bump and before execution.

  Each tuple is skipped, without failing the transaction, when its chain id
  is neither 0 nor `chain_id`, its nonce is 2^64 - 1, its signature does not
  recover, the authority has code other than a designator, or the
  authority's nonce differs. Otherwise the authority's code becomes a
  designator for `address` (or is cleared when `address` is zero) and its
  nonce is incremented. Tuples apply in order, so a later tuple from the
  same authority sees the earlier one's nonce bump.
  """
  @spec apply_authorizations(Database.t(), TxEnv.t(), non_neg_integer()) ::
          {Database.t(), authorization_outcome()}
  def apply_authorizations(%Database{} = db, %TxEnv{} = tx, chain_id) do
    Enum.reduce(
      tx.authorization_list,
      {db, %{authorities: MapSet.new(), refund: 0}},
      fn auth, acc -> apply_authorization(auth, chain_id, acc) end
    )
  end

  defp apply_authorization(auth, chain_id, {db, outcome} = acc) do
    with true <- auth.chain_id in [0, chain_id] and auth.nonce < @max_uint64,
         {:ok, authority} <- Signer.recover_authority(struct!(Authorization, auth)) do
      outcome = %{outcome | authorities: MapSet.put(outcome.authorities, authority)}
      code = Database.get_code(db, authority)

      if (code == <<>> or Delegation.designator?(code)) and
           Database.get_nonce(db, authority) == auth.nonce do
        refund =
          if Database.account_exists?(db, authority), do: @existing_authority_refund, else: 0

        new_code = if auth.address == 0, do: <<>>, else: Delegation.designator(auth.address)

        db =
          db
          |> Database.put_code(authority, new_code)
          |> Database.increment_nonce(authority)

        {db, %{outcome | refund: outcome.refund + refund}}
      else
        {db, outcome}
      end
    else
      _invalid -> acc
    end
  end

  defp max_fee(%TxEnv{type: type} = tx) when type in [:eip1559, :eip4844, :eip7702] do
    tx.gas_limit * tx.max_fee_per_gas +
      length(tx.blob_hashes) * Blob.gas_per_blob() * tx.max_fee_per_blob_gas
  end

  defp max_fee(%TxEnv{} = tx), do: tx.gas_limit * tx.gas_price

  @doc """
  EIP-4844 blob gas fee: `GAS_PER_BLOB * blob count * blob_base_fee`. Zero for
  transactions without blobs.

  ## Example

      iex> tx = EEVM.TxEnv.new(type: :eip4844, blob_hashes: [1, 2])
      iex> EEVM.Handler.PreExecution.blob_gas_fee(tx, EEVM.BlockEnv.new(blob_base_fee: 3))
      786_432
  """
  @spec blob_gas_fee(TxEnv.t(), BlockEnv.t()) :: non_neg_integer()
  def blob_gas_fee(%TxEnv{blob_hashes: hashes}, %BlockEnv{blob_base_fee: blob_base_fee}) do
    length(hashes) * Blob.gas_per_blob() * blob_base_fee
  end

  @doc """
  Price per gas the sender pays: `min(max_fee, basefee + priority_fee)` for
  EIP-1559-style transactions (EIP-1559), or the legacy gas price.
  """
  @spec effective_gas_price(TxEnv.t(), BlockEnv.t()) :: non_neg_integer()
  def effective_gas_price(%TxEnv{type: type} = tx, %BlockEnv{} = block)
      when type in [:eip1559, :eip4844, :eip7702] do
    min(tx.max_fee_per_gas, block.base_fee + tx.max_priority_fee_per_gas)
  end

  def effective_gas_price(%TxEnv{} = tx, %BlockEnv{}), do: tx.gas_price

  @doc """
  Addresses warm at transaction start (EIP-2929, EIP-2930, EIP-3651): the
  callee, caller, origin, precompiles, access-list entries, and from Shanghai
  the coinbase.
  """
  @spec initial_accessed_addresses(TxEnv.t(), EEVM.Config.t(), Contract.t(), BlockEnv.t()) ::
          MapSet.t(non_neg_integer())
  def initial_accessed_addresses(tx, config, contract_ctx, block) do
    base =
      MapSet.new()
      |> MapSet.put(contract_ctx.address)
      |> MapSet.put(contract_ctx.caller)
      |> MapSet.put(tx.origin)
      |> then(fn set ->
        Enum.reduce(Precompiles.precompile_addresses(config), set, &MapSet.put(&2, &1))
      end)
      # EIP-3651 (Shanghai): COINBASE starts warm.
      |> then(fn set ->
        if HardforkConfig.enabled?(config.hardfork, :eip_3651),
          do: MapSet.put(set, block.coinbase),
          else: set
      end)

    Enum.reduce(tx.access_list, base, fn {address, _slots}, acc ->
      MapSet.put(acc, address)
    end)
  end

  @doc "Storage keys warm at transaction start: every access-list slot (EIP-2930)."
  @spec initial_accessed_storage_keys(TxEnv.t()) ::
          MapSet.t({non_neg_integer(), non_neg_integer()})
  def initial_accessed_storage_keys(tx) do
    Enum.reduce(tx.access_list, MapSet.new(), fn {address, slots}, acc ->
      Enum.reduce(slots, acc, fn slot, inner -> MapSet.put(inner, {address, slot}) end)
    end)
  end
end
