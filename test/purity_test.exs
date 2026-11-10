defmodule EEVM.PurityTest do
  # eevm's core is pure functions over explicit state, written so it could in
  # theory run on bare metal (#150). For every module compiled from lib/,
  # this reads the import table (remote calls) and the external function
  # references in its debug info (`&Mod.fun/arity` captures, which the import
  # table leaves out), and fails on any into OS or VM services. A text search
  # misses calls behind aliases, imports, and macros; these don't.
  # test/support (the conformance harness and Mix tasks) and bench/ are edges
  # and aren't scanned. Logger is allowed, but only at the edges (AGENTS.md).
  use ExUnit.Case, async: true

  # Calls into any function of these modules.
  @banned_modules [
    # Storage outside the explicit state
    :ets,
    :dets,
    :persistent_term,
    :atomics,
    :counters,
    # Processes and messaging
    Process,
    Task,
    Agent,
    GenServer,
    Supervisor,
    Registry,
    :proc_lib,
    :gen_server,
    # Configuration, files, the OS, clocks, randomness
    Application,
    :application,
    File,
    :file,
    :prim_file,
    :os,
    System,
    Port,
    Node,
    :timer,
    :rand,
    # The code server
    Code,
    :code,
    # Native code and OpenSSL
    :crypto,
    :public_key,
    EEVM.Precompiles.Bls12381.Nif
  ]

  # :erlang BIFs with the same effects: the process dictionary, processes and
  # messages, clocks, run-time atom creation, code-server queries, and NIFs.
  @banned_bifs [
    put: 2,
    get: 0,
    get: 1,
    erase: 0,
    erase: 1,
    spawn: 1,
    spawn: 3,
    spawn_link: 1,
    spawn_link: 3,
    spawn_monitor: 1,
    spawn_monitor: 3,
    spawn_opt: 2,
    spawn_opt: 4,
    send: 2,
    send: 3,
    self: 0,
    monitor: 2,
    open_port: 2,
    monotonic_time: 0,
    monotonic_time: 1,
    system_time: 0,
    system_time: 1,
    timestamp: 0,
    binary_to_atom: 1,
    binary_to_atom: 2,
    list_to_atom: 1,
    function_exported: 3,
    load_nif: 2,
    nif_error: 1
  ]

  # Known uses, each with the issue that removes it. The test also fails on
  # an entry nothing needs any more, so this list only shrinks.
  @allowed %{
    # The deprecated pre-1.0 backend shim recognises old modules (#204)
    {EEVM.Database.Legacy, Code} => 204,
    {EEVM.Database.Legacy, :erlang} => 204
  }

  test "lib/ calls no OS or VM services outside the allowlist" do
    used = MapSet.new(violations(), fn {caller, target, _call} -> {caller, target} end)
    allowed = @allowed |> Map.keys() |> MapSet.new()

    unexpected =
      for {caller, target, call} <- violations(),
          {caller, target} not in allowed,
          do: {caller, call}

    stale = allowed |> MapSet.difference(used) |> Enum.sort()

    assert unexpected == [], """
    lib/ must stay pure: no ETS, processes, process dictionary, files, OS,
    clocks, code server, run-time atoms, NIFs, or :crypto. Move the effect to
    an edge (a Database adapter, a Mix task) or pass the state explicitly.
    Unexpected calls: #{inspect(unexpected, pretty: true)}
    """

    assert stale == [], "Remove these @allowed entries; nothing needs them: #{inspect(stale)}"
  end

  # :crypto leaves extra_applications together with its last caller (#207).
  test ":crypto is in extra_applications exactly while lib/ calls it" do
    calls_crypto? = Enum.any?(violations(), &match?({_caller, :crypto, _call}, &1))
    assert :crypto in Application.spec(:eevm, :applications) == calls_crypto?
  end

  defp violations do
    for module <- lib_modules(),
        {target, fun, arity} = call <- imports(module) ++ fun_refs(module),
        banned?(target, fun, arity),
        uniq: true,
        do: {module, target, call}
  end

  defp banned?(:erlang, fun, arity), do: {fun, arity} in @banned_bifs
  defp banned?(module, _fun, _arity), do: module in @banned_modules

  defp lib_modules do
    lib = Path.expand("../lib", __DIR__)

    for module <- Application.spec(:eevm, :modules),
        source = module.module_info(:compile)[:source],
        String.starts_with?(List.to_string(source), lib),
        do: module
  end

  defp imports(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    imports
  end

  defp fun_refs(module) do
    {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(:code.which(module), [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])
    collect_fun_refs(forms, [])
  end

  defp collect_fun_refs(
         {:fun, _, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}},
         acc
       ),
       do: [{m, f, a} | acc]

  defp collect_fun_refs(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> collect_fun_refs(acc)

  defp collect_fun_refs(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_fun_refs/2)

  defp collect_fun_refs(_other, acc), do: acc
end
