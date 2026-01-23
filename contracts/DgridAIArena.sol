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

contract DgridAIArena is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for ERC20;

    address public server;
    address[] public rewardTokens;
    bool public paused;

    mapping(address => bool) public isActivated;
    mapping(address => mapping(address => uint256)) public rewardAmount;
    mapping(address => mapping(address => uint256)) public rewardClaimedAmount;
    mapping(address => bool) public isRewardToken;
    mapping(uint256 => bool) public isRoundFulfilled;
    mapping(address => uint256) public totalOwed;

    struct Winner {
        address winner;
        address rewardToken;
        uint256 amount;
    }

    event Activated(address user);
    event UploadWinners(uint256 roundId, Winner[] winners);
    event ClaimReward(address user, address rewardToken, uint256 reward);
    event AddRewardToken(address rewardToken);

    event Pause(address operator, bool paused);
    event Unpause(address operator, bool unpaused);
    event EmergencyWithdraw(address to, address token, uint256 amount);
    event SetServer(address server);

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
        address[] memory _rewardTokens
    ) public initializer {
        //check params
        require(_owner != address(0), "owner is zero address");
        require(_server != address(0), "server is zero address");
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        server = _server;
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            require(
                _rewardTokens[i] != address(0),
                "reward token is zero address"
            );
            require(
                !isRewardToken[_rewardTokens[i]],
                "reward token already exists"
            );
            rewardTokens.push(_rewardTokens[i]);
            isRewardToken[_rewardTokens[i]] = true;
        }
    }

    function activate() external whenNotPaused {
        require(!isActivated[msg.sender], "user already activated");
        isActivated[msg.sender] = true;
        emit Activated(msg.sender);
    }

    function uploadWinners(
        uint256 _roundId,
        Winner[] calldata _winners
    ) external onlyServer whenNotPaused {
        require(!isRoundFulfilled[_roundId], "round already fulfilled");
        require(_winners.length > 0, "winners is empty");
        for (uint256 i = 0; i < _winners.length; i++) {
            require(isActivated[_winners[i].winner], "winner not activated");
            require(
                isRewardToken[_winners[i].rewardToken],
                "reward token is not supported"
            );
            require(_winners[i].amount > 0, "amount is zero");
            rewardAmount[_winners[i].winner][
                _winners[i].rewardToken
            ] += _winners[i].amount;
            totalOwed[_winners[i].rewardToken] += _winners[i].amount;
        }
        isRoundFulfilled[_roundId] = true;
        emit UploadWinners(_roundId, _winners);
    }

    function claimReward() external nonReentrant whenNotPaused {
        require(isActivated[msg.sender], "user not activated");
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            uint256 reward = rewardAmount[msg.sender][rewardTokens[i]];
            if (reward > 0) {
                rewardAmount[msg.sender][rewardTokens[i]] = 0;
                rewardClaimedAmount[msg.sender][rewardTokens[i]] += reward;
                totalOwed[rewardTokens[i]] -= reward;
                ERC20(rewardTokens[i]).safeTransfer(msg.sender, reward);
                emit ClaimReward(msg.sender, rewardTokens[i], reward);
            }
        }
    }

    function getShortfall(
        address _rewardToken
    ) external view returns (uint256) {
        return
            totalOwed[_rewardToken] >
                ERC20(_rewardToken).balanceOf(address(this))
                ? totalOwed[_rewardToken] -
                    ERC20(_rewardToken).balanceOf(address(this))
                : 0;
    }

    function addRewardToken(address _rewardToken) external onlyOwner {
        require(_rewardToken != address(0), "reward token is zero address");
        require(!isRewardToken[_rewardToken], "reward token already exists");
        rewardTokens.push(_rewardToken);
        isRewardToken[_rewardToken] = true;
        emit AddRewardToken(_rewardToken);
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
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            uint256 balance = ERC20(rewardTokens[i]).balanceOf(address(this));
            if (balance > 0) {
                ERC20(rewardTokens[i]).safeTransfer(to, balance);
                emit EmergencyWithdraw(to, rewardTokens[i], balance);
            }
        }
    }

    function setServer(address _server) external onlyOwner {
        require(_server != address(0), "server is zero address");
        server = _server;
        emit SetServer(_server);
    }

    function rewardTokensLength() external view returns (uint256) {
        return rewardTokens.length;
    }
}
