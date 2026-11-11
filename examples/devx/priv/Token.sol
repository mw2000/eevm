// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// A minimal ERC-20 for the eevm examples, with one function per way a call can fail.
contract Token {
    string public name = "Dev Token";
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    address public owner;

    event Transfer(address indexed from, address indexed to, uint256 value);

    error Unauthorized(address caller);

    constructor(uint256 supply) {
        owner = msg.sender;
        balanceOf[msg.sender] = supply;
        totalSupply = supply;
        emit Transfer(address(0), msg.sender, supply);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// Reverts with the custom error Unauthorized(caller) for anyone but the owner.
    function mint(uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        balanceOf[msg.sender] += amount;
        totalSupply += amount;
    }

    /// Runs until it is out of gas.
    function burnGas() external {
        while (true) {
            totalSupply += 1;
        }
    }

    /// Divides by zero: Panic(0x12).
    function divide(uint256 a, uint256 b) external pure returns (uint256) {
        return a / b;
    }
}
