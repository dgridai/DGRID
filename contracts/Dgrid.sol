// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ChainlinkPriceFeed} from "./ChainlinkPriceFeed.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {DgridNode} from "./DgridNode.sol";

contract Dgrid is
    Initializable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    uint256 public constant NODE_ID = 1;
    address public server;
    address public dev;
    DgridNode public dgridNode;
    ChainlinkPriceFeed public priceFeed;
    uint256 public commissionRate;
    mapping(address => mapping(address => uint256)) public commission;
    mapping(address => Asset) public assetInfos;
    mapping(uint256 => bool) public fulfilledOrders;
    address[] public assetList;
    uint256[] public priceSteps; // price steps, e.g. [600, 550, 500]
    uint256[] public stepRanges; // step ranges, e.g. [9, 49, type(uint256).max]

    constructor() {
        _disableInitializers();
    }

    struct Asset {
        address token;
        uint8 decimals;
    }

    event BuyNode(
        uint256 indexed orderId,
        address user,
        address parent,
        uint256 nodeCount,
        address asset,
        uint256 payValue,
        uint256 commissionAmount
    );
    event ClaimCommission(
        address indexed user,
        address[] assets,
        uint256[] amounts
    );

    function _initPriceSteps(
        uint256[] memory _priceSteps,
        uint256[] memory _stepRanges
    ) internal {
        if (_priceSteps.length > 0) {
            priceSteps = _priceSteps;
            stepRanges = _stepRanges;
        } else {
            priceSteps = [600, 550, 500];
            stepRanges = [9, 49, type(uint256).max];
        }
    }

    function initialize(
        address _owner,
        address _server,
        address _dev,
        address _priceFeed,
        address _dgridNodeProxy,
        uint256 _commissionRate,
        address[] memory _assets,
        uint256[] memory _priceSteps,
        uint256[] memory _stepRanges
    ) public initializer {
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        server = _server;
        dev = _dev;
        priceFeed = ChainlinkPriceFeed(_priceFeed);
        commissionRate = _commissionRate;
        for (uint256 i = 0; i < _assets.length; i++) {
            ERC20 token = ERC20(_assets[i]);
            assetInfos[_assets[i]] = Asset({
                token: address(token),
                decimals: token.decimals()
            });
            assetList.push(_assets[i]);
        }
        dgridNode = DgridNode(_dgridNodeProxy);
        _initPriceSteps(_priceSteps, _stepRanges);
    }

    function buyNode(
        uint256 orderId,
        address user,
        address parent,
        uint256 nodeCount,
        uint256 expireTime,
        bytes calldata signature,
        address asset
    ) public payable nonReentrant {
        require(!fulfilledOrders[orderId], "Order already fulfilled");
        require(
            asset == address(0) || assetInfos[asset].token != address(0),
            "Invalid asset"
        );
        require(
            expireTime > block.timestamp,
            "ExpirationTime must be greater than current timestamp"
        );

        // get the eth signed message hash
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(
            abi.encode(
                block.chainid,
                orderId,
                user,
                parent,
                nodeCount,
                expireTime
            )
        );
        // recover the signer address from the signature
        address signer = ECDSA.recover(ethSignedMessageHash, signature);
        // check if the signer is the authorized server address
        require(signer == server, "Invalid Signature");
        fulfilledOrders[orderId] = true;
        uint256 paymentAmount = calculatePaymentAmount(nodeCount);
        uint256 payValue = 0;
        uint256 commissionAmount;
        if (asset == address(0)) {
            // pay with bnb
            uint256 bnbPrice = priceFeed.fetchPrice(address(0));
            uint256 paymentAmountInBnb = (paymentAmount * 1e18) / bnbPrice;
            require(
                msg.value >= paymentAmountInBnb,
                "Buy Node: Insufficient payment amount"
            );

            payValue = paymentAmountInBnb;
            if (parent != address(0)) {
                commissionAmount = (paymentAmountInBnb * commissionRate) / 100;
                commission[parent][asset] += commissionAmount;
            }
            _safeTransfer(
                address(0),
                dev,
                paymentAmountInBnb - commissionAmount
            ); //transfer bnb to dev

            if (msg.value > paymentAmountInBnb) {
                _safeTransfer(
                    address(0),
                    msg.sender,
                    msg.value - paymentAmountInBnb
                ); //refund bnb to user
            }
        } else {
            // pay with erc20 asset
            uint256 assetPrice = priceFeed.fetchPrice(asset);
            uint256 paymentAmountInAsset = (paymentAmount *
                10 ** assetInfos[asset].decimals) / assetPrice;
            uint256 allowance = ERC20(asset).allowance(
                msg.sender,
                address(this)
            );
            require(
                allowance >= paymentAmountInAsset,
                "Buy Node: Insufficient allowance"
            );
            payValue = paymentAmountInAsset;
            if (parent != address(0)) {
                commissionAmount =
                    (paymentAmountInAsset * commissionRate) /
                    100;
                commission[parent][asset] += commissionAmount;
            }
            _safeTransferFrom(
                asset,
                msg.sender,
                address(this),
                paymentAmountInAsset
            );
            _safeTransfer(asset, dev, paymentAmountInAsset - commissionAmount);
        }

        //mint dgrid node nft
        dgridNode.mint(user, NODE_ID, nodeCount, "");
        emit BuyNode(
            orderId,
            user,
            parent,
            nodeCount,
            asset,
            payValue,
            commissionAmount
        );
    }

    function claimCommission(
        address user
    )
        public
        nonReentrant
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = new address[](assetList.length + 1); // +1 for native token
        amounts = new uint256[](assetList.length + 1); // +1 for native token
        for (uint256 i = 0; i < assetList.length; i++) {
            address asset = assetList[i];
            uint256 commissionAmount = commission[user][asset];
            assets[i] = asset;
            amounts[i] = commissionAmount;
            commission[user][asset] = 0;
            if (commissionAmount > 0) {
                // transfer asset to user
                _safeTransfer(asset, user, commissionAmount);
            }
        }
        assets[assetList.length] = address(0);
        amounts[assetList.length] = commission[user][address(0)];
        commission[user][address(0)] = 0;
        if (amounts[assetList.length] > 0) {
            _safeTransfer(address(0), user, amounts[assetList.length]);
        }
        emit ClaimCommission(user, assets, amounts);
    }

    function getCommission(
        address user
    ) public view returns (address[] memory assets, uint256[] memory amounts) {
        assets = new address[](assetList.length + 1); // +1 for native token
        amounts = new uint256[](assetList.length + 1); // +1 for native token
        for (uint256 i = 0; i < assetList.length; i++) {
            assets[i] = assetList[i];
            amounts[i] = commission[user][assetList[i]];
        }
        assets[assetList.length] = address(0);
        amounts[assetList.length] = commission[user][address(0)];
        return (assets, amounts);
    }

    function calculatePaymentAmount(
        uint256 nodeCount
    ) public view returns (uint256) {
        require(priceSteps.length > 0, "Price steps not set");
        uint256 price = 0;
        for (uint256 i = 0; i < priceSteps.length; i++) {
            if (nodeCount <= stepRanges[i]) {
                price = priceSteps[i];
                break;
            }
        }
        require(price > 0, "No price for this nodeCount");
        return price * nodeCount * 1e18;
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

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        (bool success, ) = address(token).call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                from,
                to,
                value
            )
        );
        require(success, "Transfer failed");
    }

    function setCommissionRate(uint256 _commissionRate) public onlyOwner {
        commissionRate = _commissionRate;
    }

    function setServer(address _server) public onlyOwner {
        server = _server;
    }

    function setDev(address _dev) public onlyOwner {
        dev = _dev;
    }

    function setPriceFeed(address _priceFeed) public onlyOwner {
        priceFeed = ChainlinkPriceFeed(_priceFeed);
    }

    function setPriceSteps(
        uint256[] memory _ranges,
        uint256[] memory _prices
    ) public onlyOwner {
        require(_ranges.length == _prices.length, "Length mismatch");
        stepRanges = _ranges;
        priceSteps = _prices;
    }
}
