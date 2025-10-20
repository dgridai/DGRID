// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract DgridNode is Initializable, ERC721Upgradeable, OwnableUpgradeable {
    bool public publicTransferEnabled;
    address public dgrid;
    address public dgridStakePool;

    mapping(uint256 => bool) public isStaked;
    mapping(uint256 => bool) public isJailed;

    event Mint(address to, uint256 id);
    event Stake(uint256[] tokenIds);
    event Unstake(uint256[] tokenIds);
    event Jail(uint256[] tokenIds);
    event Unjail(uint256[] tokenIds);

    modifier onlyDgridStakePool() {
        require(
            msg.sender == dgridStakePool,
            "Only DgridStakePool can call this function"
        );
        _;
    }

    constructor() {
        _disableInitializers();
    }

    modifier onlyDgrid() {
        require(msg.sender == dgrid, "Only Dgrid can call this function");
        _;
    }

    function initialize(
        address owner,
        address _dgrid,
        address _dgridStakePool
    ) public initializer {
        __ERC721_init("Dgrid Node", "DGN");
        __Ownable_init(owner);
        publicTransferEnabled = false;
        dgrid = _dgrid;
        dgridStakePool = _dgridStakePool;
    }

    // only owner can mint
    function mint(address to, uint256 id) external onlyDgrid {
        _mint(to, id);
        emit Mint(to, id);
    }

    //when transfer, check public transfer enabled or not
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && !publicTransferEnabled) {
            revert("Transfer is not enabled");
        }
        if (isStaked[tokenId] || isJailed[tokenId]) {
            revert("Node is staked or jailed");
        }
        return super._update(to, tokenId, auth);
    }

    function stake(uint256[] memory tokenIds) external onlyDgridStakePool {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(!isStaked[tokenIds[i]], "Node is already staked");
            isStaked[tokenIds[i]] = true;
        }
        emit Stake(tokenIds);
    }

    function unstake(uint256[] memory tokenIds) external onlyDgridStakePool {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(isStaked[tokenIds[i]], "Node is not staked");
            require(!isJailed[tokenIds[i]], "Node is jailed");
            isStaked[tokenIds[i]] = false;
        }
        emit Unstake(tokenIds);
    }

    function jail(uint256[] memory tokenIds) external onlyDgridStakePool {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(isStaked[tokenIds[i]], "Node is not staked");
            require(!isJailed[tokenIds[i]], "Node is already jailed");
            isJailed[tokenIds[i]] = true;
        }
        emit Jail(tokenIds);
    }

    function unjail(uint256[] memory tokenIds) external onlyDgridStakePool {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(isStaked[tokenIds[i]], "Node is not staked");
            require(isJailed[tokenIds[i]], "Node is already jailed");
            isJailed[tokenIds[i]] = false;
        }
        emit Unjail(tokenIds);
    }

    function isOwner(
        uint256[] memory tokenIds,
        address account
    ) external view returns (bool) {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (_ownerOf(tokenIds[i]) != account) {
                return false;
            }
        }
        return true;
    }

    function setDgridStakePool(address _pool) external onlyOwner {
        dgridStakePool = _pool;
    }

    function setDgrid(address _dgrid) external onlyOwner {
        dgrid = _dgrid;
    }

    function setPublicTransferEnabled(bool enabled) external onlyOwner {
        publicTransferEnabled = enabled;
    }
}
