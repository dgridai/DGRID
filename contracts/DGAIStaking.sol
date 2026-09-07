// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureValidator} from "./libraries/SignatureValidator.sol";

contract DGAIStaking is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for ERC20;

    uint256 public constant ACC_PRECISION = 1e18;
    /// @dev  Virtual team stake used to reuse accPerShare math; this is not a real deposited amount.
    uint256 private constant TEAM_SHARE = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10000;
    /// @dev Weight baseline (in bps). A stake's weight = amount * fixedRates[day] / RATE_BASE.
    ///      It is also the per-year rate the global node acc advances at under FixedRate mode.
    ///      With RATE_BASE = 6000 (60%): 180d(6000)=1x, 360d(9000)=1.5x, 90d(3000)=0.5x.
    ///      Any new tier is supported by simply configuring fixedRates[day]; a tier rate
    ///      lower than RATE_BASE (e.g. 90d => 30%) yields weight below principal, which is fine.
    uint64 private constant RATE_BASE = 6000;
    uint8 private constant NODE_POOL_ID = 0;
    uint8 private constant TEAM_POOL_ID = 1;
    uint8 private constant LLM_POOL_ID = 2;

    ERC20 public DGAI;

    bytes32 private constant ACTION_CREATE_NODE = keccak256("CREATENODE");
    bytes32 private constant ACTION_UNJAIL = keccak256("UNJAIL");
    bytes32 private constant ACTION_JAIL = keccak256("JAIL");
    bytes32 private constant ACTION_PRESTAKE = keccak256("PRESTAKE");

    struct StakingNode {
        uint64 nodeId;
        address owner;
        uint256 amount; // active principal in this node , staker not does unstake
        uint256 delegatorCount;
        /// @dev nodeStatus lifecycle (reserved for future upgrade):x
        ///      contract upgrade logic by appending the nodeStatus field.
        // status: 0 => jail, 1 => active , expand ... depends on upgrade logic
        uint8 nodeStatus;
    }

    // poolId = 0 : node reward, 1 : team reward, 2 : llm reward
    struct PoolInfo {
        uint8 poolId;
        uint128 perSecondReward;
        uint64 lastRewardTime;
        uint256 totalStaked;
        bool enabled;
    }
    PoolInfo[] public poolInfos;
    // accRewardPerShares[0] : node reward, accRewardPerShares[1] : team reward, accRewardPerShares[2] : llm reward
    uint256[] public accRewardPerShares;
    /// @dev  The unallocated remainder from the previous division in each pool (multiplied by the scale) is carried over to the next accumulation to avoid precision loss during high-frequency updates.
    uint256[] public remainders;

    /// @notice Pending unstake request released after the cooling period
    struct PendingUnstake {
        uint256 amount;
        uint256 unStakeTime;
        uint64 day; // lock tier this unstake belongs to (node stake only)
        uint64 commissionRate; // node commission rate snapshotted at unstake
        uint256 claimedReward; // waiting-period reward already claimed
        uint256 claimedCommission; // waiting-period commission already accrued
    }

    /// @notice A user's stake in a single lock tier under a node.
    ///         Lets one user hold multiple tiers (e.g. 180 and 360) at once.
    struct Position {
        uint256 amount; // active principal in this tier
        uint256 pendingUnstake; // principal cooling down in this tier
        uint256 rewardDebt; // reward debt for this tier
        uint256 unpaid; // settled but unclaimed reward for this tier
        uint256 lastClaimTime; // last reward claim time for this tier
        uint256 claimedAmount;
    }

    struct PositionView {
        uint64 nodeId;
        uint64 day;
        uint8 nodeStatus;
        address nodeOwner;
        uint256 pendingReward;
        uint256 lastClaimTime;
        uint256 amount;
        uint256 pendingUnstake;
        uint256 unpaid;
        uint256 claimedAmount;
    }

    mapping(address => uint64[]) private userNodes;
    mapping(address => mapping(uint64 => bool)) private userNodeExists;
    /// Staking node map
    mapping(uint64 => StakingNode) public stakingNodeMap;
    /// @dev Node commission unpaid
    mapping(uint64 => uint256) public nodeCommissionUnpaid;
    mapping(uint64 => uint256) public nodeDelegatedRewardDebt;
    /// @notice pending unstake request.
    mapping(uint64 => mapping(address => mapping(uint256 => PendingUnstake)))
        public pendingUnstake;
    /// @notice Pending unstake request ids indexed by node/user/day for reward preview and claim.
    mapping(uint64 => mapping(address => mapping(uint64 => uint256[])))
        public userPendingUnstakeIds;
    /// @notice pending claim for node owner, delegator, llm user.
    mapping(address => uint256) public lastTimeClaimNodeOwner;
    mapping(address => uint256) public lastTimeClaimLlm;

    mapping(address => uint256) public llmUserAmount;
    mapping(address => uint256) public llmUserRewardDebt;
    mapping(address => uint256) public llmUserUnpaid;
    mapping(address => mapping(uint256 => PendingUnstake))
        public pendingUnstakeLlm;

    /// @notice whether a user has pre staked
    mapping(address => bool) public userPreStaked;

    uint256 public teamRewardDebt;
    uint256 public teamUnpaid;

    mapping(uint256 => bool) public signedNonce;

    uint256 public unstakedNonce; // next unstaked nonce
    uint256 public minLlmStakeAmount;
    uint64 public nodeIds;
    uint256 public nodeStakers;

    uint256 public llmStakedCount;
    /// @dev Total user principal held by this contract (node + llm staked + pending unstake principal). Protected from emergencyWithdraw.
    uint256 public totalPrincipal;
    uint256 public totalNodeStake;
    uint256 public llmCommissionRate; /// @dev the subsequent upgrade may not be zero.
    uint256 public teamNextClaimTime; // next team reward time for a cooling days

    uint64 public coolingTeamClaimDay;
    uint64 public coolingClaimDay; /// @notice cooling period for node owner, delegator, llm user to claim.
    uint64 public commissionRate;

    // node stake fields
    /// @notice lock tier => rate in bps. 180 => 6000 (60%), 360 => 9000 (90%).
    ///         Add any tier freely, including below RATE_BASE (e.g. 90 => 3000 / 30%).
    mapping(uint64 => uint64) public fixedRates;
    /// @notice Per-tier stake of a user under a node. Supports multiple tiers at once.
    mapping(uint64 => mapping(address => mapping(uint64 => Position)))
        public positions;
    /// @notice Lock tiers a user currently holds under a node (index for `positions`).
    mapping(uint64 => mapping(address => uint64[])) public userDays;
    /// @notice Whether a lock tier is currently indexed in `userDays`.
    mapping(uint64 => mapping(address => mapping(uint64 => bool)))
        public userDayExists;
    /// @notice Cached total delegated weight of a node (sum over all delegators/tiers).
    ///         Used as the FixedRate-mode commission divisor; maintained incrementally.
    mapping(uint64 => uint256) public nodeWeightCache;
    /// @notice The user's activity is recorded by the backend after the tdgai swap; the interaction with the hanldePreStake function transfers the information from the treasury to this contract.
    address public treasury;
    address public server;
    address public dev;
    bool public paused;

    /// @dev @upgrade v2
    uint64 public claimStartInitTime;

    /// @dev upgrade v3
    address public stakePool;

    event CreateStakingNode(address indexed owner, uint64 nodeId);
    event Pause(bool paused);
    event Stake(
        uint64 indexed nodeId,
        address indexed staker,
        uint64 day,
        uint256 amount
    );
    event Unstake(
        uint64 indexed nodeId,
        address indexed staker,
        uint256 indexed requestId,
        uint256 day,
        uint256 amount,
        uint256 releaseTime
    );
    event JailNode(uint64 indexed nodeId);
    event UnjailedNode(uint64 indexed nodeId);
    event Claim(
        uint64 indexed nodeId,
        address indexed staker,
        uint64 day,
        uint256 amount
    );
    event ClaimCommission(address indexed node, uint256 amount);
    event ClaimTeamReward(
        address indexed target,
        uint256 amount,
        uint256 nextClaimTime
    );
    event StakeLlm(address indexed staker, uint256 amount);
    event UnstakeLlm(
        address indexed staker,
        uint256 indexed requestId,
        uint256 amount,
        uint256 releaseTime
    );
    event ClaimLlm(address indexed staker, uint256 amount);
    event ClaimUnstake(
        uint64 indexed nodeId,
        address indexed staker,
        uint256 indexed requestId,
        uint256 amount
    );
    event ClaimUnstakeLlm(
        address indexed staker,
        uint256 indexed requestId,
        uint256 amount
    );

    event SetPoolPerSecondReward(
        uint8 indexed poolId,
        uint128 oldValue,
        uint128 newValue
    );
    event AddFixedRate(uint64 indexed day, uint64 rate);
    event SetPoolEnabled(uint8 indexed poolId, bool oldValue, bool newValue);
    event SetCoolingTeamClaimDay(uint64 oldValue, uint64 newValue);
    event SetLlmCommissionRate(uint256 oldValue, uint256 newValue);
    event SetCoolingClaimDay(uint64 oldValue, uint64 newValue);
    event SetCommissionRate(uint64 oldValue, uint64 newValue);
    event SetServer(address indexed server);
    event SetDev(address indexed dev);
    event SetMinLlmStakeAmount(uint256 oldValue, uint256 newValue);
    event ChangeNode(
        address indexed user,
        uint64 indexed fromNodeId,
        uint64 indexed toNodeId,
        uint64 day,
        uint256 amount,
        uint256 canceledPendingUnstake,
        uint256[] cancelRequestIds
    );
    event EmergencyWithdraw(
        address indexed token,
        address indexed target,
        uint256 amount
    );
    event RestakeDGAI(
        address user,
        uint64 sourceNodeId,
        uint64 sourceDay,
        uint64 targetNodeId,
        uint64 targetDay,
        uint256 amount
    );
    event RestakeRewardCall(
        address user,
        uint64 selectNodeId,
        uint64 day,
        uint256 amount
    );

    modifier whenNotPaused() {
        require(!paused, "staking is paused");
        _;
    }

    modifier whenServer() {
        require(msg.sender == server, "not server");
        _;
    }

    modifier nodeExists(uint64 _nodeId) {
        require(_nodeId > 0 && _nodeId <= nodeIds, "invalid node");
        _;
    }

    modifier onlyServer() {
        require(msg.sender == server, "not server");
        _;
    }

    modifier onlyStakePool() {
        require(msg.sender == stakePool, "not stake pool");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _DGAI,
        address _owner,
        uint64 _coolingClaimDay,
        uint64 _coolingTeamClaimDay,
        uint64 _commissionRate,
        PoolInfo[] memory _poolInfos,
        uint64[] memory _days,
        uint64[] memory _fixedRates,
        address _treasury,
        address _server,
        address _dev
    ) external initializer {
        require(_DGAI != address(0), "DGAI is zero");
        /// @dev owner is safe address
        require(_owner != address(0), "owner is zero");
        require(_server != address(0), "server is zero");
        require(_dev != address(0), "dev is zero");
        require(_treasury != address(0), "treasury is zero");
        require(_poolInfos.length == 3, "pool length mismatch");
        require(
            _days.length == _fixedRates.length && _days.length > 0,
            "length mismatch"
        );
        require(
            _commissionRate > 0 && _commissionRate <= 10000,
            "invalid commission rate"
        );
        ///  @notice  The `owner` is held by a multisig / Timelock contract in production , guarantee not to do evil.
        __Ownable_init(_owner);
        __ReentrancyGuard_init();

        DGAI = ERC20(_DGAI);

        coolingClaimDay = _coolingClaimDay;
        coolingTeamClaimDay = _coolingTeamClaimDay;

        commissionRate = _commissionRate;
        server = _server;
        dev = _dev;
        /// @notice the treasury is wallet address , transfer to this contract address when user interact with the handlePreStake function.
        treasury = _treasury;
        for (uint256 i = 0; i < _poolInfos.length; i++) {
            require(_poolInfos[i].poolId == i, "pool id mismatch");
            PoolInfo memory pool = _poolInfos[i];
            pool.lastRewardTime = uint64(block.timestamp);
            /// @dev Team uses a fixed virtual stake so it can share the accPerShare model.
            pool.totalStaked = pool.poolId == TEAM_POOL_ID ? TEAM_SHARE : 0;
            poolInfos.push(pool);
            accRewardPerShares.push(0);
            remainders.push(0);
        }
        for (uint256 i = 0; i < _days.length; i++) {
            fixedRates[_days[i]] = _fixedRates[i];
        }

        paused = true;
    }

    function initializeV2(
        uint64 _claimStartInitTime //1787644688
    ) external reinitializer(2) {
        require(_claimStartInitTime > 0, "claim start init time is zero");
        claimStartInitTime = _claimStartInitTime;
    }

    function initializeV3(address _stakePool) external reinitializer(3) {
        require(_stakePool != address(0), "stake pool is zero");
        stakePool = _stakePool;
    }

    function createStakingNodeByOwner(
        address _nodeOwner
    ) external nonReentrant whenNotPaused onlyOwner {
        require(_nodeOwner != address(0), "node owner is zero");

        updateNodePool();
        nodeIds++;
        // init dgrid node
        StakingNode storage node = stakingNodeMap[nodeIds];
        node.nodeStatus = 1; // active staking
        node.amount = 0;
        node.nodeId = nodeIds;
        node.owner = _nodeOwner;

        emit CreateStakingNode(_nodeOwner, nodeIds);
    }

    function handlePreStake(
        uint64 _day,
        uint64 _nodeId,
        uint256 _amount,
        uint256 _deadline,
        uint256 _nonce,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused {
        require(fixedRates[_day] > 0, "invalid day");
        require(_amount > 0, "amount is zero");
        require(block.timestamp <= _deadline, "signature expired");
        require(!signedNonce[_nonce], "nonce is signed");
        require(!userPreStaked[msg.sender], "user has pre staked");
        StakingNode storage node = stakingNodeMap[_nodeId];
        require(node.nodeStatus == 1, "node not staking");

        SignatureValidator.validatePreStake(
            server,
            address(this),
            msg.sender,
            _day,
            _nodeId,
            _amount,
            _deadline,
            _nonce,
            ACTION_PRESTAKE,
            _signature
        );

        signedNonce[_nonce] = true;
        userPreStaked[msg.sender] = true;
        updateNodePool();
        _accrueUnpaid(_nodeId, msg.sender);
        _accrueNodeCommission(_nodeId);

        DGAI.safeTransferFrom(treasury, address(this), _amount);

        _applyStake(node, _nodeId, msg.sender, _day, _amount);
    }

    /// delegater choose a node to stake.
    function stake(
        uint64 _nodeId,
        uint64 _day,
        uint256 _amount
    ) external nodeExists(_nodeId) nonReentrant whenNotPaused {
        require(fixedRates[_day] > 0, "invalid day");
        require(_amount > 0, "amount is zero");
        StakingNode storage node = stakingNodeMap[_nodeId];
        require(node.nodeStatus == 1, "node not staking");
        updateNodePool();
        _accrueUnpaid(_nodeId, msg.sender);
        _accrueNodeCommission(_nodeId);

        DGAI.safeTransferFrom(msg.sender, address(this), _amount);

        _applyStake(node, _nodeId, msg.sender, _day, _amount);
    }

    function restakeRewardCall(
        uint64 _selectNodeId,
        uint64 _day,
        uint256 _amount,
        address _user
    )
        external
        nonReentrant
        whenNotPaused
        onlyStakePool
        nodeExists(_selectNodeId)
    {
        require(_user != address(0), "user is zero address");
        require(fixedRates[_day] > 0, "invalid day");
        require(_amount > 0, "amount is zero");
        updateNodePool();
        _accrueUnpaid(_selectNodeId, _user);
        _accrueNodeCommission(_selectNodeId);
        StakingNode storage node = stakingNodeMap[_selectNodeId];
        require(node.nodeStatus == 1, "node not staking");
        DGAI.safeTransferFrom(stakePool, address(this), _amount);

        _applyStake(node, _selectNodeId, _user, _day, _amount);
        emit RestakeRewardCall(_user, _selectNodeId, _day, _amount);
    }

    /// @dev Shared stake accounting: credits a tier position, updates node
    ///      principal, node/global weight and rebases reward debts.
    ///      FixedRate tracks weight (amount * tierRate / RATE_BASE).
    function _applyStake(
        StakingNode storage node,
        uint64 _nodeId,
        address _user,
        uint64 _day,
        uint256 _amount
    ) internal {
        Position storage pos = positions[_nodeId][_user][_day];
        if (!userNodeExists[_user][_nodeId]) {
            userNodeExists[_user][_nodeId] = true;
            userNodes[_user].push(_nodeId);
        }
        if (!userDayExists[_nodeId][_user][_day]) {
            _addUserDay(_nodeId, _user, _day);
        }
        if (_userStakeTotal(_nodeId, _user) == 0) {
            node.delegatorCount++;
            nodeStakers++;
        }

        uint256 weight = _tierWeight(_day, _amount);
        pos.amount += _amount;
        // first stake
        if (pos.lastClaimTime == 0) {
            pos.lastClaimTime = block.timestamp;
        }
        node.amount += _amount;
        nodeWeightCache[_nodeId] += weight;
        totalNodeStake += _amount;
        totalPrincipal += _amount;

        poolInfos[NODE_POOL_ID].totalStaked += weight;

        _resetDebt(_nodeId, _user);
        _resetNodeCommissionDebt(_nodeId);
        emit Stake(_nodeId, _user, _day, _amount);
    }

    function changeNodeByUser(
        uint64 _fromNodeId,
        uint64 _toNodeId,
        uint64[] calldata _days
    )
        external
        nodeExists(_fromNodeId)
        nodeExists(_toNodeId)
        nonReentrant
        whenNotPaused
    {
        require(_fromNodeId != _toNodeId, "same node");
        require(_days.length > 0, "empty days");
        StakingNode storage fromNode = stakingNodeMap[_fromNodeId];
        StakingNode storage toNode = stakingNodeMap[_toNodeId];

        require(toNode.nodeStatus == 1, "target node not staking");

        updateNodePool();
        _accrueUnpaid(_fromNodeId, msg.sender);
        _accrueNodeCommission(_fromNodeId);
        _accrueUnpaid(_toNodeId, msg.sender);
        _accrueNodeCommission(_toNodeId);

        if (_userStakeTotal(_toNodeId, msg.sender) == 0) {
            toNode.delegatorCount++;
            nodeStakers++;
        }

        uint256 totalFromAmount = 0;
        uint256 totalMoveAmount = 0;
        uint256 totalFromWeight = 0;
        uint256 totalToWeight = 0;

        for (uint256 i = 0; i < _days.length; i++) {
            uint64 day = _days[i];
            Position storage fromPos = positions[_fromNodeId][msg.sender][day];
            uint256 fromAmount = fromPos.amount;
            uint256 fromPendingUnstake = fromPos.pendingUnstake;
            uint256 moveAmount = fromAmount + fromPendingUnstake;
            require(moveAmount > 0, "no position");
            Position storage toPos = positions[_toNodeId][msg.sender][day];
            // target node first stake
            if (toPos.lastClaimTime == 0) {
                toPos.lastClaimTime = block.timestamp;
            }
            toPos.amount += moveAmount;

            fromPos.amount = 0;
            fromPos.pendingUnstake = 0;

            uint256 fromWeight = _tierWeight(day, fromAmount);
            uint256 toWeight = _tierWeight(day, moveAmount);
            totalFromAmount += fromAmount;
            totalMoveAmount += moveAmount;
            totalFromWeight += fromWeight;
            totalToWeight += toWeight;

            if (!userDayExists[_toNodeId][msg.sender][day]) {
                _addUserDay(_toNodeId, msg.sender, day);
            }

            uint256[] memory requestIds = userPendingUnstakeIds[_fromNodeId][
                msg.sender
            ][day];
            for (uint256 j = 0; j < requestIds.length; j++) {
                delete pendingUnstake[_fromNodeId][msg.sender][requestIds[j]];
            }
            delete userPendingUnstakeIds[_fromNodeId][msg.sender][day];

            emit ChangeNode(
                msg.sender,
                _fromNodeId,
                _toNodeId,
                day,
                moveAmount,
                fromPendingUnstake,
                requestIds
            );
        }

        nodeWeightCache[_fromNodeId] -= totalFromWeight;
        nodeWeightCache[_toNodeId] += totalToWeight;
        poolInfos[NODE_POOL_ID].totalStaked =
            poolInfos[NODE_POOL_ID].totalStaked -
            totalFromWeight +
            totalToWeight;
        fromNode.amount -= totalFromAmount;
        toNode.amount += totalMoveAmount;
        if (!userNodeExists[msg.sender][_toNodeId]) {
            userNodeExists[msg.sender][_toNodeId] = true;
            userNodes[msg.sender].push(_toNodeId);
        }
        if (_userStakeTotal(_fromNodeId, msg.sender) == 0) {
            fromNode.delegatorCount--;
            nodeStakers--;
        }
        _resetDebt(_fromNodeId, msg.sender);
        _resetDebt(_toNodeId, msg.sender);
        _resetNodeCommissionDebt(_fromNodeId);
        _resetNodeCommissionDebt(_toNodeId);
    }

    function restakeDGAI(
        uint64 _sourceNodeId,
        uint64 _sourceDay,
        uint64 _targetNodeId,
        uint64 _targetDay
    )
        external
        nonReentrant
        whenNotPaused
        nodeExists(_sourceNodeId)
        nodeExists(_targetNodeId)
    {
        require(fixedRates[_sourceDay] > 0, "invalid source day");
        require(fixedRates[_targetDay] > 0, "invalid stake day");
        updateNodePool();
        _accrueUnpaid(_targetNodeId, msg.sender);
        _accrueNodeCommission(_targetNodeId);
        _accruePositionUnpaid(
            _sourceNodeId,
            msg.sender,
            _sourceDay,
            _previewPoolAccRewardPerShare(NODE_POOL_ID)
        );
        _accruePendingUnstakeReward(_sourceNodeId, msg.sender, _sourceDay);

        Position storage sourcePos = positions[_sourceNodeId][msg.sender][
            _sourceDay
        ];
        // require(
        //     block.timestamp >
        //         claimStartInitTime + (uint256(coolingClaimDay) * 1 days) &&
        //         block.timestamp >
        //         sourcePos.lastClaimTime + (uint256(coolingClaimDay) * 1 days),
        //     "restake cooling"
        // );

        uint256 amount = sourcePos.unpaid;
        require(amount > 0, "no pending reward");
        require(
            amount + totalPrincipal <= DGAI.balanceOf(address(this)),
            "insufficient balance"
        );
        sourcePos.unpaid = 0;
        sourcePos.lastClaimTime = block.timestamp;
        sourcePos.claimedAmount += amount;

        StakingNode storage targetNode = stakingNodeMap[_targetNodeId];
        _applyStake(targetNode, _targetNodeId, msg.sender, _targetDay, amount);

        emit RestakeDGAI(
            msg.sender,
            _sourceNodeId,
            _sourceDay,
            _targetNodeId,
            _targetDay,
            amount
        );
    }

    /// @dev Total active + cooling principal of a user under a node.
    function _userStakeTotal(
        uint64 _nodeId,
        address _user
    ) internal view returns (uint256) {
        uint64[] storage days_ = userDays[_nodeId][_user];
        uint256 total = 0;
        for (uint256 i = 0; i < days_.length; i++) {
            Position storage p = positions[_nodeId][_user][days_[i]];
            total += p.amount + p.pendingUnstake;
        }
        return total;
    }

    function _addUserDay(uint64 _nodeId, address _user, uint64 _day) internal {
        if (userDayExists[_nodeId][_user][_day]) {
            return;
        }
        userDayExists[_nodeId][_user][_day] = true;
        userDays[_nodeId][_user].push(_day);
    }

    // llm user stake
    // function stakeLlm(uint256 _amount) external nonReentrant whenNotPaused {
    //     revert("LLM stake is disabled");
    //     require(_amount >= minLlmStakeAmount, "amount below minimum");
    //     updateLlmPool();
    //     _accrueLlmUnpaid(msg.sender);

    //     DGAI.safeTransferFrom(msg.sender, address(this), _amount);

    //     llmUserAmount[msg.sender] += _amount;
    //     if (llmUserAmount[msg.sender] == _amount) {
    //         llmStakedCount++;
    //     }

    //     poolInfos[LLM_POOL_ID].totalStaked += _amount;

    //     _resetLlmDebt(msg.sender);
    //     totalPrincipal += _amount;
    //     emit StakeLlm(msg.sender, _amount);
    // }

    function unstake(
        uint64 _nodeId,
        uint64 _day,
        uint256 _amount
    ) external nodeExists(_nodeId) nonReentrant {
        require(_amount > 0, "amount is zero");
        Position storage pos = positions[_nodeId][msg.sender][_day];
        require(_amount <= pos.amount, "insufficient staked");

        updateNodePool();
        _accrueUnpaid(_nodeId, msg.sender);
        _accrueNodeCommission(_nodeId);

        // Move principal from active to cooling: active accrual stops; waiting reward is locked on request
        uint256 weight = _tierWeight(_day, _amount);
        pos.amount -= _amount;
        pos.pendingUnstake += _amount;
        nodeWeightCache[_nodeId] -= weight;

        StakingNode storage node = stakingNodeMap[_nodeId];
        node.amount -= _amount;

        poolInfos[NODE_POOL_ID].totalStaked -= weight;

        _resetDebt(_nodeId, msg.sender);
        _resetNodeCommissionDebt(_nodeId);

        uint256 requestId = unstakedNonce++;
        pendingUnstake[_nodeId][msg.sender][requestId] = PendingUnstake({
            amount: _amount,
            unStakeTime: block.timestamp,
            day: _day,
            commissionRate: commissionRate,
            claimedReward: 0,
            claimedCommission: 0
        });
        userPendingUnstakeIds[_nodeId][msg.sender][_day].push(requestId);

        emit Unstake(
            _nodeId,
            msg.sender,
            requestId,
            _day,
            _amount,
            block.timestamp + (_day * 1 days)
        );
    }

    // function unstakeLlm(uint256 _amount) external nonReentrant {
    //     require(_amount > 0, "amount is zero");
    //     require(_amount <= llmUserAmount[msg.sender], "insufficient staked");

    //     updateLlmPool();
    //     _accrueLlmUnpaid(msg.sender);

    //     llmUserAmount[msg.sender] -= _amount;
    //     if (llmUserAmount[msg.sender] == 0 && llmStakedCount > 0) {
    //         llmStakedCount--;
    //     }
    //     poolInfos[LLM_POOL_ID].totalStaked -= _amount;

    //     _resetLlmDebt(msg.sender);

    //     uint256 requestId = unstakedNonce++;
    //     pendingUnstakeLlm[msg.sender][requestId] = PendingUnstake({
    //         amount: _amount,
    //         unStakeTime: block.timestamp,
    //         day: 0,
    //         commissionRate: 0,
    //         claimedReward: 0,
    //         claimedCommission: 0
    //     });

    //     emit UnstakeLlm(msg.sender, requestId, _amount, block.timestamp);
    // }

    function claim(
        uint64 _nodeId,
        uint64 _day
    ) external nodeExists(_nodeId) nonReentrant {
        Position storage pos = positions[_nodeId][msg.sender][_day];
        require(
            block.timestamp >
                claimStartInitTime + (uint256(coolingClaimDay) * 1 days) &&
                block.timestamp >
                pos.lastClaimTime + (uint256(coolingClaimDay) * 1 days),
            "claim cooling"
        );

        updateNodePool();
        _accruePositionUnpaid(
            _nodeId,
            msg.sender,
            _day,
            _previewPoolAccRewardPerShare(NODE_POOL_ID)
        );
        _accruePendingUnstakeReward(_nodeId, msg.sender, _day);

        uint256 amount = pos.unpaid;

        require(
            amount + totalPrincipal <= DGAI.balanceOf(address(this)),
            "pool insufficient balance"
        );
        require(amount > 0, "no pending reward");
        pos.unpaid = 0;
        pos.lastClaimTime = block.timestamp;

        pos.claimedAmount += amount;
        DGAI.safeTransfer(msg.sender, amount);

        emit Claim(_nodeId, msg.sender, _day, amount);
    }

    function claimUnstake(
        uint64 _nodeId,
        uint256 _requestId
    ) external nodeExists(_nodeId) nonReentrant {
        PendingUnstake storage req = pendingUnstake[_nodeId][msg.sender][
            _requestId
        ];
        uint256 amount = req.amount;

        require(amount > 0, "no pending unstake");
        require(
            block.timestamp >= req.unStakeTime + (req.day * 1 days),
            "cooling not finished"
        );

        uint64 day = req.day;
        updateNodePool();
        _accrueUnpaid(_nodeId, msg.sender);
        _accrueNodeCommission(_nodeId);

        delete pendingUnstake[_nodeId][msg.sender][_requestId];
        _removePendingUnstakeId(_nodeId, msg.sender, day, _requestId);

        // Principal already left the active/weight pools at unstake time; here we
        // only release the cooling principal. Waiting reward has been accrued up
        // to unlock time before the request is deleted.
        Position storage pos = positions[_nodeId][msg.sender][day];
        pos.pendingUnstake -= amount;

        StakingNode storage node = stakingNodeMap[_nodeId];
        if (_userStakeTotal(_nodeId, msg.sender) == 0) {
            if (node.delegatorCount > 0) {
                node.delegatorCount--;
            }
            if (nodeStakers > 0) {
                nodeStakers--;
            }
        }
        _resetDebt(_nodeId, msg.sender);
        _resetNodeCommissionDebt(_nodeId);

        totalNodeStake -= amount;
        totalPrincipal -= amount;
        DGAI.safeTransfer(msg.sender, amount);

        emit ClaimUnstake(_nodeId, msg.sender, _requestId, amount);
    }

    function claimNodeCommission(uint64 _nodeId) external nonReentrant {
        require(
            block.timestamp >=
                lastTimeClaimNodeOwner[msg.sender] +
                    (uint256(coolingClaimDay) * 1 days),
            "claim cooling"
        );
        StakingNode storage node = stakingNodeMap[_nodeId];
        require(node.owner == msg.sender, "not owner");
        updateNodePool();
        _accrueNodeCommission(_nodeId);

        uint256 amount = nodeCommissionUnpaid[_nodeId];
        require(
            amount + totalPrincipal <= DGAI.balanceOf(address(this)),
            "pool insufficient balance"
        );
        require(amount > 0, "no pending commission");
        nodeCommissionUnpaid[_nodeId] = 0;
        lastTimeClaimNodeOwner[msg.sender] = block.timestamp;
        DGAI.safeTransfer(msg.sender, amount);

        emit ClaimCommission(msg.sender, amount);
    }

    // node jail and unjail , user can choose a node to stake
    function jailNode(uint64 _nodeId) external whenServer nodeExists(_nodeId) {
        StakingNode storage node = stakingNodeMap[_nodeId];
        require(node.nodeStatus == 1, "already jailed");

        updateNodePool();
        _accrueNodeCommission(_nodeId);

        node.nodeStatus = 0;
        emit JailNode(_nodeId);
    }

    // resolve jailed node
    function unjailNode(
        uint64 _nodeId
    ) external whenServer nodeExists(_nodeId) {
        StakingNode storage node = stakingNodeMap[_nodeId];
        require(node.nodeStatus == 0, "not jailed");

        updateNodePool();
        _accrueNodeCommission(_nodeId);

        node.nodeStatus = 1;
        emit UnjailedNode(_nodeId);
    }

    // function claimTeamReward(address _target) external nonReentrant {
    //     require(msg.sender == dev, "only dev can claim");
    //     require(_target != address(0), "target is zero");
    //     require(block.timestamp >= teamNextClaimTime, "team claim cooling");

    //     updateTeamPool();
    //     _accrueTeamUnpaid(); /// built-in resetDebt function

    //     uint256 amount = teamUnpaid;
    //     require(
    //         amount + totalPrincipal <= DGAI.balanceOf(address(this)),
    //         "pool insufficient team reward"
    //     );

    //     teamUnpaid = 0;

    //     teamNextClaimTime =
    //         block.timestamp +
    //         (uint256(coolingTeamClaimDay) * 1 days);

    //     DGAI.safeTransfer(_target, amount);
    //     emit ClaimTeamReward(_target, amount, teamNextClaimTime);
    // }

    // function claimLlm() external nonReentrant {
    //     require(
    //         block.timestamp >=
    //             lastTimeClaimLlm[msg.sender] +
    //                 (uint256(coolingClaimDay) * 1 days),
    //         "claim cooling"
    //     );
    //     updateLlmPool();
    //     _accrueLlmUnpaid(msg.sender);

    //     uint256 amount = llmUserUnpaid[msg.sender];
    //     require(
    //         amount + totalPrincipal <= DGAI.balanceOf(address(this)),
    //         "pool insufficient balance"
    //     );

    //     llmUserUnpaid[msg.sender] = 0;
    //     _resetLlmDebt(msg.sender);
    //     lastTimeClaimLlm[msg.sender] = block.timestamp;

    //     DGAI.safeTransfer(msg.sender, amount);

    //     emit ClaimLlm(msg.sender, amount);
    // }

    // function claimUnstakeLlm(uint256 _requestId) external nonReentrant {
    //     revert("LLM unstake claim disabled");
    //     PendingUnstake storage req = pendingUnstakeLlm[msg.sender][_requestId];
    //     uint256 amount = req.amount;

    //     require(amount > 0, "no pending unstake");
    //     require(
    //         block.timestamp >= req.unStakeTime + 7 days, // 7days after unstake
    //         "cooling not finished"
    //     );

    //     delete pendingUnstakeLlm[msg.sender][_requestId];
    //     totalPrincipal -= amount;
    //     DGAI.safeTransfer(msg.sender, amount);

    //     emit ClaimUnstakeLlm(msg.sender, _requestId, amount);
    // }

    function updateNodePool() public {
        _updatePool(NODE_POOL_ID);
    }

    // function updateTeamPool() public {
    //     _updatePool(TEAM_POOL_ID);
    // }

    // function updateLlmPool() public {
    //     _updatePool(LLM_POOL_ID);
    // }

    function pendingReward(
        uint64 _nodeId,
        address _user,
        uint64 _day
    ) public view returns (uint256) {
        Position storage pos = positions[_nodeId][_user][_day];
        uint256 unpaid = pos.unpaid;
        uint256[] storage ids = userPendingUnstakeIds[_nodeId][_user][_day];
        for (uint256 i = 0; i < ids.length; i++) {
            PendingUnstake storage req = pendingUnstake[_nodeId][_user][ids[i]];
            (uint256 rewardUnpaid, ) = _pendingUnstakeUnpaid(req);
            unpaid += rewardUnpaid;
        }

        if (pos.amount == 0) {
            return unpaid;
        }

        uint256 accumulated = _positionAccumulated(
            _nodeId,
            _user,
            _day,
            _previewPoolAccRewardPerShare(NODE_POOL_ID)
        );
        uint256 debt = pos.rewardDebt;
        uint256 pending = accumulated > debt ? accumulated - debt : 0;

        return unpaid + pending;
    }

    function pendingNodeCommission(
        uint64 _nodeId
    ) external view returns (uint256) {
        uint256 delegatedAmount = nodeWeightCache[_nodeId];
        if (delegatedAmount == 0) {
            return nodeCommissionUnpaid[_nodeId];
        }

        uint256 accumulated = _nodeCommissionAccumulated(
            _nodeId,
            _previewPoolAccRewardPerShare(NODE_POOL_ID)
        );
        uint256 debt = nodeDelegatedRewardDebt[_nodeId];
        uint256 gross = accumulated > debt ? accumulated - debt : 0;
        uint256 fee = (gross * commissionRate) / BPS_DENOMINATOR;

        return nodeCommissionUnpaid[_nodeId] + fee;
    }

    // function pendingLlmReward(address _user) external view returns (uint256) {
    //     uint256 amount = llmUserAmount[_user];
    //     uint256 pending = llmUserUnpaid[_user];
    //     if (amount == 0) {
    //         return pending;
    //     }

    //     uint256 accumulated = (amount *
    //         _previewPoolAccRewardPerShare(LLM_POOL_ID)) / ACC_PRECISION;
    //     uint256 debt = llmUserRewardDebt[_user];
    //     uint256 gross = accumulated > debt ? accumulated - debt : 0;

    //     return pending + gross;
    // }

    // function pendingTeamReward() external view returns (uint256) {
    //     uint256 accumulated = (TEAM_SHARE *
    //         _previewPoolAccRewardPerShare(TEAM_POOL_ID)) / ACC_PRECISION;
    //     uint256 debt = teamRewardDebt;
    //     uint256 gross = accumulated > debt ? accumulated - debt : 0;

    //     return teamUnpaid + gross;
    // }

    function getPoolInfoLen() external view returns (uint256) {
        return poolInfos.length;
    }

    function getPositions(
        address _user
    ) external view returns (PositionView[] memory result) {
        uint256 total = 0;

        for (uint256 i = 0; i < userNodes[_user].length; i++) {
            uint64 nodeId = userNodes[_user][i];
            total += userDays[nodeId][_user].length;
        }

        result = new PositionView[](total);
        uint256 index = 0;

        for (uint256 i = 0; i < userNodes[_user].length; i++) {
            uint64 nodeId = userNodes[_user][i];
            uint64[] memory days_ = userDays[nodeId][_user];

            for (uint256 j = 0; j < days_.length; j++) {
                uint64 day = days_[j];
                Position memory pos = positions[nodeId][_user][day];

                result[index] = PositionView({
                    nodeId: nodeId,
                    day: day,
                    nodeOwner: stakingNodeMap[nodeId].owner,
                    nodeStatus: stakingNodeMap[nodeId].nodeStatus,
                    pendingReward: pendingReward(nodeId, _user, day),
                    lastClaimTime: pos.lastClaimTime,
                    amount: pos.amount,
                    pendingUnstake: pos.pendingUnstake,
                    unpaid: pos.unpaid,
                    claimedAmount: pos.claimedAmount
                });

                index++;
            }
        }
    }

    // function setMinLlmStakeAmount(uint256 _minAmount) external onlyOwner {
    //     emit SetMinLlmStakeAmount(minLlmStakeAmount, _minAmount);
    //     minLlmStakeAmount = _minAmount;
    // }

    function setCoolingTeamClaimDay(
        uint64 _coolingTeamClaimDay
    ) external onlyOwner {
        emit SetCoolingTeamClaimDay(coolingTeamClaimDay, _coolingTeamClaimDay);
        coolingTeamClaimDay = _coolingTeamClaimDay;
    }

    function setCommissionRate(uint64 _rate) external onlyOwner {
        require(_rate > 0 && _rate <= 10000, "invalid rate");
        updateNodePool();

        /// @dev Adjustment Rate: Pre-calculation and settlement of commissions for all nodes
        for (uint64 i = 1; i <= nodeIds; i++) {
            _accrueNodeCommission(i);
        }

        emit SetCommissionRate(commissionRate, _rate);
        commissionRate = _rate;
    }

    function setCoolClaimDay(uint64 _coolingClaimDay) external onlyOwner {
        emit SetCoolingClaimDay(coolingClaimDay, _coolingClaimDay);
        coolingClaimDay = _coolingClaimDay;
    }

    // function setLlmCommissionRate(uint256 _rate) external onlyOwner {
    //     require(_rate <= BPS_DENOMINATOR, "invalid rate");
    //     emit SetLlmCommissionRate(llmCommissionRate, _rate);
    //     llmCommissionRate = _rate;
    // }

    function setPoolPerSecondReward(
        uint8 _poolId,
        uint128 _perSecondReward
    ) external onlyOwner {
        require(_poolId < poolInfos.length, "pool not exist");
        _updatePool(_poolId);
        uint128 oldValue = poolInfos[_poolId].perSecondReward;
        poolInfos[_poolId].perSecondReward = _perSecondReward;
        emit SetPoolPerSecondReward(_poolId, oldValue, _perSecondReward);
    }

    function addFixedRate(uint64 _day, uint64 _rate) external onlyOwner {
        require(_day > 0, "day is zero");
        require(fixedRates[_day] == 0, "fixed rate already set");
        fixedRates[_day] = _rate;
        emit AddFixedRate(_day, _rate);
    }

    function setPoolEnabled(uint8 _poolId, bool _enabled) external onlyOwner {
        require(_poolId < poolInfos.length, "pool not exist");
        _updatePool(_poolId);
        bool oldValue = poolInfos[_poolId].enabled;
        poolInfos[_poolId].enabled = _enabled;
        emit SetPoolEnabled(_poolId, oldValue, _enabled);
    }

    function setServer(address _server) external onlyOwner {
        require(_server != address(0), "server is zero");
        server = _server;
        emit SetServer(_server);
    }

    function setDev(address _dev) external onlyOwner {
        require(_dev != address(0), "dev is zero");
        dev = _dev;
        emit SetDev(_dev);
    }

    function _updatePool(uint8 _poolId) internal {
        PoolInfo storage pool = poolInfos[_poolId];
        uint256 nowTs = block.timestamp;
        if (nowTs <= pool.lastRewardTime) {
            return;
        }

        if (paused || !pool.enabled || pool.totalStaked == 0) {
            pool.lastRewardTime = uint64(nowTs);
            return;
        }

        uint256 dt = nowTs > pool.lastRewardTime
            ? nowTs - pool.lastRewardTime
            : 0;
        uint256 deltaAcc = 0;

        if (_poolId == NODE_POOL_ID) {
            uint256 denominator = BPS_DENOMINATOR * 365 days;
            uint256 numerator = uint256(RATE_BASE) *
                dt *
                ACC_PRECISION +
                remainders[_poolId];
            deltaAcc = numerator / denominator;
            // keep the remainder for next time
            remainders[_poolId] = numerator % denominator;
        } else {
            // scaled = perSecond * dt * ACC_PRECISION + remainder,
            // then scaled / totalStaked = deltaAcc + new remainder
            uint256 scaled = uint256(pool.perSecondReward) *
                dt *
                ACC_PRECISION +
                remainders[_poolId];
            deltaAcc = scaled / pool.totalStaked;
            remainders[_poolId] = scaled % pool.totalStaked;
        }

        if (deltaAcc > 0) {
            accRewardPerShares[_poolId] += deltaAcc;
        }
        pool.lastRewardTime = uint64(nowTs);
    }

    function _previewPoolAccRewardPerShare(
        uint8 _poolId
    ) internal view returns (uint256) {
        PoolInfo storage pool = poolInfos[_poolId];
        uint256 acc = accRewardPerShares[_poolId];
        uint256 nowTs = block.timestamp;

        if (
            paused ||
            nowTs <= pool.lastRewardTime ||
            !pool.enabled ||
            pool.totalStaked == 0
        ) {
            return acc;
        }

        uint256 dt = nowTs - pool.lastRewardTime;
        uint256 deltaAcc = 0;

        if (_poolId == NODE_POOL_ID) {
            uint256 denominator = BPS_DENOMINATOR * 365 days;
            uint256 numerator = uint256(RATE_BASE) *
                dt *
                ACC_PRECISION +
                remainders[_poolId];
            deltaAcc = numerator / denominator;
        } else {
            uint256 scaled = uint256(pool.perSecondReward) *
                dt *
                ACC_PRECISION +
                remainders[_poolId];
            deltaAcc = scaled / pool.totalStaked;
        }

        return acc + deltaAcc;
    }

    /// @dev Weight of a single tier position: amount * tierRate / RATE_BASE.
    function _tierWeight(
        uint64 _day,
        uint256 _amount
    ) internal view returns (uint256) {
        if (_amount == 0) {
            return 0;
        }
        return (_amount * uint256(fixedRates[_day])) / RATE_BASE;
    }

    /// @dev Total weight of a user under a node, summed over all active tiers.
    function _userWeight(
        uint64 _nodeId,
        address _user
    ) internal view returns (uint256) {
        uint64[] storage days_ = userDays[_nodeId][_user];
        uint256 weight = 0;
        for (uint256 i = 0; i < days_.length; i++) {
            uint64 day = days_[i];
            weight += _tierWeight(day, positions[_nodeId][_user][day].amount);
        }
        return weight;
    }

    function _pendingUnstakeUnpaid(
        PendingUnstake storage _req
    ) internal view returns (uint256 rewardUnpaid, uint256 commissionUnpaid) {
        uint256 reward = 0;
        if (_req.amount > 0) {
            uint256 endTime = _req.unStakeTime + (uint256(_req.day) * 1 days);
            uint256 rewardTime = block.timestamp < endTime
                ? block.timestamp
                : endTime;
            if (rewardTime > _req.unStakeTime) {
                reward =
                    (_req.amount *
                        uint256(fixedRates[_req.day]) *
                        (rewardTime - _req.unStakeTime)) /
                    (BPS_DENOMINATOR * 365 days);
            }
        }
        rewardUnpaid = reward > _req.claimedReward
            ? reward - _req.claimedReward
            : 0;
        uint256 commission = (reward * uint256(_req.commissionRate)) /
            BPS_DENOMINATOR;
        commissionUnpaid = commission > _req.claimedCommission
            ? commission - _req.claimedCommission
            : 0;
    }

    /// @dev => claim , restakeDGAI
    function _accruePendingUnstakeReward(
        uint64 _nodeId,
        address _user,
        uint64 _day
    ) internal {
        uint256[] storage ids = userPendingUnstakeIds[_nodeId][_user][_day];
        Position storage pos = positions[_nodeId][_user][_day];
        for (uint256 i = 0; i < ids.length; i++) {
            PendingUnstake storage req = pendingUnstake[_nodeId][_user][ids[i]];
            (
                uint256 rewardUnpaid,
                uint256 commissionUnpaid
            ) = _pendingUnstakeUnpaid(req);
            if (rewardUnpaid > 0) {
                pos.unpaid += rewardUnpaid;
                req.claimedReward += rewardUnpaid;
            }
            if (commissionUnpaid > 0) {
                nodeCommissionUnpaid[_nodeId] += commissionUnpaid;
                req.claimedCommission += commissionUnpaid;
            }
        }
    }

    function _removePendingUnstakeId(
        uint64 _nodeId,
        address _user,
        uint64 _day,
        uint256 _requestId
    ) internal {
        uint256[] storage ids = userPendingUnstakeIds[_nodeId][_user][_day];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == _requestId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                return;
            }
        }
    }

    function _positionAccumulated(
        uint64 _nodeId,
        address _user,
        uint64 _day,
        uint256 _acc
    ) internal view returns (uint256) {
        return
            (_tierWeight(_day, positions[_nodeId][_user][_day].amount) * _acc) /
            ACC_PRECISION;
    }

    /// @dev A user's active (non-cooling) principal under a node.
    function _userPrincipal(
        uint64 _nodeId,
        address _user
    ) internal view returns (uint256) {
        uint64[] storage days_ = userDays[_nodeId][_user];
        uint256 total = 0;
        for (uint256 i = 0; i < days_.length; i++) {
            total += positions[_nodeId][_user][days_[i]].amount;
        }
        return total;
    }

    function _nodeCommissionAccumulated(
        uint64 _nodeId,
        uint256 _acc
    ) internal view returns (uint256) {
        return (nodeWeightCache[_nodeId] * _acc) / ACC_PRECISION;
    }

    function _accrueUnpaid(uint64 _nodeId, address _user) internal {
        uint64[] storage days_ = userDays[_nodeId][_user];
        uint256 acc = _previewPoolAccRewardPerShare(NODE_POOL_ID);
        for (uint256 i = 0; i < days_.length; i++) {
            uint64 day = days_[i];
            _accruePositionUnpaid(_nodeId, _user, day, acc);
            _accruePendingUnstakeReward(_nodeId, _user, day);
        }
    }

    function _accruePositionUnpaid(
        uint64 _nodeId,
        address _user,
        uint64 _day,
        uint256 _acc
    ) internal {
        Position storage pos = positions[_nodeId][_user][_day];
        uint256 accumulated = _positionAccumulated(_nodeId, _user, _day, _acc);
        uint256 pendingGross = accumulated > pos.rewardDebt
            ? accumulated - pos.rewardDebt
            : 0;

        // Node commission is accrued separately in `_accrueNodeCommission`;
        // delegators keep their full reward.
        if (pendingGross > 0) {
            pos.unpaid += pendingGross;
        }
        pos.rewardDebt = accumulated;
    }

    function _accrueNodeCommission(uint64 _nodeId) internal {
        uint256 delegatedAmount = nodeWeightCache[_nodeId];
        if (delegatedAmount == 0) {
            _resetNodeCommissionDebt(_nodeId);
            return;
        }

        uint256 accumulated = _nodeCommissionAccumulated(
            _nodeId,
            _previewPoolAccRewardPerShare(NODE_POOL_ID)
        );
        uint256 debt = nodeDelegatedRewardDebt[_nodeId];
        uint256 gross = accumulated > debt ? accumulated - debt : 0;
        uint256 fee = (gross * commissionRate) / BPS_DENOMINATOR;

        if (fee > 0) {
            nodeCommissionUnpaid[_nodeId] += fee;
        }
        _resetNodeCommissionDebt(_nodeId);
    }

    // function _accrueLlmUnpaid(address _user) internal {
    //     uint256 amount = llmUserAmount[_user];
    //     if (amount == 0) {
    //         return;
    //     }

    //     uint256 accumulated = (amount * accRewardPerShares[LLM_POOL_ID]) /
    //         ACC_PRECISION;
    //     uint256 debt = llmUserRewardDebt[_user];
    //     uint256 pending = accumulated > debt ? accumulated - debt : 0;

    //     if (pending > 0) {
    //         llmUserUnpaid[_user] += pending;
    //     }
    //     _resetLlmDebt(_user);
    // }

    // function _accrueTeamUnpaid() internal {
    //     uint256 accumulated = (TEAM_SHARE * accRewardPerShares[TEAM_POOL_ID]) /
    //         ACC_PRECISION;
    //     uint256 debt = teamRewardDebt;
    //     uint256 pending = accumulated > debt ? accumulated - debt : 0;

    //     if (pending > 0) {
    //         teamUnpaid += pending;
    //     }
    //     _resetTeamDebt();
    // }

    function _resetDebt(uint64 _nodeId, address _user) internal {
        uint64[] storage days_ = userDays[_nodeId][_user];
        // uint256 acc = _nodeAcc(_nodeId);
        uint256 acc = accRewardPerShares[NODE_POOL_ID];
        for (uint256 i = 0; i < days_.length; i++) {
            _resetPositionDebt(_nodeId, _user, days_[i], acc);
        }
    }

    function _resetPositionDebt(
        uint64 _nodeId,
        address _user,
        uint64 _day,
        uint256 _acc
    ) internal {
        positions[_nodeId][_user][_day].rewardDebt = _positionAccumulated(
            _nodeId,
            _user,
            _day,
            _acc
        );
    }

    function _resetNodeCommissionDebt(uint64 _nodeId) internal {
        nodeDelegatedRewardDebt[_nodeId] = _nodeCommissionAccumulated(
            _nodeId,
            // _nodeAcc(_nodeId)
            accRewardPerShares[NODE_POOL_ID]
        );
    }

    // function _resetLlmDebt(address _user) internal {
    //     llmUserRewardDebt[_user] =
    //         (llmUserAmount[_user] * accRewardPerShares[LLM_POOL_ID]) /
    //         ACC_PRECISION;
    // }

    // function _resetTeamDebt() internal {
    //     teamRewardDebt =
    //         (TEAM_SHARE * accRewardPerShares[TEAM_POOL_ID]) /
    //         ACC_PRECISION;
    // }

    /// @notice Emergency withdraw surplus DGAI (reward pool funds), user principal is protected.
    /// @dev Owner can only withdraw the amount exceeding totalPrincipal (user staked + pending unstake principal).
    ///     The `owner` is held by a multisig / Timelock contract in production , guarantee not to do evil.
    function emergencyWithdraw(
        address _target,
        uint256 _amount
    ) external onlyOwner {
        require(_target != address(0), "target is zero");
        require(_amount > 0, "amount is zero");

        uint256 balance = DGAI.balanceOf(address(this));
        uint256 withdrawable = balance > totalPrincipal
            ? balance - totalPrincipal
            : 0;
        require(_amount <= withdrawable, "exceeds withdrawable surplus");

        DGAI.safeTransfer(_target, _amount);
        emit EmergencyWithdraw(address(DGAI), _target, _amount);
    }

    function pause() external onlyOwner {
        updateNodePool();
        paused = true;
        emit Pause(true);
    }

    function unpause() external onlyOwner {
        updateNodePool();
        paused = false;
        emit Pause(false);
    }
}
