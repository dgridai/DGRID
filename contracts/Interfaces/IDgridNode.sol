// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface IDgridNode is IERC721 {
    function stake(uint256[] memory tokenIds) external;
    function unstake(uint256[] memory tokenIds) external;
    function jail(uint256[] memory tokenIds) external;
    function unjail(uint256[] memory tokenIds) external;
    function isStaked(uint256 tokenId) external view returns (bool);
    function isJailed(uint256 tokenId) external view returns (bool);
    function mint(address to, uint256 id) external;
    function setPublicTransferEnabled(bool enabled) external;
}
