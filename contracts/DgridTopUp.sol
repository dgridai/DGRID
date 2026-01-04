// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IDgridPriceFeed} from "./Interfaces/IDgridPriceFeed.sol";
import {ChainlinkPriceFeed} from "./ChainlinkPriceFeed.sol";

contract DgridTopUp is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for ERC20;
    address public dev;
    bool public paused;

    address public tDGAI;
    IDgridPriceFeed public priceFeed;
    ChainlinkPriceFeed public chainLinkPriceFeed;

    address[] public supportedTokens;
    mapping(address => Asset) public supportedTokensInfos;
    mapping(address => uint256) public userTopUpAmount; //user => top up amount(usd)

    struct Asset {
        address token;
        uint8 decimals;
    }

    event TopUp(
        address indexed user,
        address indexed token,
        uint256 tokenAmount,
        uint256 usdAmount
    );
    event Pause(address operator, bool paused);
    event Unpause(address operator, bool unpaused);
    event EmergencyWithdraw(address to, address[] tokens, uint256[] amounts);
    event SetDev(address dev);
    event SetPriceFeed(address priceFeed);
    event SetTDGAI(address tDGAI);
    event AddSupportedToken(address token);
    event SetChainLinkPriceFeed(address chainLinkPriceFeed);

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }
    modifier whenPaused() {
        require(paused, "not paused");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _dev,
        address _chainLinkPriceFeed,
        address[] memory _supportedTokens //not include tDGAI
    ) public initializer {
        //check params
        require(_owner != address(0), "owner is zero address");
        require(_dev != address(0), "dev is zero address");
        require(
            _chainLinkPriceFeed != address(0),
            "chain link price feed is zero address"
        );
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        dev = _dev;
        chainLinkPriceFeed = ChainlinkPriceFeed(_chainLinkPriceFeed);
        for (uint256 i = 0; i < _supportedTokens.length; i++) {
            require(
                _supportedTokens[i] != address(0),
                "supported token is zero address"
            );
            supportedTokensInfos[_supportedTokens[i]] = Asset({
                token: _supportedTokens[i],
                decimals: ERC20(_supportedTokens[i]).decimals()
            });
            supportedTokens.push(_supportedTokens[i]);
        }
    }

    function topUp(
        address user,
        address token,
        uint256 amount
    ) external payable whenNotPaused nonReentrant {
        require(user != address(0), "user is zero address");
        require(amount > 0, "amount is zero");

        uint256 usdAmount = 0;
        // pay with bnb
        if (token == address(0)) {
            require(msg.value == amount, "BNB amount mismatch");
            uint256 bnbPrice = chainLinkPriceFeed.fetchPrice(address(0));
            require(bnbPrice > 0, "Invalid bnb price");
            usdAmount = (msg.value * bnbPrice) / 1e18;
            //transfer bnb to dev
            _safeTransfer(address(0), dev, msg.value);
        } else {
            require(msg.value == 0, "BNB not needed");
            require(
                supportedTokensInfos[token].token != address(0),
                "token not supported"
            );
            // pay with tDGAI
            if (token == tDGAI) {
                require(
                    address(priceFeed) != address(0),
                    "price feed is zero address"
                );
                uint256 price = priceFeed.getTDGAITwapPrice18();
                usdAmount = (amount * price) / 1e18; //usd amount
            } else {
                // pay with stablecoin
                // is stablecoin, 1 usd = 1 stablecoin
                usdAmount = _adjust18Decimals(
                    amount,
                    supportedTokensInfos[token].decimals
                );
            }
            //transfer token to dev
            _safeTransferFrom(token, msg.sender, dev, amount);
        }
        userTopUpAmount[user] += usdAmount;
        emit TopUp(user, token, amount, usdAmount);
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

    function _safeTransfer(address token, address to, uint256 value) internal {
        if (token == address(0)) {
            (bool success, ) = to.call{value: value}("");
            require(success, "Native token transfer failed");
        } else {
            ERC20(token).safeTransfer(to, value);
        }
    }

    function addSupportedToken(address token) public onlyOwner {
        require(token != address(0), "Invalid token");
        require(
            supportedTokensInfos[token].token == address(0),
            "Token already supported"
        );
        supportedTokensInfos[token] = Asset({
            token: token,
            decimals: ERC20(token).decimals()
        });
        supportedTokens.push(token);
        emit AddSupportedToken(token);
    }

    function setDev(address _dev) public onlyOwner {
        require(_dev != address(0), "Invalid dev");
        dev = _dev;
        emit SetDev(_dev);
    }

    function setTDGAI(address _tDGAI) public onlyOwner {
        require(_tDGAI != address(0), "Invalid tDGAI");
        if (supportedTokensInfos[_tDGAI].token == address(0)) {
            supportedTokensInfos[_tDGAI] = Asset({
                token: _tDGAI,
                decimals: ERC20(_tDGAI).decimals()
            });
            supportedTokens.push(_tDGAI);
        }
        tDGAI = _tDGAI;
        emit SetTDGAI(_tDGAI);
    }

    function setTDGridPriceFeed(address _priceFeed) public onlyOwner {
        require(_priceFeed != address(0), "Invalid price feed");
        priceFeed = IDgridPriceFeed(_priceFeed);
        emit SetPriceFeed(_priceFeed);
    }

    function setChainLinkPriceFeed(
        address _chainLinkPriceFeed
    ) public onlyOwner {
        require(
            _chainLinkPriceFeed != address(0),
            "Invalid chain link price feed"
        );
        chainLinkPriceFeed = ChainlinkPriceFeed(_chainLinkPriceFeed);
        emit SetChainLinkPriceFeed(_chainLinkPriceFeed);
    }

    function pause() external onlyOwner whenNotPaused {
        paused = true;
        emit Pause(msg.sender, true);
    }

    function unpause() external onlyOwner whenPaused {
        paused = false;
        emit Unpause(msg.sender, false);
    }

    function emergencyWithdraw(
        address to,
        address[] memory tokens
    ) external onlyOwner whenPaused nonReentrant {
        require(to != address(0), "to is zero address");
        uint256[] memory amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = ERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                ERC20(tokens[i]).safeTransfer(to, balance);
                amounts[i] = balance;
            }
        }
        emit EmergencyWithdraw(to, tokens, amounts);
    }
}
