// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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
    uint8 public constant NODE_GROUP_ID = 0;
    uint8 public constant TEAM_GROUP_ID = 1;
    uint8 public constant LLM_GROUP_ID = 2;

    ERC20 public DGAI;

    // node stake status: FixedRate => NoReward => AccPerShare
    enum NodeStakeMode {
        FixedRate,
        NoReward,
        AccPerShare
    }

    bytes32 private constant ACTION_CREATE_NODE = keccak256("CREATENODE");

    struct StakingNode {
        string nodeName;
        uint256 amount;
        uint256 delegatorCount;
        uint256 commissionRate;
        ///  @dev nodeStatus lifecycle (reserved for future upgrade):x
        ///      contract upgrade logic by appending the nodeStatus field.
        // status: 0 => jail, 1 => active , expand ... depends on upgrade logic
        uint8 nodeStatus;
    }

    // groupId = 0 : node reward, 1 : team reward, 2 : llm reward
    struct GroupInfo {
        uint8 groupId;
        uint128 perSecondReward;
        uint64 lastRewardTime;
        uint256 totalStaked;
        bool enabled;
    }
    GroupInfo[] public groupInfos;
    // accRewardPerShares[0] : node reward, accRewardPerShares[1] : team reward, accRewardPerShares[2] : llm reward
    uint256[] public accRewardPerShares;
    /// @dev  The unallocated remainder from the previous division in each pool (multiplied by the ACC_PRECISION scale) is carried over to the next accumulation to avoid precision loss during high-frequency updates.
    uint256[] public accRewardRemainders;

    /// @notice Pending unstake request released after the cooling period
    struct PendingUnstake {
        uint256 amount;
        uint256 releaseTime;
    }

    /// @notice Node stake status
    NodeStakeMode public nodeRewardMode;
    /// Staking node map
    mapping(address => StakingNode) public stakingNodeMap;
    mapping(address => mapping(address => uint256)) public userAmount;
    mapping(address => mapping(address => uint256)) public userRewardDebt;
    mapping(address => mapping(address => uint256)) public userUnpaid;
    /// @dev Node commission unpaid
    mapping(address => uint256) public nodeCommissionUnpaid;
    mapping(address => uint256) public nodeDelegatedAmount;
    mapping(address => uint256) public nodeDelegatedRewardDebt;
    /// @notice pending unstake request.
    mapping(address => mapping(address => mapping(uint256 => PendingUnstake)))
        public pendingUnstake;
    /// @notice pending claim for node owner, delegator, llm user.
    mapping(address => mapping(address => uint256)) public lastTimeClaimNode;
    mapping(address => uint256) public lastTimeClaimNodeOwner;
    mapping(address => uint256) public lastTimeClaimLlm;

    mapping(address => uint256) public llmUserAmount;
    mapping(address => uint256) public llmUserRewardDebt;
    mapping(address => uint256) public llmUserUnpaid;
    mapping(address => mapping(uint256 => PendingUnstake))
        public pendingUnstakeLlm;

    uint256 public teamRewardDebt;
    uint256 public teamUnpaid;

    mapping(uint256 => bool) public signedNonce;

    uint256 public unstakedNonce; // next unstaked nonce
    uint256 public minNodeSelfStakeAmount;
    uint256 public minLlmStakeAmount;
    uint256 public minDelegatorStakeAmount;
    uint256 public totalStakingNodes;
    uint256 public totalStakedAmount;
    uint256 public totalDelegators;
    uint256 public llmTotalStakedAmount;
    uint256 public llmStakedCount;
    /// @dev Total user principal held by this contract (node + llm staked + pending unstake principal). Protected from emergencyWithdraw.
    uint256 public totalPrincipal;
    uint256 public llmCommissionRate; /// @dev the subsequent upgrade may not be zero.
    uint256 public teamNextClaimTime; // next team reward time for a 30 days

    uint64 public coolingUnstakeDay;
    uint64 public coolingTeamClaimDay;
    uint64 public coolingClaimDay; /// @notice cooling period for node owner, delegator, llm user to claim.
    uint64 public annualRewardRate; // rate of 365 days per year

    address public server;
    address public dev;
    bool public paused;

    event CreateStakingNode(
        address indexed owner,
        string nodeName,
        uint256 amount,
        uint256 commissionRate
    );
    event Pause(bool paused);
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
    event SetAnnualRewardRate(uint64 newValue);
    event SetGroupPerSecondReward(
        uint8 indexed groupId,
        uint128 oldValue,
        uint128 newValue
    );
    event SetGroupEnabled(uint8 indexed groupId, bool oldValue, bool newValue);
    event SetCoolingUnstakeDay(uint64 oldValue, uint64 newValue);
    event SetCoolingTeamClaimDay(uint64 oldValue, uint64 newValue);
    event SetLlmCommissionRate(uint256 oldValue, uint256 newValue);
    event SetCoolingClaimDay(uint64 oldValue, uint64 newValue);
    event SwitchNodeRewardMode(
        NodeStakeMode indexed oldMode,
        NodeStakeMode indexed newMode
    );
    event SetServer(address indexed server);
    event EmergencyWithdraw(
        address indexed token,
        address indexed target,
        uint256 amount
    );

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

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _DGAI,
        address _owner,
        uint256 _minNodeSelfStakeAmount,
        uint256 _minLlmStakeAmount,
        uint256 _minDelegatorStakeAmount,
        uint64 _coolingUnstakeDay, // 180 days
        uint64 _coolingClaimDay, // 7 days
        uint64 _coolingTeamClaimDay, // 30 days
        uint64 _annualRewardRate,
        GroupInfo[] memory _groupInfos,
        address _server,
        address _dev
    ) external initializer {
        require(_DGAI != address(0), "DGAI is zero");
        require(_owner != address(0), "owner is zero");
        require(_server != address(0), "server is zero");
        require(_dev != address(0), "dev is zero");
        require(
            _minNodeSelfStakeAmount > 0 &&
                _minLlmStakeAmount > 0 &&
                _minDelegatorStakeAmount > 0,
            "minimum stake amount is zero"
        );
        require(_groupInfos.length == 3, "group length mismatch");

        ///  @notice  The `owner` is held by a multisig / Timelock contract in production , guarantee not to do evil.
        __Ownable_init(_owner);
        __ReentrancyGuard_init();

        DGAI = ERC20(_DGAI);
        minNodeSelfStakeAmount = _minNodeSelfStakeAmount;
        minLlmStakeAmount = _minLlmStakeAmount;
        minDelegatorStakeAmount = _minDelegatorStakeAmount;
        coolingUnstakeDay = _coolingUnstakeDay;
        coolingClaimDay = _coolingClaimDay;
        coolingTeamClaimDay = _coolingTeamClaimDay;
        annualRewardRate = _annualRewardRate;

        server = _server;
        dev = _dev;
        nodeRewardMode = NodeStakeMode.FixedRate;

        for (uint256 i = 0; i < _groupInfos.length; i++) {
            require(_groupInfos[i].groupId == i, "group id mismatch");
            GroupInfo memory group = _groupInfos[i];
            group.lastRewardTime = uint64(block.timestamp);
            /// @dev Team uses a fixed virtual stake so it can share the accPerShare model.
            group.totalStaked = group.groupId == TEAM_GROUP_ID ? TEAM_SHARE : 0;
            groupInfos.push(group);
            accRewardPerShares.push(0);
            accRewardRemainders.push(0);
        }
    }

    /// @notice Create a new staking node for server signature.
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
        require(_commissionRate <= 2000, "invalid commissionrate");
        require(!signedNonce[_nonce], "nonce is signed");

        signedNonce[_nonce] = true;

        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(
            abi.encode(
                block.chainid,
                address(this),
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

        updateNodePool();
        DGAI.safeTransferFrom(msg.sender, address(this), _amount);

        StakingNode storage node = stakingNodeMap[_staker];
        node.nodeStatus = 1; // active staking
        node.nodeName = _nodeName;
        node.amount = _amount;
        node.commissionRate = _commissionRate;
        node.delegatorCount = 1;

        userAmount[_staker][_staker] = _amount;
        totalStakingNodes++;
        totalDelegators++;
        totalStakedAmount += _amount;
        groupInfos[NODE_GROUP_ID].totalStaked = totalStakedAmount;

        _resetDebt(_staker, _staker);
        _resetNodeCommissionDebt(_staker);

        totalPrincipal += _amount;

        emit CreateStakingNode(_staker, _nodeName, _amount, _commissionRate);
        emit Stake(_staker, _staker, _amount);
    }

    /// delegater choose a node to stake.
    function stake(
        address _node,
        uint256 _amount
    ) external nodeExists(_node) nonReentrant whenNotPaused {
        require(_amount >= minDelegatorStakeAmount, "amount below minimum");

        StakingNode storage node = stakingNodeMap[_node];
        require(node.nodeStatus == 1, "node not staking");
        updateNodePool();
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
        groupInfos[NODE_GROUP_ID].totalStaked = totalStakedAmount;

        _resetDebt(_node, msg.sender);
        if (msg.sender != _node) {
            nodeDelegatedAmount[_node] += _amount;
            _resetNodeCommissionDebt(_node);
        }

        totalPrincipal += _amount;

        emit Stake(_node, msg.sender, _amount);
    }

    // llm user stake
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
        groupInfos[LLM_GROUP_ID].totalStaked = llmTotalStakedAmount;

        _resetLlmDebt(msg.sender);
        totalPrincipal += _amount;
        emit StakeLlm(msg.sender, _amount);
    }

    function unstake(
        address _node,
        uint256 _amount
    ) external nodeExists(_node) nonReentrant {
        require(_amount > 0, "amount is zero");
        require(
            _amount <= userAmount[_node][msg.sender],
            "insufficient staked"
        );
        if (msg.sender == _node) {
            uint256 remaining = userAmount[_node][msg.sender] - _amount;
            require(
                remaining >= minNodeSelfStakeAmount,
                "self stake below minimum"
            );
        }

        updateNodePool();
        _accrueUnpaid(_node, msg.sender);
        if (msg.sender != _node) {
            _accrueNodeCommission(_node);
        }

        uint256 stakedAmountBefore = userAmount[_node][msg.sender];
        uint256 earned = 0;
        if (stakedAmountBefore > 0) {
            earned =
                (userUnpaid[_node][msg.sender] * _amount) /
                stakedAmountBefore;
            userUnpaid[_node][msg.sender] -= earned;
        }

        userAmount[_node][msg.sender] -= _amount;

        StakingNode storage node = stakingNodeMap[_node];
        node.amount -= _amount;
        if (userAmount[_node][msg.sender] == 0 && node.delegatorCount > 0) {
            node.delegatorCount--;
            totalDelegators--;
        }

        totalStakedAmount -= _amount;
        groupInfos[NODE_GROUP_ID].totalStaked = totalStakedAmount;

        _resetDebt(_node, msg.sender);
        if (msg.sender != _node) {
            nodeDelegatedAmount[_node] -= _amount;
            _resetNodeCommissionDebt(_node);
        }

        uint256 releaseAt = block.timestamp +
            (uint256(coolingUnstakeDay) * 1 days);
        uint256 requestId = unstakedNonce++;
        pendingUnstake[_node][msg.sender][requestId] = PendingUnstake({
            amount: _amount,
            releaseTime: releaseAt
        });

        if (earned > 0) {
            DGAI.safeTransfer(msg.sender, earned);
        }

        emit Unstake(_node, msg.sender, requestId, _amount, earned, releaseAt);
    }

    function unstakeLlm(uint256 _amount) external nonReentrant {
        require(_amount > 0, "amount is zero");
        require(_amount <= llmUserAmount[msg.sender], "insufficient staked");

        updateLlmPool();
        _accrueLlmUnpaid(msg.sender);

        uint256 stakedAmountBefore = llmUserAmount[msg.sender];
        uint256 earned = 0;
        if (stakedAmountBefore > 0) {
            earned = (llmUserUnpaid[msg.sender] * _amount) / stakedAmountBefore;
            llmUserUnpaid[msg.sender] -= earned;
        }

        llmUserAmount[msg.sender] -= _amount;
        llmTotalStakedAmount -= _amount;
        if (llmUserAmount[msg.sender] == 0 && llmStakedCount > 0) {
            llmStakedCount--;
        }
        groupInfos[LLM_GROUP_ID].totalStaked = llmTotalStakedAmount;

        _resetLlmDebt(msg.sender);

        uint256 releaseAt = block.timestamp +
            (uint256(coolingUnstakeDay) * 1 days);
        uint256 requestId = unstakedNonce++;
        pendingUnstakeLlm[msg.sender][requestId] = PendingUnstake({
            amount: _amount,
            releaseTime: releaseAt
        });

        if (earned > 0) {
            DGAI.safeTransfer(msg.sender, earned);
        }

        emit UnstakeLlm(msg.sender, requestId, _amount, earned, releaseAt);
    }

    function claim(address _node) external nodeExists(_node) nonReentrant {
        require(
            block.timestamp >=
                lastTimeClaimNode[_node][msg.sender] +
                    (uint256(coolingClaimDay) * 1 days),
            "claim cooling"
        );
        updateNodePool();
        _accrueUnpaid(_node, msg.sender);

        uint256 amount = userUnpaid[_node][msg.sender];
        require(
            amount + totalPrincipal <= DGAI.balanceOf(address(this)),
            "pool insufficient balance"
        );

        userUnpaid[_node][msg.sender] = 0;
        lastTimeClaimNode[_node][msg.sender] = block.timestamp;
        DGAI.safeTransfer(msg.sender, amount);

        emit Claim(_node, msg.sender, amount);
    }

    function claimUnstake(
        address _node,
        uint256 _requestId
    ) external nodeExists(_node) nonReentrant {
        PendingUnstake storage req = pendingUnstake[_node][msg.sender][
            _requestId
        ];
        uint256 amount = req.amount;

        require(amount > 0, "no pending unstake");
        require(block.timestamp >= req.releaseTime, "cooling not finished");

        delete pendingUnstake[_node][msg.sender][_requestId];
        totalPrincipal -= amount;
        DGAI.safeTransfer(msg.sender, amount);

        emit ClaimUnstake(_node, msg.sender, _requestId, amount);
    }

    function claimNodeCommission() external nonReentrant {
        require(
            block.timestamp >=
                lastTimeClaimNodeOwner[msg.sender] +
                    (uint256(coolingClaimDay) * 1 days),
            "claim cooling"
        );
        updateNodePool();
        _accrueNodeCommission(msg.sender);

        uint256 amount = nodeCommissionUnpaid[msg.sender];
        require(
            amount + totalPrincipal <= DGAI.balanceOf(address(this)),
            "pool insufficient balance"
        );

        nodeCommissionUnpaid[msg.sender] = 0;
        lastTimeClaimNodeOwner[msg.sender] = block.timestamp;
        DGAI.safeTransfer(msg.sender, amount);

        emit ClaimCommission(msg.sender, amount);
    }

    function claimTeamReward(address _target) external nonReentrant {
        require(msg.sender == dev, "only dev can claim");
        require(_target != address(0), "target is zero");
        require(block.timestamp >= teamNextClaimTime, "team claim cooling");

        updateTeamPool();
        _accrueTeamUnpaid(); /// built-in resetDebt function

        uint256 amount = teamUnpaid;
        require(
            amount + totalPrincipal <= DGAI.balanceOf(address(this)),
            "pool insufficient balance"
        );

        teamUnpaid = 0;

        teamNextClaimTime =
            block.timestamp +
            (uint256(coolingTeamClaimDay) * 1 days);

        DGAI.safeTransfer(_target, amount);
        emit ClaimTeamReward(_target, amount, teamNextClaimTime);
    }

    function claimLlm() external nonReentrant {
        require(
            block.timestamp >=
                lastTimeClaimLlm[msg.sender] +
                    (uint256(coolingClaimDay) * 1 days),
            "claim cooling"
        );
        updateLlmPool();
        _accrueLlmUnpaid(msg.sender);

        uint256 amount = llmUserUnpaid[msg.sender];
        require(
            amount + totalPrincipal <= DGAI.balanceOf(address(this)),
            "pool insufficient balance"
        );

        llmUserUnpaid[msg.sender] = 0;
        _resetLlmDebt(msg.sender);
        lastTimeClaimLlm[msg.sender] = block.timestamp;

        DGAI.safeTransfer(msg.sender, amount);

        emit ClaimLlm(msg.sender, amount);
    }

    function claimUnstakeLlm(uint256 _requestId) external nonReentrant {
        PendingUnstake storage req = pendingUnstakeLlm[msg.sender][_requestId];
        uint256 amount = req.amount;

        require(amount > 0, "no pending unstake");
        require(block.timestamp >= req.releaseTime, "cooling not finished");

        delete pendingUnstakeLlm[msg.sender][_requestId];
        totalPrincipal -= amount;
        DGAI.safeTransfer(msg.sender, amount);

        emit ClaimUnstakeLlm(msg.sender, _requestId, amount);
    }

    function updateNodePool() public {
        _updateGroup(NODE_GROUP_ID);
    }

    function updateTeamPool() public {
        _updateGroup(TEAM_GROUP_ID);
    }

    function updateLlmPool() public {
        _updateGroup(LLM_GROUP_ID);
    }

    function pendingReward(
        address _node,
        address _user
    ) external view returns (uint256) {
        uint256 amount = userAmount[_node][_user];
        uint256 pending = userUnpaid[_node][_user];
        if (amount == 0) {
            return pending;
        }

        uint256 accumulated = (amount * _previewNodeAccRewardPerShare()) /
            ACC_PRECISION;
        uint256 debt = userRewardDebt[_node][_user];
        uint256 pendingGross = accumulated > debt ? accumulated - debt : 0;

        if (_user != _node) {
            uint256 commissionRate = stakingNodeMap[_node].commissionRate;
            pendingGross =
                (pendingGross * (BPS_DENOMINATOR - commissionRate)) /
                BPS_DENOMINATOR;
        }

        return pending + pendingGross;
    }

    function pendingNodeCommission(
        address _node
    ) external view returns (uint256) {
        uint256 delegatedAmount = nodeDelegatedAmount[_node];
        if (delegatedAmount == 0) {
            return nodeCommissionUnpaid[_node];
        }

        uint256 accumulated = (delegatedAmount *
            _previewNodeAccRewardPerShare()) / ACC_PRECISION;
        uint256 debt = nodeDelegatedRewardDebt[_node];
        uint256 gross = accumulated > debt ? accumulated - debt : 0;
        uint256 fee = (gross * stakingNodeMap[_node].commissionRate) /
            BPS_DENOMINATOR;

        return nodeCommissionUnpaid[_node] + fee;
    }

    function pendingLlmReward(address _user) external view returns (uint256) {
        uint256 amount = llmUserAmount[_user];
        uint256 pending = llmUserUnpaid[_user];
        if (amount == 0) {
            return pending;
        }

        uint256 accumulated = (amount *
            _previewGroupAccRewardPerShare(LLM_GROUP_ID)) / ACC_PRECISION;
        uint256 debt = llmUserRewardDebt[_user];
        uint256 gross = accumulated > debt ? accumulated - debt : 0;

        return pending + gross;
    }

    function pendingTeamReward() external view returns (uint256) {
        uint256 accumulated = (TEAM_SHARE *
            _previewGroupAccRewardPerShare(TEAM_GROUP_ID)) / ACC_PRECISION;
        uint256 debt = teamRewardDebt;
        uint256 gross = accumulated > debt ? accumulated - debt : 0;

        return teamUnpaid + gross;
    }

    function getAccPershareLen() external view returns (uint256) {
        return accRewardPerShares.length;
    }

    function getGroupInfoLen() external view returns (uint256) {
        return groupInfos.length;
    }

    function getAnnualStakingEmission(
        uint256 _groupId
    ) external view returns (uint256 released) {
        require(_groupId < groupInfos.length, "invalid group");

        if (_groupId == NODE_GROUP_ID) {
            if (nodeRewardMode == NodeStakeMode.FixedRate) {
                return
                    (totalStakedAmount * uint256(annualRewardRate)) /
                    BPS_DENOMINATOR;
            }
            if (nodeRewardMode == NodeStakeMode.NoReward) {
                return 0;
            }
        }

        if (!groupInfos[_groupId].enabled) {
            return 0;
        }

        return uint256(groupInfos[_groupId].perSecondReward) * 365 days;
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

    function setCoolingUnstakeDay(
        uint64 _coolingUnstakeDay
    ) external onlyOwner {
        emit SetCoolingUnstakeDay(coolingUnstakeDay, _coolingUnstakeDay);
        coolingUnstakeDay = _coolingUnstakeDay;
    }

    function setCoolingTeamClaimDay(
        uint64 _coolingTeamClaimDay
    ) external onlyOwner {
        emit SetCoolingTeamClaimDay(coolingTeamClaimDay, _coolingTeamClaimDay);
        coolingTeamClaimDay = _coolingTeamClaimDay;
    }

    function setCoolClaimDay(uint64 _coolingClaimDay) external onlyOwner {
        emit SetCoolingClaimDay(coolingClaimDay, _coolingClaimDay);
        coolingClaimDay = _coolingClaimDay;
    }

    function setAnnualRewardRate(uint64 _rate) external onlyOwner {
        require(nodeRewardMode == NodeStakeMode.FixedRate, "not fixedRate");
        updateNodePool();
        annualRewardRate = _rate;
        emit SetAnnualRewardRate(_rate);
    }

    // function setLlmCommissionRate(uint256 _rate) external onlyOwner {
    //     require(_rate <= BPS_DENOMINATOR, "invalid rate");
    //     emit SetLlmCommissionRate(llmCommissionRate, _rate);
    //     llmCommissionRate = _rate;
    // }

    function setGroupPerSecondReward(
        uint8 _groupId,
        uint128 _perSecondReward
    ) external onlyOwner {
        require(_groupId < groupInfos.length, "group not exist");
        _updateGroup(_groupId);
        uint128 oldValue = groupInfos[_groupId].perSecondReward;
        groupInfos[_groupId].perSecondReward = _perSecondReward;
        emit SetGroupPerSecondReward(_groupId, oldValue, _perSecondReward);
    }

    function setGroupEnabled(uint8 _groupId, bool _enabled) external onlyOwner {
        require(_groupId < groupInfos.length, "group not exist");
        _updateGroup(_groupId);
        bool oldValue = groupInfos[_groupId].enabled;
        groupInfos[_groupId].enabled = _enabled;
        emit SetGroupEnabled(_groupId, oldValue, _enabled);
    }

    /// @notice fixedRate => noReward => accPerShare
    // switch node reward mode to no reward
    function switchNodeRewardModeToNoReward() external onlyOwner {
        require(
            nodeRewardMode == NodeStakeMode.FixedRate,
            "mode must be fixedRate"
        );
        updateNodePool();
        NodeStakeMode oldMode = nodeRewardMode;
        nodeRewardMode = NodeStakeMode.NoReward;
        emit SwitchNodeRewardMode(oldMode, NodeStakeMode.NoReward);
    }

    // switch node reward mode to acc per share
    function switchNodeRewardModeToAccPerShare() external onlyOwner {
        require(
            nodeRewardMode == NodeStakeMode.NoReward,
            "mode must be noReward"
        );
        updateNodePool();
        NodeStakeMode oldMode = nodeRewardMode;
        nodeRewardMode = NodeStakeMode.AccPerShare;
        emit SwitchNodeRewardMode(oldMode, NodeStakeMode.AccPerShare);
    }

    function setServer(address _server) external onlyOwner {
        require(_server != address(0), "server is zero");
        server = _server;
        emit SetServer(_server);
    }

    function setDev(address _dev) external onlyOwner {
        dev = _dev;
    }

    function _updateGroup(uint8 _groupId) internal {
        GroupInfo storage group = groupInfos[_groupId];
        uint256 nowTs = block.timestamp;
        if (nowTs <= group.lastRewardTime) {
            return;
        }

        if (paused || !group.enabled || group.totalStaked == 0) {
            group.lastRewardTime = uint64(nowTs);
            return;
        }

        uint256 dt = nowTs - group.lastRewardTime;
        uint256 deltaAcc = 0;

        if (
            _groupId == NODE_GROUP_ID &&
            nodeRewardMode == NodeStakeMode.FixedRate
        ) {
            uint256 denominator = BPS_DENOMINATOR * 365 days;
            uint256 numerator = uint256(annualRewardRate) *
                dt *
                ACC_PRECISION +
                accRewardRemainders[_groupId];
            deltaAcc = numerator / denominator;
            // keep the remainder for next time
            accRewardRemainders[_groupId] = numerator % denominator;
        } else {
            if (
                _groupId == NODE_GROUP_ID &&
                nodeRewardMode == NodeStakeMode.NoReward
            ) {
                group.lastRewardTime = uint64(nowTs);
                return;
            }

            // scaled = perSecond * dt * ACC_PRECISION + remainder,
            // then scaled / totalStaked = deltaAcc + new remainder
            uint256 scaled = uint256(group.perSecondReward) *
                dt *
                ACC_PRECISION +
                accRewardRemainders[_groupId];
            deltaAcc = scaled / group.totalStaked;
            accRewardRemainders[_groupId] = scaled % group.totalStaked;
        }

        if (deltaAcc > 0) {
            accRewardPerShares[_groupId] += deltaAcc;
        }
        group.lastRewardTime = uint64(nowTs);
    }

    function _previewGroupAccRewardPerShare(
        uint8 _groupId
    ) internal view returns (uint256) {
        GroupInfo storage group = groupInfos[_groupId];
        uint256 acc = accRewardPerShares[_groupId];
        uint256 nowTs = block.timestamp;

        if (
            paused ||
            nowTs <= group.lastRewardTime ||
            !group.enabled ||
            group.totalStaked == 0
        ) {
            return acc;
        }

        uint256 dt = nowTs - group.lastRewardTime;
        uint256 deltaAcc = 0;

        if (
            _groupId == NODE_GROUP_ID &&
            nodeRewardMode == NodeStakeMode.FixedRate
        ) {
            uint256 denominator = BPS_DENOMINATOR * 365 days;
            uint256 numerator = uint256(annualRewardRate) *
                dt *
                ACC_PRECISION +
                accRewardRemainders[_groupId];
            deltaAcc = numerator / denominator;
        } else {
            if (
                _groupId == NODE_GROUP_ID &&
                nodeRewardMode == NodeStakeMode.NoReward
            ) {
                return acc;
            }

            uint256 scaled = uint256(group.perSecondReward) *
                dt *
                ACC_PRECISION +
                accRewardRemainders[_groupId];
            deltaAcc = scaled / group.totalStaked;
        }

        return acc + deltaAcc;
    }

    function _previewNodeAccRewardPerShare() internal view returns (uint256) {
        return _previewGroupAccRewardPerShare(NODE_GROUP_ID);
    }

    function _accrueUnpaid(address _node, address _user) internal {
        uint256 amount = userAmount[_node][_user];
        if (amount == 0) {
            return;
        }

        uint256 accumulated = (amount * accRewardPerShares[NODE_GROUP_ID]) /
            ACC_PRECISION;
        uint256 debt = userRewardDebt[_node][_user];
        uint256 pendingGross = accumulated > debt ? accumulated - debt : 0;

        if (_user != _node) {
            uint256 commissionRate = stakingNodeMap[_node].commissionRate;
            pendingGross =
                (pendingGross * (BPS_DENOMINATOR - commissionRate)) /
                BPS_DENOMINATOR;
        }

        if (pendingGross > 0) {
            userUnpaid[_node][_user] += pendingGross;
        }
        _resetDebt(_node, _user);
    }

    function _accrueNodeCommission(address _node) internal {
        uint256 delegatedAmount = nodeDelegatedAmount[_node];
        if (delegatedAmount == 0) {
            _resetNodeCommissionDebt(_node);
            return;
        }

        uint256 accumulated = (delegatedAmount *
            accRewardPerShares[NODE_GROUP_ID]) / ACC_PRECISION;
        uint256 debt = nodeDelegatedRewardDebt[_node];
        uint256 gross = accumulated > debt ? accumulated - debt : 0;
        uint256 fee = (gross * stakingNodeMap[_node].commissionRate) /
            BPS_DENOMINATOR;

        if (fee > 0) {
            nodeCommissionUnpaid[_node] += fee;
        }
        _resetNodeCommissionDebt(_node);
    }

    function _accrueLlmUnpaid(address _user) internal {
        uint256 amount = llmUserAmount[_user];
        if (amount == 0) {
            return;
        }

        uint256 accumulated = (amount * accRewardPerShares[LLM_GROUP_ID]) /
            ACC_PRECISION;
        uint256 debt = llmUserRewardDebt[_user];
        uint256 pending = accumulated > debt ? accumulated - debt : 0;

        if (pending > 0) {
            llmUserUnpaid[_user] += pending;
        }
        _resetLlmDebt(_user);
    }

    function _accrueTeamUnpaid() internal {
        uint256 accumulated = (TEAM_SHARE * accRewardPerShares[TEAM_GROUP_ID]) /
            ACC_PRECISION;
        uint256 debt = teamRewardDebt;
        uint256 pending = accumulated > debt ? accumulated - debt : 0;

        if (pending > 0) {
            teamUnpaid += pending;
        }
        _resetTeamDebt();
    }

    function _resetDebt(address _node, address _user) internal {
        userRewardDebt[_node][_user] =
            (userAmount[_node][_user] * accRewardPerShares[NODE_GROUP_ID]) /
            ACC_PRECISION;
    }

    function _resetNodeCommissionDebt(address _node) internal {
        nodeDelegatedRewardDebt[_node] =
            (nodeDelegatedAmount[_node] * accRewardPerShares[NODE_GROUP_ID]) /
            ACC_PRECISION;
    }

    function _resetLlmDebt(address _user) internal {
        llmUserRewardDebt[_user] =
            (llmUserAmount[_user] * accRewardPerShares[LLM_GROUP_ID]) /
            ACC_PRECISION;
    }

    function _resetTeamDebt() internal {
        teamRewardDebt =
            (TEAM_SHARE * accRewardPerShares[TEAM_GROUP_ID]) /
            ACC_PRECISION;
    }

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
        updateLlmPool();
        updateTeamPool();
        paused = true;
        emit Pause(true);
    }

    function unpause() external onlyOwner {
        updateNodePool();
        updateLlmPool();
        updateTeamPool();
        paused = false;
        emit Pause(false);
    }
}
