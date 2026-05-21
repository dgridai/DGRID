// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CalcMonthData} from "./libraries/CalcMonthData.sol";

contract DGAIStake is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for ERC20;
    uint256 public constant ACC_PRECISION = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10000;
    ERC20 public DGAI;

    bytes32 private constant ACTION_CREATE_NODE = keccak256("CREATENODE");

    struct StakingNode {
        string nodeName;
        uint256 amount; //dgai amount staked
        uint256 delegatorCount;
        uint256 commissionRate;
    }

    // per month release token value for Node Reward-LLM Provider,  Node Reward-Team, Node Reward- Staking&Reserved
    struct MonthlyEmission {
        uint64 startTime; // Inclusive start timestamp for this month's emission window.
        uint64 endTime; // Exclusive end timestamp for this month's emission window.
        uint256 llmQuota; // Total LLM reward to be linearly emitted during this month.
        uint256 llmEmitted; // LLM reward already emitted for this month.
        uint256 stakingQuota; // Total staking reward to be linearly emitted during this month.
        uint256 stakingEmitted; // Staking reward already emitted for this month.
        uint256 teamClaimed; // Team reward already claimed for this month.
        uint256 teamAmount; // Total team reward claimable for this month.
    }

    struct PendingUnstake {
        uint256 amount;
        uint256 releaseTime;
    }

    mapping(address => StakingNode) public stakingNodeMap; // staker => node

    mapping(address => mapping(address => uint256)) public userAmount; // node => user => amount
    mapping(address => mapping(address => uint256)) public userRewardDebt; // node => user => debt
    mapping(address => mapping(address => uint256)) public userUnpaid; // node => user => reward
    mapping(address => uint256) public nodeCommissionUnpaid; // node owner => commission
    mapping(address => uint256) public nodeDelegatedAmount; // node owner => delegated amount, excluding self-stake
    mapping(address => uint256) public nodeDelegatedRewardDebt; // node owner => delegated amount reward debt
    mapping(address => mapping(address => mapping(uint256 => PendingUnstake)))
        public pendingUnstake; // node => user => pending

    mapping(uint256 => bool) public signedNonce;
    uint256 public unstakedNonce; // unstakedNonce & requstId : unstake ,unstakeLlm nonce required
    uint256 public minNodeSelfStakeAmount; //minimum node self-stake amount required
    uint256 public minLlmStakeAmount; //staking amount required for LLM
    uint256 public minDelegatorStakeAmount; //minimum amount required for delegator to stake
    uint256 public coolingTimeDay; //cooling time for LLM staking and delegate staking

    uint256 public totalStakingNodes;
    uint256 public totalStakedAmount;

    uint256 public totalDelegators;

    uint256 public lastRewardTime;
    uint256 public accRewardPerShare;
    uint256 public emissionCursor;
    MonthlyEmission[] public monthlyEmissions;

    uint256 public llmTotalStakedAmount;
    uint256 public llmStakedCount;
    uint256 public llmLastRewardTime;
    uint256 public llmAccRewardPerShare;
    uint256 public llmEmissionCursor;

    mapping(address => uint256) public llmUserAmount;
    mapping(address => uint256) public llmUserRewardDebt;
    mapping(address => uint256) public llmUserUnpaid;
    mapping(address => mapping(uint256 => PendingUnstake))
        public pendingUnstakeLlm;

    uint256 public llmCommissionRate;

    address public server;
    address public dev; //Node Reward-Team address
    bool public paused;

    event CreateStakingNode(
        address indexed owner,
        string nodeName,
        uint256 amount,
        uint256 commissionRate
    );

    event Pause(bool paused);

    event AddMonthlyEmission(
        uint64 indexed indexMonth,
        uint64 startTime,
        uint64 endTime,
        uint256 llmQuota,
        uint256 llmEmitted,
        uint256 stakingQuota,
        uint256 stakingEmitted,
        uint256 teamClaimed,
        uint256 teamAmount
    );

    event SetMonthlyEmission(
        uint64 indexed indexMonth,
        uint64 startTime,
        uint64 endTime,
        uint256 llmQuota,
        uint256 llmEmitted,
        uint256 stakingQuota,
        uint256 stakingEmitted,
        uint256 teamClaimed,
        uint256 teamAmount
    );
    event Stake(address indexed node, address indexed staker, uint256 amount);

    event Unstake(
        address indexed node,
        address indexed staker,
        uint256 indexed requestId,
        uint256 amount,
        uint256 earned,
        uint256 releaseTime
    );
    event Claim(address indexed node, address indexed staker, uint256 amount);
    event ClaimCommission(address indexed node, uint256 amount);
    event SetCoolingTimeDay(uint256 oldValue, uint256 newValue);

    event ClaimTeamReward(
        uint256 indexed monthIndex,
        address indexed target,
        uint256 amount
    );

    event StakeLlm(address indexed staker, uint256 amount);

    event UnstakeLlm(
        address indexed staker,
        uint256 indexed requestId,
        uint256 amount,
        uint256 earned,
        uint256 releaseTime
    );
    event ClaimLlm(address indexed staker, uint256 amount);
    event ClaimUnstake(
        address indexed node,
        address indexed staker,
        uint256 indexed requestId,
        uint256 amount
    );
    event ClaimUnstakeLlm(
        address indexed staker,
        uint256 indexed requestId,
        uint256 amount
    );
    event SetServer(address indexed server);
    event EmergencyWithdraw(
        address indexed token,
        address indexed target,
        uint256 amount
    );

    event SetLlmCommissionRate(uint256 newValue);

    modifier whenNotPaused() {
        require(!paused, "staking is paused");
        _;
    }

    modifier nodeExists(address _node) {
        require(
            bytes(stakingNodeMap[_node].nodeName).length > 0,
            "node not exist"
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _DGAI, // DGAI token address
        address _owner, // owner address
        uint256 _minNodeSelfStakeAmount, // minimum node self-stake amount required
        uint256 _minLlmStakeAmount, //minimum amount required for LLM
        uint256 _minDelegatorStakeAmount, //minimum amount required for delegator to stake
        uint256 _emissionStartTime, // staking node start time for emission
        uint256 _llmEmissionStartTime, // LLM start time for emission
        uint256 _coolingTimeDay, // cooling time for LLM staking and delegate staking
        address _server, // server address
        address _dev // dev address
    ) external initializer {
        require(_DGAI != address(0), "DGAI is zero");
        require(_coolingTimeDay > 0, "coolingTimeDay is zero");
        require(
            _minNodeSelfStakeAmount > 0 &&
                _minLlmStakeAmount > 0 &&
                _minDelegatorStakeAmount > 0,
            "minimum stake amount is zero"
        );
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        DGAI = ERC20(_DGAI);
        minNodeSelfStakeAmount = _minNodeSelfStakeAmount;
        minLlmStakeAmount = _minLlmStakeAmount;
        minDelegatorStakeAmount = _minDelegatorStakeAmount;
        server = _server;
        coolingTimeDay = _coolingTimeDay;
        dev = _dev;

        lastRewardTime = _emissionStartTime;
        llmLastRewardTime = _llmEmissionStartTime;
    }

    /// @notice Create staking nodes as whitelist only
    /// @param _nodeName the name of the node
    /// @param _staker the address to create the node
    /// @param _amount the amount to stake
    /// @param _commissionRate the commission rate to set
    /// @param _deadline the deadline to sign the signature
    /// @param _nonce the nonce to sign the signature
    /// @param _signature the signature to verify the signature
    function createStakingNode(
        string memory _nodeName,
        address _staker,
        uint256 _amount,
        uint256 _commissionRate,
        uint256 _deadline,
        uint256 _nonce,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused {
        require(_staker == msg.sender, "staker must be caller");
        require(
            bytes(stakingNodeMap[_staker].nodeName).length == 0,
            "node exists"
        );
        require(bytes(_nodeName).length > 0, "nodeName is empty");
        require(block.timestamp <= _deadline, "signature expired");
        require(_amount >= minNodeSelfStakeAmount, "amount below minimum");
        require(
            _commissionRate >= 0 && _commissionRate <= 2000,
            "invalid commissionrate"
        );
        require(!signedNonce[_nonce], "nonce is signed");
        signedNonce[_nonce] = true;

        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(
            abi.encode(
                block.chainid,
                _nodeName,
                _staker,
                _amount,
                _commissionRate,
                _deadline,
                _nonce,
                ACTION_CREATE_NODE
            )
        );
        require(
            ECDSA.recover(ethSignedMessageHash, _signature) == server,
            "invalid server signature"
        );

        updatePool();
        DGAI.safeTransferFrom(msg.sender, address(this), _amount);

        StakingNode storage node = stakingNodeMap[_staker];
        node.nodeName = _nodeName;
        node.amount = _amount;
        node.commissionRate = _commissionRate;
        node.delegatorCount = 1;

        userAmount[_staker][_staker] = _amount;
        userRewardDebt[_staker][_staker] =
            (_amount * accRewardPerShare) /
            ACC_PRECISION;

        totalStakingNodes++;
        totalStakedAmount += _amount;
        totalDelegators++;

        emit CreateStakingNode(_staker, _nodeName, _amount, _commissionRate);
        emit Stake(_staker, _staker, _amount);
    }

    /// @notice choose a delegated node to stake a DGAI then you can flexibly unstake DGAI.
    /// @param _node the address of the created node to stake
    /// @param _amount the amount to stake
    function stake(
        address _node,
        uint256 _amount
    ) public nodeExists(_node) nonReentrant whenNotPaused {
        require(_amount >= minDelegatorStakeAmount, "amount below minimum");

        StakingNode storage node = stakingNodeMap[_node];

        updatePool();
        _accrueUnpaid(_node, msg.sender);
        if (msg.sender != _node) {
            _accrueNodeCommission(_node);
        }

        DGAI.safeTransferFrom(msg.sender, address(this), _amount);

        uint256 beforeAmount = userAmount[_node][msg.sender];
        if (beforeAmount == 0) {
            node.delegatorCount++;
            totalDelegators++;
        }

        userAmount[_node][msg.sender] = beforeAmount + _amount;
        node.amount += _amount;
        totalStakedAmount += _amount;

        _resetDebt(_node, msg.sender);
        if (msg.sender != _node) {
            nodeDelegatedAmount[_node] += _amount;
            _resetNodeCommissionDebt(_node);
        }
        emit Stake(_node, msg.sender, _amount);
    }

    /// @notice stake LLM tokens
    function stakeLlm(uint256 _amount) external nonReentrant whenNotPaused {
        require(_amount >= minLlmStakeAmount, "amount below minimum");
        updateLlmPool();
        _accrueLlmUnpaid(msg.sender);

        DGAI.safeTransferFrom(msg.sender, address(this), _amount);
        llmUserAmount[msg.sender] += _amount;
        if (llmUserAmount[msg.sender] == _amount) {
            llmStakedCount++;
        }
        llmTotalStakedAmount += _amount;
        _resetLlmDebt(msg.sender);
        emit StakeLlm(msg.sender, _amount);
    }

    /// @notice request unstake first; tokens can be claimed after coolingTimeDay.
    /// @param _node the address of the created node to unstake
    function unstake(
        address _node,
        uint256 _amount
    ) external nodeExists(_node) nonReentrant whenNotPaused {
        require(_amount > 0, "amount is zero");
        require(
            _amount <= userAmount[_node][msg.sender],
            "insufficient staked"
        );

        updatePool();
        _accrueUnpaid(_node, msg.sender);
        if (msg.sender != _node) {
            _accrueNodeCommission(_node);
        }

        uint256 stakedAmountBefore = userAmount[_node][msg.sender];
        uint256 earned = (userUnpaid[_node][msg.sender] * _amount) /
            stakedAmountBefore;
        userAmount[_node][msg.sender] -= _amount;

        StakingNode storage node = stakingNodeMap[_node];
        node.amount -= _amount;
        if (userAmount[_node][msg.sender] == 0 && node.delegatorCount > 0) {
            node.delegatorCount--;
        }
        totalStakedAmount -= _amount;
        _resetDebt(_node, msg.sender);
        if (msg.sender != _node) {
            nodeDelegatedAmount[_node] -= _amount;
            _resetNodeCommissionDebt(_node);
        }
        uint256 releaseAt = block.timestamp + (coolingTimeDay * 1 days);
        uint256 requestId = unstakedNonce++;
        pendingUnstake[_node][msg.sender][requestId] = PendingUnstake({
            amount: _amount,
            releaseTime: releaseAt
        });
        emit Unstake(_node, msg.sender, requestId, _amount, earned, releaseAt);
    }

    /// @notice request unstake LLM tokens first; tokens can be claimed after coolingTimeDay.
    function unstakeLlm(uint256 _amount) external nonReentrant whenNotPaused {
        require(_amount > 0, "amount is zero");
        require(_amount <= llmUserAmount[msg.sender], "insufficient staked");

        updateLlmPool();
        _accrueLlmUnpaid(msg.sender);
        uint256 earned = (llmUserUnpaid[msg.sender] * _amount) /
            llmTotalStakedAmount;
        llmTotalStakedAmount -= _amount;
        llmUserAmount[msg.sender] -= _amount;
        if (llmUserAmount[msg.sender] == 0 && llmStakedCount > 0) {
            llmStakedCount--;
        }
        _resetLlmDebt(msg.sender);

        uint64 releaseAt = uint64(block.timestamp + (coolingTimeDay * 1 days));
        uint256 requestId = unstakedNonce++;
        pendingUnstakeLlm[msg.sender][requestId] = PendingUnstake({
            amount: _amount,
            releaseTime: releaseAt
        });

        emit UnstakeLlm(msg.sender, requestId, _amount, earned, releaseAt);
    }

    // -----------------------------------
    //-----------claim--------------------
    //------------------------------------
    /// @notice claim rewards for a node
    /// @param _node the address of the node to claim rewards
    /// @dev The rewards are calculated as the amount of the monthly emission that has been unlocked
    ///      between the fromTs and toTs.
    function claim(
        address _node
    ) external nodeExists(_node) nonReentrant whenNotPaused {
        updatePool();
        _accrueUnpaid(_node, msg.sender);
        uint256 amount = userUnpaid[_node][msg.sender];
        require(amount > 0, "no rewards");
        userUnpaid[_node][msg.sender] = 0;
        _resetDebt(_node, msg.sender);
        DGAI.safeTransfer(msg.sender, amount);
        emit Claim(_node, msg.sender, amount);
    }

    /// @notice claim unstake for a node
    /// @param _node the address of the node to claim unstake
    /// @param _requestId the request id to claim unstake
    /// @dev The unstake is calculated as the amount of the monthly emission that has been unlocked
    ///      between the fromTs and toTs.
    function claimUnstake(
        address _node,
        uint256 _requestId
    ) external nodeExists(_node) nonReentrant whenNotPaused {
        PendingUnstake storage req = pendingUnstake[_node][msg.sender][
            _requestId
        ];
        uint256 amount = req.amount;
        require(amount > 0, "no pending unstake");
        require(block.timestamp >= req.releaseTime, "cooling not finished");

        delete pendingUnstake[_node][msg.sender][_requestId];

        DGAI.safeTransfer(msg.sender, amount);
        emit ClaimUnstake(_node, msg.sender, _requestId, amount);
    }

    /// @notice Node creator claims the commission that
    function claimNodeCommission() external nonReentrant whenNotPaused {
        updatePool();
        _accrueNodeCommission(msg.sender);
        _resetNodeCommissionDebt(msg.sender);
        uint256 amount = nodeCommissionUnpaid[msg.sender];
        require(amount > 0, "no commission");
        nodeCommissionUnpaid[msg.sender] = 0;
        DGAI.safeTransfer(msg.sender, amount);
        emit ClaimCommission(msg.sender, amount);
    }

    /// @notice claim team reward for a month
    /// @param _target the address to receive the reward
    /// @param _amount the amount to claim
    /// @param _monthIndex the month index to claim the reward
    function claimTeamReward(
        uint256 _monthIndex,
        address _target,
        uint256 _amount
    ) external nonReentrant whenNotPaused {
        require(msg.sender == dev, "only dev can claim");
        require(_target != address(0), "target is zero");
        require(_amount > 0, "amount is zero");
        require(_monthIndex <= emissionCursor, "month index OOB");

        MonthlyEmission storage m = monthlyEmissions[_monthIndex];
        require(block.timestamp >= m.startTime, "month not started");
        require(m.teamAmount > 0, "team amount is zero");
        require(m.teamClaimed + _amount <= m.teamAmount, "exceed month amount");

        m.teamClaimed += _amount;
        DGAI.safeTransfer(_target, _amount);
        emit ClaimTeamReward(_monthIndex, _target, _amount);
    }

    /// @notice claim llm rewards
    function claimLlm() external nonReentrant whenNotPaused {
        updateLlmPool();
        _accrueLlmUnpaid(msg.sender);
        uint256 amount = llmUserUnpaid[msg.sender];
        require(amount > 0, "no rewards");
        llmUserUnpaid[msg.sender] = 0;
        _resetLlmDebt(msg.sender);
        uint256 commission = (amount * llmCommissionRate) / BPS_DENOMINATOR;
        amount -= commission;
        if (commission > 0) {
            DGAI.safeTransfer(server, commission);
        }
        DGAI.safeTransfer(msg.sender, amount);
        emit ClaimLlm(msg.sender, amount);
    }

    /// @notice claim unstake llm rewards finished after coolingTimeDay
    /// @param _requestId the request id to claim unstake llm rewards
    function claimUnstakeLlm(
        uint256 _requestId
    ) external nonReentrant whenNotPaused {
        PendingUnstake storage req = pendingUnstakeLlm[msg.sender][_requestId];
        uint256 amount = req.amount;
        require(amount > 0, "no pending unstake");
        require(block.timestamp >= req.releaseTime, "cooling not finished");

        delete pendingUnstakeLlm[msg.sender][_requestId];

        DGAI.safeTransfer(msg.sender, amount);
        emit ClaimUnstakeLlm(msg.sender, _requestId, amount);
    }

    function addMonthlyEmission(
        uint64 _monthIndex,
        MonthlyEmission memory pushEmissionMonths
    ) external onlyOwner {
        require(_monthIndex == monthlyEmissions.length, "month index mismatch");
        require(
            pushEmissionMonths.startTime < pushEmissionMonths.endTime,
            "invalid month range"
        );
        monthlyEmissions.push(pushEmissionMonths);
        emit AddMonthlyEmission(
            _monthIndex,
            pushEmissionMonths.startTime,
            pushEmissionMonths.endTime,
            pushEmissionMonths.llmQuota,
            pushEmissionMonths.llmEmitted,
            pushEmissionMonths.stakingQuota,
            pushEmissionMonths.stakingEmitted,
            pushEmissionMonths.teamClaimed,
            pushEmissionMonths.teamAmount
        );
    }

    /// @notice only set the emission for later months.
    function setMonthlyEmission(
        uint64 _monthIndex,
        MonthlyEmission memory _monthlyEmission
    ) external onlyOwner {
        require(_monthIndex < monthlyEmissions.length, "month not exist");
        require(
            _monthIndex > emissionCursor && _monthIndex > llmEmissionCursor,
            "only set the emission for later months"
        );
        require(
            _monthlyEmission.startTime < _monthlyEmission.endTime,
            "invalid month range"
        );
        require(
            block.timestamp < monthlyEmissions[_monthIndex].startTime,
            "month already started"
        );
        require(
            _monthlyEmission.teamClaimed == 0 &&
                _monthlyEmission.llmEmitted == 0 &&
                _monthlyEmission.stakingEmitted == 0,
            "initial emitted values must be zero"
        );
        monthlyEmissions[_monthIndex] = _monthlyEmission;
        emit SetMonthlyEmission(
            _monthIndex,
            _monthlyEmission.startTime,
            _monthlyEmission.endTime,
            _monthlyEmission.llmQuota,
            _monthlyEmission.llmEmitted,
            _monthlyEmission.stakingQuota,
            _monthlyEmission.stakingEmitted,
            _monthlyEmission.teamClaimed,
            _monthlyEmission.teamAmount
        );
    }

    function setMinLlmStakeAmount(uint256 _minAmount) external onlyOwner {
        minLlmStakeAmount = _minAmount;
    }

    function setMinDelegatorStakeAmount(uint256 _minAmount) external onlyOwner {
        minDelegatorStakeAmount = _minAmount;
    }

    function setMinNodeSelfStakeAmount(uint256 _minAmount) external onlyOwner {
        minNodeSelfStakeAmount = _minAmount;
    }

    function setCoolingTimeDay(uint256 _coolingTimeDay) external onlyOwner {
        require(_coolingTimeDay > 0, "coolingTimeDay is zero");
        emit SetCoolingTimeDay(coolingTimeDay, _coolingTimeDay);
        coolingTimeDay = _coolingTimeDay;
    }

    function updatePool() public {
        uint256 nowTs = block.timestamp;
        if (nowTs <= lastRewardTime) return;
        if (paused || totalStakedAmount == 0) {
            lastRewardTime = nowTs;
            return;
        }

        uint256 reward = _accrueEmission(lastRewardTime, nowTs);
        lastRewardTime = nowTs;
        if (reward > 0) {
            accRewardPerShare += (reward * ACC_PRECISION) / totalStakedAmount;
        }
    }

    function updateLlmPool() public {
        uint256 nowTs = block.timestamp;
        if (nowTs <= llmLastRewardTime) return;
        if (paused || llmTotalStakedAmount == 0) {
            llmLastRewardTime = nowTs;
            return;
        }

        uint256 reward = _accrueLlmEmission(llmLastRewardTime, nowTs);
        llmLastRewardTime = nowTs;
        if (reward > 0) {
            llmAccRewardPerShare +=
                (reward * ACC_PRECISION) /
                llmTotalStakedAmount;
        }
    }

    function pendingLlmReward(address _user) external view returns (uint256) {
        uint256 acc = llmAccRewardPerShare;
        if (
            !paused &&
            llmTotalStakedAmount > 0 &&
            block.timestamp > llmLastRewardTime
        ) {
            uint256 reward = _previewLlmEmission(
                llmLastRewardTime,
                block.timestamp
            );
            if (reward > 0) {
                acc += (reward * ACC_PRECISION) / llmTotalStakedAmount;
            }
        }
        uint256 pending = ((llmUserAmount[_user] * acc) / ACC_PRECISION) -
            llmUserRewardDebt[_user];
        return pending + llmUserUnpaid[_user];
    }

    function pendingReward(
        address _node,
        address _user
    ) external view returns (uint256) {
        uint256 acc = accRewardPerShare;
        if (
            !paused && totalStakedAmount > 0 && block.timestamp > lastRewardTime
        ) {
            uint256 reward = _previewEmission(lastRewardTime, block.timestamp);
            if (reward > 0) {
                acc += (reward * ACC_PRECISION) / totalStakedAmount;
            }
        }

        uint256 amount = userAmount[_node][_user];
        uint256 pending = ((amount * acc) / ACC_PRECISION) -
            userRewardDebt[_node][_user];

        if (_user != _node) {
            pending =
                (pending *
                    (BPS_DENOMINATOR - stakingNodeMap[_node].commissionRate)) /
                BPS_DENOMINATOR;
        }
        return pending + userUnpaid[_node][_user];
    }

    function pendingNodeCommission(
        address _node
    ) external view returns (uint256) {
        uint256 acc = accRewardPerShare;
        if (
            !paused && totalStakedAmount > 0 && block.timestamp > lastRewardTime
        ) {
            uint256 reward = _previewEmission(lastRewardTime, block.timestamp);
            if (reward > 0) {
                acc += (reward * ACC_PRECISION) / totalStakedAmount;
            }
        }

        uint256 delegatedAmount = nodeDelegatedAmount[_node];
        if (delegatedAmount == 0) {
            return nodeCommissionUnpaid[_node];
        }

        uint256 grossPending = ((delegatedAmount * acc) / ACC_PRECISION) -
            nodeDelegatedRewardDebt[_node];
        uint256 fee = (grossPending * stakingNodeMap[_node].commissionRate) /
            BPS_DENOMINATOR;
        return nodeCommissionUnpaid[_node] + fee;
    }

    function _accrueEmission(
        uint256 fromTs,
        uint256 toTs
    ) internal returns (uint256 released) {
        if (toTs <= fromTs) return 0;

        uint256 i = emissionCursor;
        uint256 len = monthlyEmissions.length;
        while (i < len && fromTs < toTs) {
            MonthlyEmission storage m = monthlyEmissions[i];
            if (toTs <= m.startTime) break;

            uint256 delta = CalcMonthData.calcMonthlyDelta(
                m.startTime,
                m.endTime,
                m.stakingQuota,
                m.stakingEmitted,
                fromTs,
                toTs
            );
            if (delta > 0) {
                m.stakingEmitted += delta;
                released += delta;
            }

            if (toTs >= m.endTime) {
                i++;
                emissionCursor = i;
            } else {
                break;
            }
        }
    }

    function _accrueLlmEmission(
        uint256 fromTs,
        uint256 toTs
    ) internal returns (uint256 released) {
        if (toTs <= fromTs) return 0;

        uint256 i = llmEmissionCursor;
        uint256 len = monthlyEmissions.length;
        while (i < len && fromTs < toTs) {
            MonthlyEmission storage m = monthlyEmissions[i];
            if (toTs <= m.startTime) break;

            uint256 delta = CalcMonthData.calcMonthlyDelta(
                m.startTime,
                m.endTime,
                m.llmQuota,
                m.llmEmitted,
                fromTs,
                toTs
            );
            if (delta > 0) {
                m.llmEmitted += delta;
                released += delta;
            }

            if (toTs >= m.endTime) {
                i++;
                llmEmissionCursor = i;
            } else {
                break;
            }
        }
    }

    function _previewEmission(
        uint256 fromTs,
        uint256 toTs
    ) internal view returns (uint256 released) {
        if (toTs <= fromTs) return 0;

        uint256 i = emissionCursor;
        uint256 len = monthlyEmissions.length;
        while (i < len && fromTs < toTs) {
            MonthlyEmission storage m = monthlyEmissions[i];
            if (toTs <= m.startTime) break;
            released += CalcMonthData.calcMonthlyDelta(
                m.startTime,
                m.endTime,
                m.stakingQuota,
                m.stakingEmitted,
                fromTs,
                toTs
            );
            if (toTs >= m.endTime) {
                i++;
            } else {
                break;
            }
        }
    }

    function _previewLlmEmission(
        uint256 fromTs,
        uint256 toTs
    ) internal view returns (uint256 released) {
        if (toTs <= fromTs) return 0;

        uint256 i = llmEmissionCursor;
        uint256 len = monthlyEmissions.length;
        while (i < len && fromTs < toTs) {
            MonthlyEmission storage m = monthlyEmissions[i];
            if (toTs <= m.startTime) break;
            released += CalcMonthData.calcMonthlyDelta(
                m.startTime,
                m.endTime,
                m.llmQuota,
                m.llmEmitted,
                fromTs,
                toTs
            );
            if (toTs >= m.endTime) {
                i++;
            } else {
                break;
            }
        }
    }

    function _accrueLlmUnpaid(address _user) internal {
        uint256 amount = llmUserAmount[_user];
        if (amount == 0) return;
        uint256 pending = ((amount * llmAccRewardPerShare) / ACC_PRECISION) -
            llmUserRewardDebt[_user];
        if (pending == 0) return;
        llmUserUnpaid[_user] += pending;
    }

    function _accrueUnpaid(address _node, address _user) internal {
        uint256 amount = userAmount[_node][_user];
        if (amount == 0) return;

        uint256 pending = ((amount * accRewardPerShare) / ACC_PRECISION) -
            userRewardDebt[_node][_user];
        if (pending == 0) return;

        if (_user != _node) {
            pending =
                (pending *
                    (BPS_DENOMINATOR - stakingNodeMap[_node].commissionRate)) /
                BPS_DENOMINATOR;
        }
        userUnpaid[_node][_user] += pending;
    }

    function _accrueNodeCommission(address _node) internal {
        uint256 delegatedAmount = nodeDelegatedAmount[_node];
        if (delegatedAmount == 0) return;

        uint256 grossPending = ((delegatedAmount * accRewardPerShare) /
            ACC_PRECISION) - nodeDelegatedRewardDebt[_node];
        if (grossPending == 0) return;

        uint256 fee = (grossPending * stakingNodeMap[_node].commissionRate) /
            BPS_DENOMINATOR;
        if (fee == 0) return;

        nodeCommissionUnpaid[_node] += fee;
    }

    function _resetLlmDebt(address _user) internal {
        llmUserRewardDebt[_user] =
            (llmUserAmount[_user] * llmAccRewardPerShare) /
            ACC_PRECISION;
    }

    function _resetDebt(address _node, address _user) internal {
        uint256 amount = userAmount[_node][_user];
        userRewardDebt[_node][_user] =
            (amount * accRewardPerShare) /
            ACC_PRECISION;
    }

    function _resetNodeCommissionDebt(address _node) internal {
        nodeDelegatedRewardDebt[_node] =
            (nodeDelegatedAmount[_node] * accRewardPerShare) /
            ACC_PRECISION;
    }

    function getMonthlyEmission(
        uint256 _monthIndex
    ) external view returns (MonthlyEmission memory) {
        require(_monthIndex < monthlyEmissions.length, "month not exist");
        return monthlyEmissions[_monthIndex];
    }

    function getMonthlyEmissionsLength() external view returns (uint256) {
        return monthlyEmissions.length;
    }

    function setServer(address _server) external onlyOwner {
        require(_server != address(0), "server is zero");
        server = _server;
        emit SetServer(_server);
    }

    /// @notice Get the annual emission for calculating base APY;
    /// 0. _index: llm
    /// 1. _index: team
    /// 2. _index: node
    function getAnnualStakingEmission(
        uint256 _index
    ) external view returns (uint256 released) {
        uint256 nowTs = block.timestamp;
        uint256 horizon = nowTs + 365 days;

        uint256 i = (_index == 0) ? llmEmissionCursor : emissionCursor;
        uint256 lastTime = (_index == 0) ? llmLastRewardTime : lastRewardTime;
        uint256 len = monthlyEmissions.length;

        while (i < len && nowTs < horizon) {
            MonthlyEmission storage m = monthlyEmissions[i];
            if (horizon <= m.startTime) break;

            uint256 emitted;
            uint256 quota;

            if (_index == 0) {
                emitted = m.llmEmitted;
                quota = m.llmQuota;
            } else if (_index == 1) {
                emitted = m.teamClaimed;
                quota = m.teamAmount;
            } else {
                emitted = m.stakingEmitted;
                quota = m.stakingQuota;
            }

            if (nowTs > lastTime) {
                emitted += CalcMonthData.calcMonthlyDelta(
                    m.startTime,
                    m.endTime,
                    quota,
                    emitted,
                    lastTime,
                    nowTs
                );
            }

            released += CalcMonthData.calcMonthlyDelta(
                m.startTime,
                m.endTime,
                quota,
                emitted,
                nowTs,
                horizon
            );

            if (horizon >= m.endTime) {
                i++;
            } else {
                break;
            }
        }
    }

    function setLlmCommissionRate(
        uint256 _rate
    ) external whenNotPaused onlyOwner {
        require(_rate < 2000, "rate must be less than 2000");
        llmCommissionRate = _rate;
        emit SetLlmCommissionRate(_rate);
    }

    /// @notice Emergency withdraw DGAI from this contract.
    /// @dev Owner-only emergency path that transfers the core token (DGAI).
    function emergencyWithdraw(
        address _target,
        uint256 _amount
    ) external onlyOwner {
        require(_target != address(0), "target is zero");
        require(_amount > 0, "amount is zero");

        DGAI.safeTransfer(_target, _amount);
        emit EmergencyWithdraw(address(DGAI), _target, _amount);
    }

    function pause(bool _paused) external onlyOwner {
        updatePool();
        updateLlmPool();
        paused = _paused;
        emit Pause(_paused);
    }
}
