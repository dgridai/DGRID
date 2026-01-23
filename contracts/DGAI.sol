// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DGAI is Ownable, ERC20 {
    uint256 public maxSupply;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_, // max supply
        uint256 initialSupply_, // initial supply
        address owner_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        require(maxSupply_ > 0, "maxSupply=0");
        maxSupply = maxSupply_;
        require(initialSupply_ <= maxSupply, "initial > maxSupply");
        _mint(owner_, initialSupply_);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= maxSupply, "maxSupply exceeded");
        _mint(to, amount);
    }
}
