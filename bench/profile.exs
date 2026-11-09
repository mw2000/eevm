# Profiling target for the interpreter hot path:
#
#     MIX_ENV=prod mix profile.tprof --type time --warmup bench/profile.exs
#
# Runs the arithmetic loop from interpreter_bench.exs (20k iterations, ~1.1M gas).

# tprof evaluates this file without __DIR__, so the path is relative to the repo root.
Code.require_file("bench/support/asm.exs")

alias EEVM.Bench.Asm

[0, 20_000, {:label, :loop}, :dup1, :dup3, :add, 3, :mul, 0xFFFF_FFFF_FFFF, :and, :swap2, :pop]
|> Kernel.++([1, :swap1, :sub, :dup1, {:ref, :loop}, :jumpi, :stop])
|> Asm.assemble()
|> EEVM.Interpreter.run(gas: 1_000_000_000)
