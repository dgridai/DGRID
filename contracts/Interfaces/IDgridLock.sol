// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface IDgridLock is IERC721 {
    function withdraw(address _token, address _to, uint256 _amount) external;
}
