// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DgridLock is Initializable, OwnableUpgradeable {
    address public dgrid;
    address public operator;
    address[] public assets;

    address public dexRouter; // Pancake/UniswapV2 Router
    address public dgridToken; // DGRID
    address public wNative; // WBNB

    event SetDexRouter(address indexed router);
    event SetDgridToken(address indexed dgrid);
    event SetWNative(address indexed w);
    event SwapAndBurn();

    constructor() {
        _disableInitializers();
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "Only operator can call this function");
        _;
    }

    function initialize(
        address _owner,
        address _dgrid,
        address _operator,
        address[] memory _assets
    ) public initializer {
        __Ownable_init(_owner);
        dgrid = _dgrid;
        operator = _operator;
        for (uint256 i = 0; i < _assets.length; i++) {
            assets.push(_assets[i]);
        }
    }

    function withdraw(
        address _token,
        address _to,
        uint256 _amount
    ) public onlyOperator {
        if (_token == address(0)) {
            (bool success, ) = _to.call{value: _amount}("");
            require(success, "Native token transfer failed");
        } else {
            (bool success, ) = address(_token).call(
                abi.encodeWithSignature(
                    "transfer(address,uint256)",
                    _to,
                    _amount
                )
            );
            require(success, "Transfer failed");
        }
    }

    function swapAndBurn() public onlyOperator {
        //todo : Subsequent versions will be upgraded to: traverse assets/native tokens -> exchange to dgridToken via dexRouter -> transfer to zero address
        emit SwapAndBurn();
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        if (token == address(0)) {
            (bool success, ) = to.call{value: value}("");
            require(success, "Native token transfer failed");
        } else {
            (bool success, ) = address(token).call(
                abi.encodeWithSignature("transfer(address,uint256)", to, value)
            );
            require(success, "Transfer failed");
        }
    }

    function setOperator(address _operator) public onlyOwner {
        operator = _operator;
    }

    function setDexRouter(address _router) external onlyOwner {
        dexRouter = _router;
        emit SetDexRouter(_router);
    }

    function setDgridToken(address _dgrid) external onlyOwner {
        dgridToken = _dgrid;
        emit SetDgridToken(_dgrid);
    }

    function setWNative(address _w) external onlyOwner {
        wNative = _w;
        emit SetWNative(_w);
    }

    receive() external payable {}
}
