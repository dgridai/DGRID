// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ChainlinkPriceFeed} from "./ChainlinkPriceFeed.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IDgridNode} from "./Interfaces/IDgridNode.sol";

contract Dgrid is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for ERC20;

    address public server;
    address public dev;
    address public dgridLock;
    IDgridNode public dgridNode;
    ChainlinkPriceFeed public priceFeed;

    uint256 public NODE_ID;
    uint256 public commissionRate;
    uint256 public lockAmountPerNode;

    mapping(address => mapping(address => uint256)) public commission;
    mapping(address => Asset) public assetInfos;
    mapping(uint256 => bool) public fulfilledOrders;
    address[] public assetList;
    uint256 public nodePrice;

    bool public paused;

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
        uint256 commissionAmount,
        uint256[] nodeIds
    );
    event ClaimCommission(
        address indexed user,
        address[] assets,
        uint256[] amounts
    );
    event Locked(
        address token,
        uint256 lockAmount,
        uint256 nodeCount,
        address payer
    );
    event Pause(address operator, bool paused);
    event Unpause(address operator, bool unpaused);
    event EmergencyWithdraw(address to, address token, uint256 amount);

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    modifier whenPaused() {
        require(paused, "not paused");
        _;
    }
    function _initNodeNodeId() internal {
        NODE_ID = 1;
    }

    function initialize(
        address _owner,
        address _server,
        address _dev,
        address _priceFeed,
        address _dgridNodeProxy,
        uint256 _commissionRate,
        address[] memory _assets,
        uint256 _nodePrice,
        address _dgridLock,
        uint256 _lockAmountPerNode
    ) public initializer {
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        server = _server;
        dev = _dev;
        priceFeed = ChainlinkPriceFeed(_priceFeed);
        commissionRate = _commissionRate;
        nodePrice = _nodePrice;
        for (uint256 i = 0; i < _assets.length; i++) {
            ERC20 token = ERC20(_assets[i]);
            assetInfos[_assets[i]] = Asset({
                token: address(token),
                decimals: token.decimals()
            });
            assetList.push(_assets[i]);
        }
        dgridNode = IDgridNode(_dgridNodeProxy);
        _initNodeNodeId();
        lockAmountPerNode = _lockAmountPerNode;
        dgridLock = _dgridLock;
    }

    function buyNode(
        uint256 orderId,
        address user,
        address parent,
        uint256 nodeCount,
        uint256 expireTime,
        bytes calldata signature,
        address asset
    ) public payable nonReentrant whenNotPaused {
        require(!fulfilledOrders[orderId], "Order already fulfilled");
        require(
            asset == address(0) || assetInfos[asset].token != address(0),
            "Invalid asset"
        );
        require(
            expireTime > block.timestamp,
            "ExpirationTime must be greater than current timestamp"
        );
        require(nodeCount > 0, "invalid nodeCount");

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
        require(dgridLock != address(0), "dgridLock not set");
        fulfilledOrders[orderId] = true;
        uint256 paymentAmount = calculatePaymentAmount(nodeCount);
        uint256 lockAmount = calculateLockAmount(nodeCount);
        uint256 payValue = 0;
        uint256 commissionAmount;
        if (asset == address(0)) {
            // pay with bnb
            uint256 bnbPrice = priceFeed.fetchPrice(address(0));
            require(bnbPrice > 0, "Invalid bnb price");
            uint256 paymentAmountInBnb = (paymentAmount * 1e18) / bnbPrice;
            uint256 lockAmountInBnb = (lockAmount * 1e18) / bnbPrice;
            require(
                msg.value >= paymentAmountInBnb,
                "Buy Node: Insufficient payment amount"
            );
            payValue = paymentAmountInBnb;
            if (parent != address(0)) {
                commissionAmount = (paymentAmountInBnb * commissionRate) / 100;
                commission[parent][asset] += commissionAmount;
            }
            // check if the payment amount is enough
            require(
                paymentAmountInBnb >= commissionAmount + lockAmountInBnb,
                "lock+commission exceeds payment"
            );

            //transfer bnb to dgrid lock
            _safeTransfer(address(0), dgridLock, lockAmountInBnb);
            _safeTransfer(
                address(0),
                dev,
                paymentAmountInBnb - commissionAmount - lockAmountInBnb
            ); //transfer bnb to dev

            if (msg.value > paymentAmountInBnb) {
                _safeTransfer(
                    address(0),
                    msg.sender,
                    msg.value - paymentAmountInBnb
                ); //refund bnb to user
            }
            emit Locked(address(0), lockAmountInBnb, nodeCount, msg.sender);
        } else {
            // pay with erc20 asset
            uint256 paymentAmountInAsset = (paymentAmount *
                (10 ** assetInfos[asset].decimals)) / 1e18;
            uint256 lockAmountInAsset = (lockAmount *
                (10 ** assetInfos[asset].decimals)) / 1e18;
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
            // check if the payment amount is enough
            require(
                paymentAmountInAsset >= commissionAmount + lockAmountInAsset,
                "lock+commission exceeds payment"
            );
            _safeTransferFrom(
                asset,
                msg.sender,
                address(this),
                paymentAmountInAsset
            );
            //transfer asset to dgrid lock
            _safeTransfer(asset, dgridLock, lockAmountInAsset);
            _safeTransfer(
                asset,
                dev,
                paymentAmountInAsset - commissionAmount - lockAmountInAsset
            );
            emit Locked(asset, lockAmountInAsset, nodeCount, msg.sender);
        }

        uint256[] memory nodeIds = new uint256[](nodeCount);
        for (uint256 i = 0; i < nodeCount; i++) {
            //mint dgrid node nft
            dgridNode.mint(user, NODE_ID);
            nodeIds[i] = NODE_ID;
            NODE_ID++;
        }

        emit BuyNode(
            orderId,
            user,
            parent,
            nodeCount,
            asset,
            payValue,
            commissionAmount,
            nodeIds
        );
    }

    function claimCommission(
        address _user,
        address[] memory _assets
    )
        public
        nonReentrant
        whenNotPaused
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = new address[](_assets.length);
        amounts = new uint256[](_assets.length);
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_assets[i] != address(0)) {
                // check if the asset is valid
                Asset memory assetInfo = assetInfos[_assets[i]];
                require(assetInfo.token != address(0), "Invalid asset");
            }
            uint256 commissionAmount = commission[_user][_assets[i]];
            assets[i] = _assets[i];
            amounts[i] = commissionAmount;
            commission[_user][_assets[i]] = 0;
            if (commissionAmount > 0) {
                _safeTransfer(_assets[i], _user, commissionAmount);
            }
        }
        emit ClaimCommission(_user, assets, amounts);
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
        require(nodePrice > 0, "Node price not set");
        return nodePrice * nodeCount * 1e18;
    }

    function calculateLockAmount(
        uint256 nodeCount
    ) public view returns (uint256) {
        require(lockAmountPerNode > 0, "Lock amount not set");
        return lockAmountPerNode * nodeCount * 1e18;
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        require(to != address(0), "Invalid to address");
        if (token == address(0)) {
            (bool success, ) = to.call{value: value}("");
            require(success, "Native token transfer failed");
        } else {
            ERC20(token).safeTransfer(to, value);
        }
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

    function setCommissionRate(uint256 _commissionRate) public onlyOwner {
        require(_commissionRate <= 100, "Invalid commission rate");
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

    function setAssets(address[] memory _assets) public onlyOwner {
        for (uint256 i = 0; i < _assets.length; i++) {
            assetInfos[_assets[i]] = Asset({
                token: _assets[i],
                decimals: ERC20(_assets[i]).decimals()
            });
        }
    }

    function setNodePrice(uint256 _nodePrice) public onlyOwner {
        nodePrice = _nodePrice;
    }

    function setLockAmountPerNode(uint256 _lockAmountPerNode) public onlyOwner {
        lockAmountPerNode = _lockAmountPerNode;
    }

    function setDgridLock(address _dgridLock) public onlyOwner {
        require(_dgridLock != address(0), "Invalid dgrid lock address");
        dgridLock = _dgridLock;
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
        address to
    ) external onlyOwner whenPaused nonReentrant {
        require(to != address(0), "to is zero address");
        for (uint256 i = 0; i < assetList.length; i++) {
            uint256 balance = ERC20(assetList[i]).balanceOf(address(this));
            if (balance > 0) {
                _safeTransfer(assetList[i], to, balance);
                emit EmergencyWithdraw(to, assetList[i], balance);
            }
        }
        uint256 bnbBalance = address(this).balance;
        if (bnbBalance > 0) {
            _safeTransfer(address(0), to, bnbBalance);
            emit EmergencyWithdraw(to, address(0), bnbBalance);
        }
    }
}
