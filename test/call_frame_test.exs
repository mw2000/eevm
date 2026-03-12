defmodule EEVM.CallFrameTest do
  use ExUnit.Case, async: true

  alias EEVM.{CallFrame, Executor, MachineState, Memory, Stack}
  alias EEVM.Context.Contract

  test "push_frame stores parent frame and switches execution context" do
    parent_state = MachineState.new(<<0x00>>, contract: Contract.new(address: 1), gas: 1000)

    child_frame = %CallFrame{
      code: <<0x60, 1, 0x00>>,
      pc: 0,
      stack: Stack.new(),
      memory: Memory.new(),
      gas: 300,
      contract: Contract.new(address: 2, caller: 1),
      return_offset: 10,
      return_size: 4,
      is_static: false,
      depth: 1
    }

    {:ok, state_after_push} = MachineState.push_frame(parent_state, child_frame)

    assert state_after_push.code == child_frame.code
    assert state_after_push.contract.address == 2
    assert length(state_after_push.call_stack) == 1
    assert MachineState.current_depth(state_after_push) == 1
  end

  test "push_frame enforces max call depth of 1024" do
    state = MachineState.new(<<0x00>>, depth: 1024)

    frame = %CallFrame{
      code: <<0x00>>,
      stack: Stack.new(),
      memory: Memory.new(),
      contract: Contract.new()
    }

    assert {:error, :max_call_depth, _} = MachineState.push_frame(state, frame)
  end

  test "pop_frame restores parent and writes return data into parent memory" do
    parent_state = MachineState.new(<<0x00>>, contract: Contract.new(address: 1), gas: 700)

    child_frame = %CallFrame{
      code: <<0x00>>,
      stack: Stack.new(),
      memory: Memory.new(),
      gas: 250,
      contract: Contract.new(address: 2, caller: 1),
      return_offset: 4,
      return_size: 4,
      depth: 1
    }

    {:ok, state_after_push} = MachineState.push_frame(parent_state, child_frame)
    child_finished = %{state_after_push | status: :stopped, return_data: <<0xAA, 0xBB>>}

    {:ok, resumed_state} = MachineState.pop_frame(child_finished)
    {bytes, _} = Memory.read_bytes(resumed_state.memory, 4, 4)

    assert resumed_state.contract.address == 1
    assert resumed_state.status == :running
    assert resumed_state.gas == 950
    assert bytes == <<0xAA, 0xBB, 0x00, 0x00>>
  end

  test "run_loop pops halted child frame and resumes parent" do
    parent_state = MachineState.new(<<0x00>>, contract: Contract.new(address: 10), gas: 900)

    child_frame = %CallFrame{
      code: <<0x00>>,
      stack: Stack.new(),
      memory: Memory.new(),
      gas: 100,
      contract: Contract.new(address: 11, caller: 10),
      return_offset: 0,
      return_size: 0,
      depth: 1
    }

    {:ok, state_after_push} = MachineState.push_frame(parent_state, child_frame)
    child_halted = %{state_after_push | status: :stopped}

    result = Executor.run_loop(child_halted)

    assert result.status == :stopped
    assert result.contract.address == 10
    assert result.call_stack == []
  end
end
