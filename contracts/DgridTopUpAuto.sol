// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract DgridTopUpAuto is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for ERC20;

    struct Asset {
        address token;
        uint8 decimals;
        bool isSupported;
    }

    mapping(address => Asset) public supportedAutoTokensInfos;
    mapping(address => uint256) public userTopUpAmount; //user => top up amount(usd)
    address[] public supportedAutoTokens;

    address public server;
    address public dev;
    bool public paused;

    event AutoTopUp(
        address indexed user,
        address indexed token,
        uint256 tokenAmount,
        uint256 usdAmount
    );

    event SetServer(address indexed oldServer, address indexed newServer);
    event SetDev(address indexed oldDev, address indexed newDev);
    event IsPaused(bool paused);
    event AddSupportedAutoToken(address indexed token, uint8 decimals);
    event SetSupportedAutoToken(address indexed token, bool isSupported);

    modifier onlyServer() {
        require(msg.sender == server, "not server");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _dev,
        address _server,
        address _usdt
    ) public initializer {
        require(_server != address(0), "server is zero address");
        require(_usdt != address(0), "usdt is zero address");
        require(_dev != address(0), "dev is zero address");
        require(_owner != address(0), "owner is zero address");

        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        dev = _dev;
        paused = false;

        server = _server;
        uint8 decimals = ERC20(_usdt).decimals();
        supportedAutoTokensInfos[_usdt] = Asset({
            token: _usdt,
            decimals: decimals,
            isSupported: true
        });
        supportedAutoTokens.push(_usdt);
        emit AddSupportedAutoToken(_usdt, decimals);
    }

    function autoTopUp(
        address user,
        address token,
        uint256 amount
    ) external onlyServer whenNotPaused nonReentrant {
        require(user != address(0), "user is zero address");
        require(amount > 0, "amount is zero");
        Asset memory asset = supportedAutoTokensInfos[token];
        require(asset.token != address(0), "token not supported");
        require(asset.isSupported, "token not supported");
        _safeTransferFrom(token, user, dev, amount);
        uint256 usdAmount = _adjust18Decimals(amount, asset.decimals);
        userTopUpAmount[user] += usdAmount;
        emit AutoTopUp(user, token, amount, usdAmount);
    }

    function setServer(address _server) external onlyOwner {
        require(_server != address(0), "server is zero address");
        emit SetServer(server, _server);
        server = _server;
    }

    function setDev(address _dev) external onlyOwner {
        require(_dev != address(0), "dev is zero address");
        emit SetDev(dev, _dev);
        dev = _dev;
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        require(from != address(0), "Invalid from address");
        require(to != address(0), "Invalid to address");
        ERC20(token).safeTransferFrom(from, to, value);
    }

    function _adjust18Decimals(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals < 18) {
            return amount * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            return amount / (10 ** (decimals - 18));
        }
        return amount;
    }

    function addSupportedAutoToken(address token) external onlyOwner {
        require(token != address(0), "token is zero address");
        require(
            supportedAutoTokensInfos[token].token == address(0),
            "token is supported"
        );

        uint8 decimals = ERC20(token).decimals();
        supportedAutoTokensInfos[token] = Asset({
            token: token,
            decimals: decimals,
            isSupported: true
        });
        supportedAutoTokens.push(token);
        emit AddSupportedAutoToken(token, decimals);
    }

    function setSupportedAutoToken(
        address token,
        bool isSupported
    ) external onlyOwner {
        require(token != address(0), "token is zero address");
        Asset storage asset = supportedAutoTokensInfos[token];
        require(asset.token != address(0), "token not supported");
        asset.isSupported = isSupported;
        emit SetSupportedAutoToken(token, isSupported);
    }

    function getSupportedAutoTokenLen() external view returns (uint256 len) {
        return supportedAutoTokens.length;
    }

    function getSupportedAutoToken(
        uint256 index
    ) external view returns (address token) {
        return supportedAutoTokens[index];
    }

    function isSupportedAutoToken(
        address token
    ) external view returns (bool isSupported) {
        Asset memory asset = supportedAutoTokensInfos[token];
        return asset.isSupported;
    }

    function pause() external onlyOwner {
        require(!paused, "paused");
        paused = true;
        emit IsPaused(paused);
    }

    function unpause() external onlyOwner {
        require(paused, "not paused");
        paused = false;
        emit IsPaused(paused);
    }
}
