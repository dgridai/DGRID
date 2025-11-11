// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import {
    MessageHashUtils
} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ChainlinkPriceFeed} from "./ChainlinkPriceFeed.sol";
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
import {IDgridNode} from "./Interfaces/IDgridNode.sol";

contract Dgrid is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for ERC20;

    address public server;
    address public dev;
    IDgridNode public dgridNode;
    ChainlinkPriceFeed public priceFeed;

    uint256 public NODE_ID;
    uint256 public commissionRate;
    uint256 public gasAmountPerNode;

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
    event Pause(address operator, bool paused);
    event Unpause(address operator, bool unpaused);
    event EmergencyWithdraw(address to, address token, uint256 amount);
    event SetServer(address server);
    event SetDev(address dev);
    event SetPriceFeed(address priceFeed);
    event SetAssets(address[] assets);
    event SetNodePrice(uint256 nodePrice);
    event SetGasAmountPerNode(uint256 gasAmountPerNode);

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
        uint256 _gasAmountPerNode
    ) public initializer {
        //check params
        require(_owner != address(0), "owner is zero address");
        require(_server != address(0), "server is zero address");
        require(_dev != address(0), "dev is zero address");
        require(_priceFeed != address(0), "price feed is zero address");
        require(
            _dgridNodeProxy != address(0),
            "dgrid node proxy is zero address"
        );
        require(_nodePrice > 0, "node price is zero");
        require(_gasAmountPerNode > 0, "gas amount per node is zero");

        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        server = _server;
        dev = _dev;
        priceFeed = ChainlinkPriceFeed(_priceFeed);
        commissionRate = _commissionRate;
        nodePrice = _nodePrice;
        for (uint256 i = 0; i < _assets.length; i++) {
            require(_assets[i] != address(0), "asset is zero address");
            ERC20 token = ERC20(_assets[i]);
            assetInfos[_assets[i]] = Asset({
                token: address(token),
                decimals: token.decimals()
            });
            assetList.push(_assets[i]);
        }
        dgridNode = IDgridNode(_dgridNodeProxy);
        _initNodeNodeId();
        gasAmountPerNode = _gasAmountPerNode;
    }

    function buyNode(
        uint256 orderId,
        address user,
        address parent,
        uint256 nodeCount,
        uint256 expireTime,
        bytes calldata signature,
        address asset
    ) public nonReentrant whenNotPaused {
        require(!fulfilledOrders[orderId], "Order already fulfilled");
        require(assetInfos[asset].token != address(0), "Invalid asset");
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
        fulfilledOrders[orderId] = true;
        uint256 paymentAmount = calculatePaymentAmount(nodeCount);
        uint256 gasAmount = calculateGasAmount(nodeCount);
        uint256 payValue = 0;
        uint256 commissionAmount;

        // pay with erc20 asset
        uint256 paymentAmountInAsset = (paymentAmount *
            (10 ** assetInfos[asset].decimals)) / 1e18;
        uint256 gasAmountInAsset = (gasAmount *
            (10 ** assetInfos[asset].decimals)) / 1e18;
        uint256 totalAmountInAsset = paymentAmountInAsset + gasAmountInAsset;
        uint256 allowance = ERC20(asset).allowance(msg.sender, address(this));
        require(
            allowance >= totalAmountInAsset,
            "Buy Node: Insufficient allowance"
        );
        payValue = totalAmountInAsset;
        if (parent != address(0)) {
            commissionAmount = (paymentAmountInAsset * commissionRate) / 100;
            commission[parent][asset] += commissionAmount;
        }
        _safeTransferFrom(asset, msg.sender, address(this), totalAmountInAsset);
        //transfer asset to dev
        _safeTransfer(asset, dev, totalAmountInAsset - commissionAmount);

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
        require(_user != address(0), "Invalid user");
        require(_assets.length > 0, "Invalid assets");
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

    function calculateGasAmount(
        uint256 nodeCount
    ) public view returns (uint256) {
        require(gasAmountPerNode > 0, "Gas amount not set");
        return gasAmountPerNode * nodeCount * 1e18;
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
        require(_server != address(0), "Invalid server");
        server = _server;
        emit SetServer(_server);
    }

    function setDev(address _dev) public onlyOwner {
        require(_dev != address(0), "Invalid dev");
        dev = _dev;
        emit SetDev(_dev);
    }

    function setPriceFeed(address _priceFeed) public onlyOwner {
        require(_priceFeed != address(0), "Invalid price feed");
        priceFeed = ChainlinkPriceFeed(_priceFeed);
        emit SetPriceFeed(_priceFeed);
    }

    function setAssets(address[] memory _assets) public onlyOwner {
        for (uint256 i = 0; i < _assets.length; i++) {
            require(_assets[i] != address(0), "Invalid asset");
            assetInfos[_assets[i]] = Asset({
                token: _assets[i],
                decimals: ERC20(_assets[i]).decimals()
            });

            // remove duplicate assets
            bool exists = false;
            for (uint256 j = 0; j < assetList.length; j++) {
                if (assetList[j] == _assets[i]) {
                    exists = true;
                    break;
                }
            }
            if (!exists) assetList.push(_assets[i]);
        }
        emit SetAssets(_assets);
    }

    function setNodePrice(uint256 _nodePrice) public onlyOwner {
        require(_nodePrice > 0, "Invalid node price");
        nodePrice = _nodePrice;
        emit SetNodePrice(_nodePrice);
    }

    function setGasAmountPerNode(uint256 _gasAmountPerNode) public onlyOwner {
        require(_gasAmountPerNode > 0, "Invalid gas amount per node");
        gasAmountPerNode = _gasAmountPerNode;
        emit SetGasAmountPerNode(_gasAmountPerNode);
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
