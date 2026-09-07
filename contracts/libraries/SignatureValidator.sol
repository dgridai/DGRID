// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

library SignatureValidator {
    function validatePreStake(
        address server,
        address contractAddress,
        address user,
        uint64 day,
        uint64 nodeId,
        uint256 amount,
        uint256 expireTime,
        uint256 nonce,
        bytes32 actionHash,
        bytes memory signature
    ) external view {
        require(block.timestamp <= expireTime, "signature expired");

        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(
            abi.encode(
                block.chainid,
                contractAddress,
                user,
                day,
                nodeId,
                amount,
                expireTime,
                nonce,
                actionHash
            )
        );
        address signer = ECDSA.recover(hash, signature);
        require(signer == server, "invalid signature");
    }
}
