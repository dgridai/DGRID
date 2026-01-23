// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract tDGAI is Ownable, ERC20 {
    uint256 public cap;

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 cap_, // cap
        uint256 initialSupply_, // initial supply
        address owner_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        require(cap_ > 0, "cap=0");
        cap = cap_;
        require(initialSupply_ <= cap, "initial > cap");
        _mint(owner_, initialSupply_);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= cap, "cap exceeded");
        _mint(to, amount);
    }
}
