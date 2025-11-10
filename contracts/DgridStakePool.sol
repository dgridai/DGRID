// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    MessageHashUtils
} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "./Interfaces/IDgridNode.sol";

contract DgridStakePool is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for ERC20;

    struct UserInfo {
        uint256 amount; //user staked amount
        uint256[] rewardDebt; //reward debt
        uint256[] unpaidRewards; //unpaid rewards
        uint256[] paidRewards; //paid rewards: rewardIndex => amount
    }

    struct RewardTokenInfo {
        ERC20 rewardToken; //reward token
        uint256 rewardPerBlock; //reward per block
        bool enabled; //enabled
    }

    struct JailInfo {
        address owner;
        uint256[] tokenIds;
    }

    // paused
    bool public paused;

    // server
    address public server;

    // dgrid node
    IDgridNode public dgridNode;

    // configuration
    uint256 public startBlock; //start block
    uint256 public lastRewardBlock; //last reward block

    RewardTokenInfo[] public rewardTokenInfos; //reward token infos
    uint256[] public accPerShares; //acc per shares (expanded ACC_PRECISION)
    uint256 public constant ACC_PRECISION = 1e18;
    uint256 public totalStaked; //total staked amount
    mapping(address => UserInfo) public userInfo; //user -> info
    // mapping(address => uint256[]) public unpaidRewards; //unpaid rewards: user -> [rewardIndex => amount]

    //unstake
    bool public unstakeEnabled;

    //signature action usage
    bytes32 private constant ACTION_DEPOSIT = keccak256("DEPOSIT");
    bytes32 private constant ACTION_UNJAIL = keccak256("UNJAIL");

    event Deposit(address indexed user, uint256[] tokenIds);
    event JailNodes(address indexed user, uint256[] tokenIds);
    event UnjailNodes(address indexed user, uint256[] tokenIds);
    event Harvest(address indexed user, uint256 amount, address rewardToken);
    event UpdateStartBlock(uint256 oldValue, uint256 newValue);
    event UpdateServer(address oldValue, address newValue);
    event UpdateRewardPerBlock(
        address rewardToken,
        uint256 oldValue,
        uint256 newValue
    );
    event UpdateRewardTokenEnabled(
        uint256 rewardTokenIndex,
        address rewardToken,
        bool enabled
    );
    event AccrueUnpaid(
        address indexed user,
        uint256 indexed rewardIndex,
        uint256 amount
    );
    event Pause(address operator, bool paused);
    event Unpause(address operator, bool paused);
    event EmergencyWithdraw(address to, address token, uint256 amount);
    event UpdateUnstakeEnabled(bool unstakeEnabled);
    event Unstake(address indexed user, uint256 amount);

    modifier whenUnstakeEnabled() {
        require(unstakeEnabled, "unstake is not enabled");
        _;
    }

    modifier onlyServer() {
        require(msg.sender == server, "only server can call this function");
        _;
    }

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
        address _server,
        uint256 _startBlock,
        address _dgridNode,
        address[] memory _rewardTokens,
        uint256[] memory _rewardPerBlocks
    ) external initializer {
        //check params
        require(_owner != address(0), "owner is zero address");
        require(_server != address(0), "server is zero address");
        require(_dgridNode != address(0), "dgrid node is zero address");
        require(_rewardTokens.length > 0, "reward tokens is empty");
        require(
            _rewardTokens.length == _rewardPerBlocks.length,
            "length mismatch"
        );
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        server = _server;
        startBlock = _startBlock;
        lastRewardBlock = _startBlock;
        dgridNode = IDgridNode(_dgridNode);
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            require(
                _rewardTokens[i] != address(0),
                "reward token is zero address"
            );
            require(_rewardPerBlocks[i] > 0, "reward per block is zero");
            rewardTokenInfos.push(
                RewardTokenInfo({
                    rewardToken: ERC20(_rewardTokens[i]),
                    rewardPerBlock: _rewardPerBlocks[i],
                    enabled: true
                })
            );
            accPerShares.push(0);
        }
    }

    //add reward token
    function addRewardToken(
        address _rewardToken,
        uint256 _rewardPerBlock
    ) public onlyOwner {
        require(_rewardToken != address(0), "reward token is zero address");
        require(_rewardPerBlock > 0, "reward per block is zero");
        updatePool();
        rewardTokenInfos.push(
            RewardTokenInfo({
                rewardToken: ERC20(_rewardToken),
                rewardPerBlock: _rewardPerBlock,
                enabled: true
            })
        );
        accPerShares.push(0);
    }

    //update pool reward status
    function updatePool() public {
        if (block.number <= lastRewardBlock) {
            return;
        }

        if (totalStaked == 0 || rewardTokenInfos.length == 0) {
            lastRewardBlock = block.number;
            return;
        }

        uint256 blocks = block.number - lastRewardBlock;
        for (uint256 i = 0; i < rewardTokenInfos.length; i++) {
            if (!rewardTokenInfos[i].enabled) {
                continue; //not calculate disabled rewards
            }
            uint256 reward = blocks * rewardTokenInfos[i].rewardPerBlock;
            accPerShares[i] += (reward * ACC_PRECISION) / totalStaked; //calculate acc per shares
        }
        lastRewardBlock = block.number;
    }

    //view user reward info
    function rewardInfo(
        address _user
    )
        external
        view
        returns (
            address[] memory rewardTokens,
            uint256[] memory pendingRewards,
            uint256[] memory paidRewards
        )
    {
        uint256 n = rewardTokenInfos.length;
        rewardTokens = new address[](n);
        pendingRewards = new uint256[](n);
        paidRewards = new uint256[](n);

        if (n == 0) {
            return (rewardTokens, pendingRewards, paidRewards);
        }

        UserInfo storage user = userInfo[_user];
        uint256 blocks = block.number > lastRewardBlock && totalStaked > 0
            ? (block.number - lastRewardBlock)
            : 0;

        for (uint256 i = 0; i < n; i++) {
            uint256 acc = accPerShares[i];
            if (blocks > 0 && rewardTokenInfos[i].enabled) {
                uint256 reward = blocks * rewardTokenInfos[i].rewardPerBlock;
                acc += (reward * ACC_PRECISION) / totalStaked;
            }
            uint256 debt = i < user.rewardDebt.length ? user.rewardDebt[i] : 0;
            uint256 pending = (user.amount * acc) / ACC_PRECISION - debt;
            pendingRewards[i] =
                pending +
                (i < user.unpaidRewards.length ? user.unpaidRewards[i] : 0);
            paidRewards[i] = i < user.paidRewards.length
                ? user.paidRewards[i]
                : 0;
            rewardTokens[i] = address(rewardTokenInfos[i].rewardToken);
        }
        return (rewardTokens, pendingRewards, paidRewards);
    }

    //stake/add
    function deposit(
        uint256[] memory _nodes,
        address _staker,
        uint256 _expireTime,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused {
        require(_staker != address(0), "staker is zero address");
        require(_nodes.length > 0, "nodes is empty");
        for (uint256 i = 0; i < _nodes.length; i++) {
            require(
                dgridNode.ownerOf(_nodes[i]) == _staker,
                "node is not owned by staker"
            );
            require(!dgridNode.isStaked(_nodes[i]), "node is already staked");
            require(!dgridNode.isJailed(_nodes[i]), "node is already jailed");
        }
        require(_expireTime > block.timestamp, "expire time is in the past");

        // server sign check
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(
            abi.encode(
                block.chainid,
                _nodes,
                _staker,
                _expireTime,
                ACTION_DEPOSIT
            )
        );
        address signer = ECDSA.recover(ethSignedMessageHash, _signature);
        require(signer == server, "invalid signature");

        dgridNode.stake(_nodes);

        updatePool();
        _ensureUserInfoLen(_staker);
        _accrueUnpaid(_staker);
        UserInfo storage user = userInfo[_staker];
        user.amount += _nodes.length;
        totalStaked += _nodes.length;
        _resetDebt(_staker);
        emit Deposit(_staker, _nodes);
    }

    function unstake(
        uint256[] memory _nodeIds
    ) external nonReentrant whenUnstakeEnabled whenNotPaused {
        require(block.number >= startBlock, "not started");
        for (uint256 i = 0; i < _nodeIds.length; i++) {
            require(dgridNode.ownerOf(_nodeIds[i]) == msg.sender, "not owner");
            require(!dgridNode.isJailed(_nodeIds[i]), "node is already jailed");
            require(dgridNode.isStaked(_nodeIds[i]), "node is not staked");
        }
        updatePool();
        _ensureUserInfoLen(msg.sender);
        _accrueUnpaid(msg.sender);
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _nodeIds.length, "not enough staked");
        user.amount -= _nodeIds.length;
        totalStaked -= _nodeIds.length;
        _resetDebt(msg.sender);
        dgridNode.unstake(_nodeIds);
        emit Unstake(msg.sender, _nodeIds.length);
    }

    //server: jail nodes
    function jailNodes(
        JailInfo[] memory _jailInfos
    ) external onlyServer nonReentrant whenNotPaused {
        require(_jailInfos.length > 0, "node ids is empty");
        updatePool(); //first update pool

        for (uint256 i = 0; i < _jailInfos.length; i++) {
            JailInfo memory jailInfo = _jailInfos[i];
            if (jailInfo.tokenIds.length == 0) {
                continue;
            }
            for (uint256 j = 0; j < jailInfo.tokenIds.length; j++) {
                uint256 tokenId = jailInfo.tokenIds[j];
                address owner = dgridNode.ownerOf(tokenId);
                require(owner == jailInfo.owner, "node is not owned by staker");
                require(dgridNode.isStaked(tokenId), "node is not staked");
                require(!dgridNode.isJailed(tokenId), "node is already jailed");
            }

            dgridNode.jail(jailInfo.tokenIds); //batch lock
            UserInfo storage user = userInfo[jailInfo.owner];
            require(user.amount > 0, "user is not staked");
            _ensureUserInfoLen(jailInfo.owner);
            _accrueUnpaid(jailInfo.owner);
            user.amount -= jailInfo.tokenIds.length;
            totalStaked -= jailInfo.tokenIds.length;
            _resetDebt(jailInfo.owner);
            emit JailNodes(jailInfo.owner, jailInfo.tokenIds);
        }
    }

    //user: unjail nodes
    function unjailNodes(
        uint256[] memory _nodeIds,
        address _owner,
        uint256 _expireTime,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused {
        require(_owner != address(0), "owner is zero address");
        require(_nodeIds.length > 0, "node ids is empty");
        require(_expireTime > block.timestamp, "expire time is in the past");

        // server sign check
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(
            abi.encode(
                block.chainid,
                _nodeIds,
                _owner,
                _expireTime,
                ACTION_UNJAIL
            )
        );
        address signer = ECDSA.recover(ethSignedMessageHash, _signature);
        require(signer == server, "invalid signature");

        updatePool(); //first update pool
        _ensureUserInfoLen(_owner);
        for (uint256 i = 0; i < _nodeIds.length; i++) {
            uint256 nodeId = _nodeIds[i];
            address owner = dgridNode.ownerOf(nodeId);
            require(owner == _owner, "not owner");
            require(dgridNode.isJailed(nodeId), "node is not jailed");
        }
        _accrueUnpaid(_owner);
        dgridNode.unjail(_nodeIds);
        UserInfo storage user = userInfo[_owner];
        user.amount += _nodeIds.length;
        totalStaked += _nodeIds.length;
        _resetDebt(_owner);
        emit UnjailNodes(_owner, _nodeIds);
    }

    //only harvest rewards (no principal)
    function harvest() external nonReentrant whenNotPaused {
        require(block.number >= startBlock, "not started");
        updatePool();
        _ensureUserInfoLen(msg.sender);
        _payReward(msg.sender);
        _resetDebt(msg.sender);
    }

    //admin: adjust reward per block
    function setRewardPerBlock(
        uint256[] memory _rewardPerBlock
    ) external onlyOwner {
        require(
            _rewardPerBlock.length == rewardTokenInfos.length,
            "length mismatch"
        );
        updatePool();
        for (uint256 i = 0; i < _rewardPerBlock.length; i++) {
            require(_rewardPerBlock[i] > 0, "reward per block is zero");
            emit UpdateRewardPerBlock(
                address(rewardTokenInfos[i].rewardToken),
                rewardTokenInfos[i].rewardPerBlock,
                _rewardPerBlock[i]
            );
            rewardTokenInfos[i].rewardPerBlock = _rewardPerBlock[i];
        }
    }

    //admin: adjust start block
    function setStartBlock(uint256 _startBlock) external onlyOwner {
        require(_startBlock >= block.number, "start < current block");
        require(block.number < startBlock, "already started"); //if already started, can't set start block
        emit UpdateStartBlock(startBlock, _startBlock);
        startBlock = _startBlock;
        lastRewardBlock = _startBlock;
    }

    //admin: set server address
    function setServer(address _server) external onlyOwner {
        require(_server != address(0), "server is zero address");
        address oldServer = server;
        server = _server;
        emit UpdateServer(oldServer, _server);
    }

    function _accrueUnpaid(address _user) internal {
        UserInfo storage user = userInfo[_user];
        if (user.amount == 0) {
            return;
        }
        for (uint256 i = 0; i < rewardTokenInfos.length; i++) {
            uint256 pending = (user.amount * accPerShares[i]) /
                ACC_PRECISION -
                user.rewardDebt[i];
            if (pending > 0) {
                user.unpaidRewards[i] += pending;
                emit AccrueUnpaid(_user, i, pending);
            }
        }
    }

    function _payReward(address _user) internal {
        UserInfo storage user = userInfo[_user];
        for (uint256 i = 0; i < rewardTokenInfos.length; i++) {
            uint256 pending = (user.amount * accPerShares[i]) /
                ACC_PRECISION -
                user.rewardDebt[i];
            uint256 unpaid = user.unpaidRewards[i];
            uint256 toPay = pending + unpaid;
            if (toPay > 0) {
                user.unpaidRewards[i] = 0;
                user.paidRewards[i] += toPay;
                rewardTokenInfos[i].rewardToken.safeTransfer(_user, toPay);
                emit Harvest(
                    _user,
                    toPay,
                    address(rewardTokenInfos[i].rewardToken)
                );
            }
        }
    }

    function _ensureUserInfoLen(address _user) internal {
        UserInfo storage user = userInfo[_user];
        if (
            user.rewardDebt.length == rewardTokenInfos.length &&
            user.unpaidRewards.length == rewardTokenInfos.length &&
            user.paidRewards.length == rewardTokenInfos.length
        ) {
            return;
        }

        uint256 n = rewardTokenInfos.length;
        while (user.rewardDebt.length < n) {
            user.rewardDebt.push(0);
        }
        while (user.unpaidRewards.length < n) {
            user.unpaidRewards.push(0);
        }
        while (user.paidRewards.length < n) {
            user.paidRewards.push(0);
        }
    }

    function _resetDebt(address _user) internal {
        UserInfo storage user = userInfo[_user];
        uint256 n = rewardTokenInfos.length;
        for (uint256 i = 0; i < n; i++) {
            user.rewardDebt[i] =
                (user.amount * accPerShares[i]) /
                ACC_PRECISION;
        }
    }

    function rewardTokenInfosLength() external view returns (uint256) {
        return rewardTokenInfos.length;
    }

    function setRewardTokenEnabled(
        uint256 _rewardTokenIndex,
        bool _enabled
    ) external onlyOwner {
        require(
            _rewardTokenIndex < rewardTokenInfos.length,
            "index out of range"
        );
        updatePool(); //first update accPerShares
        rewardTokenInfos[_rewardTokenIndex].enabled = _enabled;
        emit UpdateRewardTokenEnabled(
            _rewardTokenIndex,
            address(rewardTokenInfos[_rewardTokenIndex].rewardToken),
            _enabled
        );
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
        for (uint256 i = 0; i < rewardTokenInfos.length; i++) {
            uint256 balance = rewardTokenInfos[i].rewardToken.balanceOf(
                address(this)
            );
            if (balance > 0) {
                rewardTokenInfos[i].rewardToken.safeTransfer(to, balance);
                emit EmergencyWithdraw(
                    to,
                    address(rewardTokenInfos[i].rewardToken),
                    balance
                );
            }
        }
    }

    function accPerSharesLength() external view returns (uint256) {
        return accPerShares.length;
    }

    function setUnstakeEnabled(bool _unstakeEnabled) external onlyOwner {
        unstakeEnabled = _unstakeEnabled;
        emit UpdateUnstakeEnabled(unstakeEnabled);
    }
}
