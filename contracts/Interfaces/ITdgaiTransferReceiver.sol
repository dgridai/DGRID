// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITdgaiTransferReceiver {
    function onTdgaiTransfer(
        address from,
        uint256 amount,
        bytes calldata data
    ) external returns (bytes4);
}
