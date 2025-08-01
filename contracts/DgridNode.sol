// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract DgridNode is ERC1155Upgradeable, OwnableUpgradeable {
    bool public publicTransferEnabled;
    address public dgrid;
    mapping(uint256 => uint256) public totalSupply;

    modifier onlyDgrid() {
        require(msg.sender == dgrid, "Only Dgrid can call this function");
        _;
    }

    function initialize(
        address owner,
        address _dgrid,
        string memory uri_
    ) public initializer {
        __ERC1155_init(uri_);
        __Ownable_init(owner);
        publicTransferEnabled = false;
        dgrid = _dgrid;
    }

    // only owner can mint
    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) external onlyDgrid {
        _mint(to, id, amount, data);
        totalSupply[id] += amount;
    }

    // only owner can burn
    function burn(address from, uint256 id, uint256 amount) external onlyOwner {
        _burn(from, id, amount);
        totalSupply[id] -= amount;
    }

    //when transfer, check public transfer enabled or not
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override {
        if (from != address(0) && to != address(0) && publicTransferEnabled) {
            revert("Only owner can transfer");
        }
        super._update(from, to, ids, values);
    }

    function setPublicTransferEnabled(bool enabled) external onlyOwner {
        publicTransferEnabled = enabled;
    }
}
