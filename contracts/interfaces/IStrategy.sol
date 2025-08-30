// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategy {

    /// @notice deposit `amount` of want from caller (Vault) into external protocol
    function deposit(uint256 amountWant, bytes[] calldata swapCalldatas) external;


}