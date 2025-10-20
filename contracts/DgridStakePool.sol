// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "./Interfaces/IDgridNode.sol";

contract DgridStakePool is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for ERC20;

    struct UserInfo {
        uint256 amount; // user staked amount
        uint256[] rewardDebt; // reward debt (for settlement)
    }

    struct RewardInfo {
        ERC20 rewardToken; // reward token
        uint256 rewardPerBlock; // reward per block
        bool enabled; // is enabled
    }

    struct JailInfo {
        address owner;
        uint256[] tokenIds;
    }

    // server
    address public server;

    // configuration
    uint256 public startBlock; // start block
    uint256 public lastRewardBlock; // last reward block

    RewardInfo[] public rewardInfos; // reward information
    uint256[] public accPerShares; // accumulated per share (expand ACC_PRECISION)
    uint256 public constant ACC_PRECISION = 1e18;
    uint256 public totalStaked; // total staked amount
    mapping(address => UserInfo) public userInfo; // user -> info

    IDgridNode public dgridNode;

    mapping(address => uint256[]) public unpaidRewards; // unpaid rewards book: user -> [rewardIndex => amount]

    bool public paused;

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
    event Unpause(address operator, bool unpaused);
    event EmergencyWithdraw(address to, address token, uint256 amount);

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
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        server = _server;
        startBlock = _startBlock;
        lastRewardBlock = _startBlock;
        dgridNode = IDgridNode(_dgridNode);
        require(_rewardTokens.length > 0, "reward tokens is empty");
        require(
            _rewardTokens.length == _rewardPerBlocks.length,
            "length mismatch"
        );
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            require(
                _rewardTokens[i] != address(0),
                "reward token is zero address"
            );
            require(_rewardPerBlocks[i] > 0, "reward per block is zero");
            rewardInfos.push(
                RewardInfo({
                    rewardToken: ERC20(_rewardTokens[i]),
                    rewardPerBlock: _rewardPerBlocks[i],
                    enabled: true
                })
            );
            accPerShares.push(0);
        }
    }

    // add reward token
    function addRewardToken(
        address _rewardToken,
        uint256 _rewardPerBlock
    ) public onlyOwner {
        require(_rewardToken != address(0), "reward token is zero address");
        require(_rewardPerBlock > 0, "reward per block is zero");
        updatePool();
        rewardInfos.push(
            RewardInfo({
                rewardToken: ERC20(_rewardToken),
                rewardPerBlock: _rewardPerBlock,
                enabled: true
            })
        );
        accPerShares.push(0);
    }

    // update reward status of a single pool
    function updatePool() public {
        if (block.number <= lastRewardBlock) {
            return;
        }

        if (totalStaked == 0 || rewardInfos.length == 0) {
            lastRewardBlock = block.number;
            return;
        }

        uint256 blocks = block.number - lastRewardBlock;
        for (uint256 i = 0; i < rewardInfos.length; i++) {
            if (!rewardInfos[i].enabled) {
                continue; // do not calculate disabled rewards
            }
            uint256 reward = blocks * rewardInfos[i].rewardPerBlock;
            accPerShares[i] += (reward * ACC_PRECISION) / totalStaked; // calculate accumulated per share
        }
        lastRewardBlock = block.number;
    }

    // check pending rewards
    function pendingRewards(
        address _user
    )
        external
        view
        returns (address[] memory rewardTokens, uint256[] memory rewards)
    {
        uint256 n = rewardInfos.length;
        rewardTokens = new address[](n);
        rewards = new uint256[](n);

        if (n == 0) {
            return (rewardTokens, rewards);
        }

        UserInfo storage user = userInfo[_user];
        uint256 blocks = block.number > lastRewardBlock && totalStaked > 0
            ? (block.number - lastRewardBlock)
            : 0;

        for (uint256 i = 0; i < n; i++) {
            uint256 acc = accPerShares[i];
            if (blocks > 0 && rewardInfos[i].enabled) {
                uint256 reward = blocks * rewardInfos[i].rewardPerBlock;
                acc += (reward * ACC_PRECISION) / totalStaked;
            }
            uint256 debt = i < user.rewardDebt.length ? user.rewardDebt[i] : 0;
            uint256 pending = (user.amount * acc) / ACC_PRECISION - debt;
            uint256 unpaid = i < unpaidRewards[_user].length
                ? unpaidRewards[_user][i]
                : 0;
            rewards[i] = pending + unpaid;
            rewardTokens[i] = address(rewardInfos[i].rewardToken);
        }
        return (rewardTokens, rewards);
    }

    // stake/add
    function deposit(
        uint256[] memory _nodes,
        address _staker,
        uint256 _expireTime,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused {
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
            abi.encode(block.chainid, _nodes, _staker, _expireTime)
        );
        address signer = ECDSA.recover(ethSignedMessageHash, _signature);
        require(signer == server, "invalid signature");

        dgridNode.stake(_nodes);

        updatePool();
        _ensureUnpaidLen(_staker);
        _ensureDebtLen(_staker);
        _accrueUnpaid(_staker);
        UserInfo storage user = userInfo[_staker];
        user.amount += _nodes.length;
        totalStaked += _nodes.length;
        _resetDebt(_staker);
        emit Deposit(_staker, _nodes);
    }

    function jailNodes(
        JailInfo[] memory _jailInfos
    ) external onlyServer nonReentrant whenNotPaused {
        require(_jailInfos.length > 0, "node ids is empty");
        updatePool(); // update pool first

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

            dgridNode.jail(jailInfo.tokenIds); // batch jail
            UserInfo storage user = userInfo[jailInfo.owner];
            require(user.amount > 0, "user is not staked");
            _ensureDebtLen(jailInfo.owner);
            _ensureUnpaidLen(jailInfo.owner);
            _accrueUnpaid(jailInfo.owner);
            user.amount -= jailInfo.tokenIds.length;
            totalStaked -= jailInfo.tokenIds.length;
            _resetDebt(jailInfo.owner);
            emit JailNodes(jailInfo.owner, jailInfo.tokenIds);
        }
    }

    function unjailNodes(
        uint256[] memory _nodeIds,
        address _owner
    ) external nonReentrant whenNotPaused {
        require(_nodeIds.length > 0, "node ids is empty");
        updatePool(); // update pool first
        _ensureUnpaidLen(_owner);
        _ensureDebtLen(_owner);
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

    // only harvest rewards (no principal)
    function harvest() external nonReentrant whenNotPaused {
        require(block.number >= startBlock, "not started");
        updatePool();
        _ensureUnpaidLen(msg.sender);
        _ensureDebtLen(msg.sender);
        _payReward(msg.sender);
        _resetDebt(msg.sender);
    }

    // admin: adjust reward per block
    function setRewardPerBlock(
        uint256[] memory _rewardPerBlock
    ) external onlyOwner {
        require(
            _rewardPerBlock.length == rewardInfos.length,
            "length mismatch"
        );
        for (uint256 i = 0; i < _rewardPerBlock.length; i++) {
            emit UpdateRewardPerBlock(
                address(rewardInfos[i].rewardToken),
                rewardInfos[i].rewardPerBlock,
                _rewardPerBlock[i]
            );
            rewardInfos[i].rewardPerBlock = _rewardPerBlock[i];
        }
    }

    // admin: adjust start block
    function setStartBlock(uint256 _startBlock) external onlyOwner {
        require(_startBlock >= block.number, "start < current block");
        require(block.number < startBlock, "already started");
        emit UpdateStartBlock(startBlock, _startBlock);
        startBlock = _startBlock;
        lastRewardBlock = _startBlock;
    }

    // admin: set server address
    function setServer(address _server) external onlyOwner {
        address oldServer = server;
        server = _server;
        emit UpdateServer(oldServer, _server);
    }

    // accrue unpaid rewards
    function _accrueUnpaid(address _user) internal {
        UserInfo storage user = userInfo[_user];
        if (user.amount == 0) {
            return;
        }
        for (uint256 i = 0; i < rewardInfos.length; i++) {
            uint256 pending = (user.amount * accPerShares[i]) /
                ACC_PRECISION -
                user.rewardDebt[i];
            if (pending > 0) {
                unpaidRewards[_user][i] += pending;
                emit AccrueUnpaid(_user, i, pending);
            }
        }
    }

    // pay rewards
    function _payReward(address _user) internal {
        UserInfo storage user = userInfo[_user];
        for (uint256 i = 0; i < rewardInfos.length; i++) {
            uint256 pending = (user.amount * accPerShares[i]) /
                ACC_PRECISION -
                user.rewardDebt[i];
            uint256 unpaid = unpaidRewards[_user][i];
            uint256 toPay = pending + unpaid;
            if (toPay > 0) {
                unpaidRewards[_user][i] = 0;
                rewardInfos[i].rewardToken.safeTransfer(_user, toPay);
                emit Harvest(_user, toPay, address(rewardInfos[i].rewardToken));
            }
        }
    }

    // ensure reward debt length
    function _ensureDebtLen(address _user) internal {
        UserInfo storage user = userInfo[_user];
        if (user.rewardDebt.length == rewardInfos.length) {
            // if user.rewardDebt length is the same as rewardInfos length, return
            return;
        }
        uint256 n = rewardInfos.length;
        while (user.rewardDebt.length < n) {
            // handle new rewards, set user.rewardDebt to 0 so that users can calculate accumulated rewards even if they do not interact with the contract
            user.rewardDebt.push(0);
        }
    }

    // ensure unpaid rewards length
    function _ensureUnpaidLen(address _user) internal {
        uint256 n = rewardInfos.length;
        if (unpaidRewards[_user].length == n) {
            return;
        }
        while (unpaidRewards[_user].length < n) {
            unpaidRewards[_user].push(0);
        }
    }

    // reset reward debt
    function _resetDebt(address _user) internal {
        UserInfo storage user = userInfo[_user];
        uint256 n = rewardInfos.length;
        for (uint256 i = 0; i < n; i++) {
            user.rewardDebt[i] =
                (user.amount * accPerShares[i]) /
                ACC_PRECISION;
        }
    }

    // get reward infos length
    function rewardInfosLength() external view returns (uint256) {
        return rewardInfos.length;
    }

    // set reward token enabled
    function setRewardTokenEnabled(
        uint256 _rewardTokenIndex,
        bool _enabled
    ) external onlyOwner {
        require(_rewardTokenIndex < rewardInfos.length, "index out of range");
        updatePool(); // update accPerShares first
        rewardInfos[_rewardTokenIndex].enabled = _enabled;
        emit UpdateRewardTokenEnabled(
            _rewardTokenIndex,
            address(rewardInfos[_rewardTokenIndex].rewardToken),
            _enabled
        );
    }

    // pause
    function pause() external onlyOwner whenNotPaused {
        paused = true;
        emit Pause(msg.sender, true);
    }

    // unpause
    function unpause() external onlyOwner whenPaused {
        paused = false;
        emit Unpause(msg.sender, false);
    }

    // emergency withdraw
    function emergencyWithdraw(
        address to
    ) external onlyOwner whenPaused nonReentrant {
        require(to != address(0), "to is zero address");
        for (uint256 i = 0; i < rewardInfos.length; i++) {
            uint256 balance = rewardInfos[i].rewardToken.balanceOf(
                address(this)
            );
            if (balance > 0) {
                rewardInfos[i].rewardToken.safeTransfer(to, balance);
                emit EmergencyWithdraw(
                    to,
                    address(rewardInfos[i].rewardToken),
                    balance
                );
            }
        }
    }
}
