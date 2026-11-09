defmodule EEVM.Handler.PreExecution do
  @moduledoc """
  Steps 4-7 of the transaction pipeline (Yellow Paper §6):

  - **Charge upfront** — debit `gas_limit * max_price` from the sender, plus
    the EIP-4844 blob gas fee, which is burned and never refunded. The
    `value` portion is *not* debited here; it is moved by `Execution` when
    the call frame is set up so the same wei is not deducted twice.
  - **Intrinsic gas** — verify `tx.gas_limit >= IntrinsicGas.calculate(tx, hardfork)`
    and compute the gas available to the EVM as the difference.
  - **Bump nonce** — increment the sender's nonce.
  - **Apply authorizations** (EIP-7702) — write delegation designators for
    each valid authorization tuple. These writes happen before execution and
    persist even if the call reverts.
  - **Pre-warm access set** — seed `accessed_addresses` and
    `accessed_storage_keys` with EIP-2929 / EIP-3651 entries plus the
    transaction's access list.

  Also exposes `gas_upfront/1` and `effective_gas_price/2` because both
  `PostExecution` settlement and the upfront balance check share the same
  fee-market formula, and `blob_gas_fee/2` for runners that settle fees
  themselves.
  """

  alias EEVM.Context.{Block, Contract, Transaction}
  alias EEVM.{Database, Delegation, HardforkConfig, Precompiles}
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
  Debit the maximum gas fee from the sender after checking that the balance
  also covers `tx.value` and that the effective gas price meets the basefee.
  """
  @spec charge_upfront(Database.t(), Transaction.t(), Block.t()) ::
          {:ok, Database.t()} | {:error, atom()}
  def charge_upfront(%Database{} = db, %Transaction{} = tx, %Block{} = block) do
    sender_balance = Database.get_balance(db, tx.origin)
    gas_charge = gas_upfront(tx) + blob_gas_fee(tx, block)

    cond do
      sender_balance < gas_charge + tx.value ->
        {:error, :insufficient_balance}

      effective_gas_price(tx, block) < block.basefee ->
        {:error, :effective_gas_price_below_basefee}

      true ->
        debited = Database.set_balance(db, tx.origin, sender_balance - gas_charge)
        {:ok, debited}
    end
  end

  @doc """
  Verify intrinsic gas, bump the sender nonce, and return the gas available
  to the EVM.
  """
  @spec prepare_execution(Database.t(), Transaction.t(), HardforkConfig.t()) ::
          {:ok, Database.t(), non_neg_integer()} | {:error, :intrinsic_gas_too_low}
  def prepare_execution(%Database{} = db, %Transaction{} = tx, %HardforkConfig{} = hardfork) do
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
  @spec apply_authorizations(Database.t(), Transaction.t(), non_neg_integer()) ::
          {Database.t(), authorization_outcome()}
  def apply_authorizations(%Database{} = db, %Transaction{} = tx, chain_id) do
    Enum.reduce(
      tx.authorization_list,
      {db, %{authorities: MapSet.new(), refund: 0}},
      fn auth, acc -> apply_authorization(auth, chain_id, acc) end
    )
  end

  defp apply_authorization(auth, chain_id, {db, outcome} = acc) do
    with true <- auth.chain_id in [0, chain_id] and auth.nonce < @max_uint64,
         {:ok, authority_bytes} <- Signer.recover_authority(struct!(Authorization, wire(auth))) do
      authority = :binary.decode_unsigned(authority_bytes)
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

  defp wire(auth), do: %{auth | address: <<auth.address::unsigned-big-160>>}

  @doc "Maximum gas fee debited upfront: `gas_limit` times the fee cap (or gas price)."
  @spec gas_upfront(Transaction.t()) :: non_neg_integer()
  def gas_upfront(%Transaction{type: type} = tx) when type in [:eip1559, :eip4844, :eip7702] do
    tx.gas_limit * tx.max_fee_per_gas
  end

  def gas_upfront(%Transaction{} = tx), do: tx.gas_limit * tx.gasprice

  @doc """
  EIP-4844 blob gas fee: `GAS_PER_BLOB * blob count * blob_base_fee`. Zero for
  transactions without blobs.

  ## Example

      iex> tx = EEVM.Context.Transaction.new(type: :eip4844, blob_hashes: [1, 2])
      iex> EEVM.Handler.PreExecution.blob_gas_fee(tx, EEVM.Context.Block.new(blob_base_fee: 3))
      786_432
  """
  @spec blob_gas_fee(Transaction.t(), Block.t()) :: non_neg_integer()
  def blob_gas_fee(%Transaction{blob_hashes: hashes}, %Block{blob_base_fee: blob_base_fee}) do
    length(hashes) * Blob.gas_per_blob() * blob_base_fee
  end

  @doc """
  Price per gas the sender pays: `min(max_fee, basefee + priority_fee)` for
  EIP-1559-style transactions (EIP-1559), or the legacy gas price.
  """
  @spec effective_gas_price(Transaction.t(), Block.t()) :: non_neg_integer()
  def effective_gas_price(%Transaction{type: type} = tx, %Block{} = block)
      when type in [:eip1559, :eip4844, :eip7702] do
    min(tx.max_fee_per_gas, block.basefee + tx.max_priority_fee_per_gas)
  end

  def effective_gas_price(%Transaction{} = tx, %Block{}), do: tx.gasprice

  @doc """
  Addresses warm at transaction start (EIP-2929, EIP-2930, EIP-3651): the
  callee, caller, origin, precompiles, access-list entries, and from Shanghai
  the coinbase.
  """
  @spec initial_accessed_addresses(Transaction.t(), EEVM.Config.t(), Contract.t(), Block.t()) ::
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
  @spec initial_accessed_storage_keys(Transaction.t()) ::
          MapSet.t({non_neg_integer(), non_neg_integer()})
  def initial_accessed_storage_keys(tx) do
    Enum.reduce(tx.access_list, MapSet.new(), fn {address, slots}, acc ->
      Enum.reduce(slots, acc, fn slot, inner -> MapSet.put(inner, {address, slot}) end)
    end)
  end
end
