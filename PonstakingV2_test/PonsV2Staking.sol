// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title PonsV2Staking
 * @notice Standalone experimental staking module for Pons V2.
 *
 * @dev
 * Users stake Pons tokens and earn Pons-denominated rewards over time.
 *
 * The reward pool is expected to be funded by the Ponstaking tax mechanism.
 * For the standalone testing implementation, the owner/reward distributor
 * can fund the contract through `notifyRewardAmount()`.
 *
 * Reward accounting follows a per-token accumulator model:
 *
 *     rewardPerTokenStored
 *
 * This allows rewards to accrue continuously and proportionally to each
 * user's stake and the time their capital remains in the pool.
 *
 * This contract is intentionally standalone and does not modify the
 * production Pons V2 contracts.
 */
contract PonsV2Staking is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant PRECISION = 1e18;
    uint256 public constant YEAR = 365 days;

    /**
     * @dev Default reward duration used by the testing deployment.
     *
     * A shorter duration makes reward funding cycles easy to test.
     */
    uint256 public constant DEFAULT_REWARD_DURATION = 30 days;

    /**
     * @dev Maximum reward duration accepted by the contract.
     *
     * Prevents accidental extremely long emissions.
     */
    uint256 public constant MAX_REWARD_DURATION = 365 days;

    /**
     * @dev Testing safety limit for the instantaneous reward rate.
     *
     * This is deliberately generous because this implementation is
     * intended for protocol testing.
     */
    uint256 public constant MAX_REWARD_RATE = 1e24;

    // -------------------------------------------------------------------------
    // Immutable configuration
    // -------------------------------------------------------------------------

    /**
     * @notice Token users stake and receive as rewards.
     */
    IERC20 public immutable stakingToken;

    /**
     * @notice Address allowed to fund the reward pool.
     *
     * In production this can be replaced by a dedicated tax collector,
     * fee escrow, or protocol rewards controller.
     */
    address public rewardDistributor;

    // -------------------------------------------------------------------------
    // Global staking state
    // -------------------------------------------------------------------------

    /**
     * @notice Total amount currently staked.
     */
    uint256 public totalStaked;

    /**
     * @notice Total rewards distributed through user claims.
     */
    uint256 public totalRewardsPaid;

    /**
     * @notice Total rewards ever funded into the contract.
     */
    uint256 public totalRewardsFunded;

    /**
     * @notice Current reward emission rate, denominated in tokens/second.
     */
    uint256 public rewardRate;

    /**
     * @notice Timestamp at which the current reward period ends.
     */
    uint256 public periodFinish;

    /**
     * @notice Last timestamp included in global reward accounting.
     */
    uint256 public lastUpdateTime;

    /**
     * @notice Accumulated rewards per staked token.
     *
     * Scaled by PRECISION.
     */
    uint256 public rewardPerTokenStored;

    // -------------------------------------------------------------------------
    // User state
    // -------------------------------------------------------------------------

    mapping(address => uint256) public balanceOf;

    mapping(address => uint256) public rewards;

    mapping(address => uint256) public userRewardPerTokenPaid;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Staked(
        address indexed account,
        uint256 amount,
        uint256 totalStaked
    );

    event Withdrawn(
        address indexed account,
        uint256 amount,
        uint256 totalStaked
    );

    event RewardPaid(
        address indexed account,
        uint256 reward
    );

    event RewardAdded(
        uint256 amount,
        uint256 rewardRate,
        uint256 duration,
        uint256 periodFinish
    );

    event RewardDistributorUpdated(
        address indexed previousDistributor,
        address indexed newDistributor
    );

    event Recovered(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param _stakingToken Pons token used for staking and rewards.
     * @param _rewardDistributor Initial address allowed to fund rewards.
     * @param _initialOwner Initial Ownable owner.
     */
    constructor(
        address _stakingToken,
        address _rewardDistributor,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(
            _stakingToken != address(0),
            "Staking: zero token"
        );

        require(
            _rewardDistributor != address(0),
            "Staking: zero distributor"
        );

        stakingToken = IERC20(_stakingToken);
        rewardDistributor = _rewardDistributor;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();

        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }

        _;
    }

    modifier onlyRewardDistributor() {
        require(
            msg.sender == rewardDistributor || msg.sender == owner(),
            "Staking: unauthorized distributor"
        );
        _;
    }

    // -------------------------------------------------------------------------
    // Staking
    // -------------------------------------------------------------------------

    /**
     * @notice Stake Pons tokens.
     * @param amount Amount of Pons to stake.
     */
    function stake(
        uint256 amount
    )
        external
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        require(
            amount > 0,
            "Staking: zero amount"
        );

        totalStaked += amount;
        balanceOf[msg.sender] += amount;

        stakingToken.safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        emit Staked(
            msg.sender,
            amount,
            totalStaked
        );
    }

    /**
     * @notice Withdraw staked Pons.
     * @param amount Amount to withdraw.
     */
    function withdraw(
        uint256 amount
    )
        public
        nonReentrant
        updateReward(msg.sender)
    {
        require(
            amount > 0,
            "Staking: zero amount"
        );

        require(
            balanceOf[msg.sender] >= amount,
            "Staking: insufficient stake"
        );

        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;

        stakingToken.safeTransfer(
            msg.sender,
            amount
        );

        emit Withdrawn(
            msg.sender,
            amount,
            totalStaked
        );
    }

    /**
     * @notice Claim accumulated staking rewards.
     */
    function getReward()
        public
        nonReentrant
        updateReward(msg.sender)
    {
        uint256 reward = rewards[msg.sender];

        if (reward == 0) {
            return;
        }

        rewards[msg.sender] = 0;
        totalRewardsPaid += reward;

        stakingToken.safeTransfer(
            msg.sender,
            reward
        );

        emit RewardPaid(
            msg.sender,
            reward
        );
    }

    /**
     * @notice Withdraw the stake and claim all rewards.
     */
    function exit()
        external
        nonReentrant
        updateReward(msg.sender)
    {
        uint256 staked = balanceOf[msg.sender];
        uint256 reward = rewards[msg.sender];

        require(
            staked > 0 || reward > 0,
            "Staking: nothing to exit"
        );

        if (staked > 0) {
            balanceOf[msg.sender] = 0;
            totalStaked -= staked;
        }

        if (reward > 0) {
            rewards[msg.sender] = 0;
            totalRewardsPaid += reward;
        }

        if (staked > 0) {
            stakingToken.safeTransfer(
                msg.sender,
                staked
            );
        }

        if (reward > 0) {
            stakingToken.safeTransfer(
                msg.sender,
                reward
            );
        }

        if (staked > 0) {
            emit Withdrawn(
                msg.sender,
                staked,
                totalStaked
            );
        }

        if (reward > 0) {
            emit RewardPaid(
                msg.sender,
                reward
            );
        }
    }

    /**
     * @notice Compound accumulated rewards back into the staking position.
     *
     * @dev
     * Since rewards and staking assets are the same token, compounding
     * requires no external approval and simply increases the user's stake.
     */
    function compound()
        external
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
    {
        uint256 reward = rewards[msg.sender];

        require(
            reward > 0,
            "Staking: no rewards"
        );

        rewards[msg.sender] = 0;

        balanceOf[msg.sender] += reward;
        totalStaked += reward;

        emit Staked(
            msg.sender,
            reward,
            totalStaked
        );
    }

    // -------------------------------------------------------------------------
    // Reward engine
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the last timestamp relevant for reward emission.
     */
    function lastTimeRewardApplicable()
        public
        view
        returns (uint256)
    {
        return block.timestamp < periodFinish
            ? block.timestamp
            : periodFinish;
    }

    /**
     * @notice Returns accumulated reward per staked token.
     */
    function rewardPerToken()
        public
        view
        returns (uint256)
    {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }

        uint256 elapsed =
            lastTimeRewardApplicable() - lastUpdateTime;

        return rewardPerTokenStored
            + (
                elapsed
                * rewardRate
                * PRECISION
                / totalStaked
            );
    }

    /**
     * @notice Returns a user's currently accrued rewards.
     */
    function earned(
        address account
    )
        public
        view
        returns (uint256)
    {
        return
            (
                balanceOf[account]
                * (
                    rewardPerToken()
                    - userRewardPerTokenPaid[account]
                )
                / PRECISION
            )
            + rewards[account];
    }

    /**
     * @notice Fund and start a new reward emission period.
     *
     * @dev
     * The caller must approve the staking contract for `amount`.
     *
     * If a previous reward period is still active, its undistributed
     * rewards are carried into the new emission period.
     */
    function notifyRewardAmount(
        uint256 amount,
        uint256 duration
    )
        external
        nonReentrant
        onlyRewardDistributor
        updateReward(address(0))
    {
        require(
            amount > 0,
            "Staking: zero reward"
        );

        require(
            duration > 0 &&
            duration <= MAX_REWARD_DURATION,
            "Staking: invalid duration"
        );

        uint256 leftover;

        if (block.timestamp < periodFinish) {
            leftover =
                (periodFinish - block.timestamp)
                * rewardRate;
        }

        uint256 totalReward =
            amount + leftover;

        uint256 newRewardRate =
            totalReward / duration;

        require(
            newRewardRate > 0,
            "Staking: rate too low"
        );

        require(
            newRewardRate <= MAX_REWARD_RATE,
            "Staking: rate too high"
        );

        stakingToken.safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        rewardRate = newRewardRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;

        totalRewardsFunded += amount;

        emit RewardAdded(
            amount,
            newRewardRate,
            duration,
            periodFinish
        );
    }

    /**
     * @notice Convenience function using the default 30-day reward period.
     */
    function notifyRewardAmount(
        uint256 amount
    )
        external
    {
        notifyRewardAmount(
            amount,
            DEFAULT_REWARD_DURATION
        );
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /**
     * @notice Estimated annualized APY for the current pool state.
     *
     * @dev
     * This is an instantaneous estimate based on:
     *
     *     rewardRate × 365 days / totalStaked
     *
     * It is NOT a guaranteed future yield.
     */
    function estimatedAPY()
        external
        view
        returns (uint256 apyBps)
    {
        if (totalStaked == 0) {
            return 0;
        }

        apyBps =
            rewardRate
            * YEAR
            * 10_000
            / totalStaked;
    }

    /**
     * @notice Returns a user's stake and accrued reward in one call.
     */
    function position(
        address account
    )
        external
        view
        returns (
            uint256 staked,
            uint256 pendingRewards,
            uint256 totalPosition
        )
    {
        staked = balanceOf[account];
        pendingRewards = earned(account);
        totalPosition = staked + pendingRewards;
    }

    /**
     * @notice Returns the amount of reward tokens currently held by
     * the contract.
     */
    function rewardBalance()
        external
        view
        returns (uint256)
    {
        return stakingToken.balanceOf(address(this));
    }

    /**
     * @notice Returns the currently committed undistributed reward amount.
     */
    function remainingRewardAllocation()
        public
        view
        returns (uint256)
    {
        if (block.timestamp >= periodFinish) {
            return 0;
        }

        return
            (periodFinish - block.timestamp)
            * rewardRate;
    }

    /**
     * @notice Returns whether the reward period is currently active.
     */
    function rewardPeriodActive()
        external
        view
        returns (bool)
    {
        return
            block.timestamp < periodFinish &&
            rewardRate > 0;
    }

    /**
     * @notice Returns the token address and current staking configuration.
     */
    function configuration()
        external
        view
        returns (
            address token,
            address distributor,
            uint256 currentRewardRate,
            uint256 currentPeriodFinish,
            uint256 currentTotalStaked
        )
    {
        token = address(stakingToken);
        distributor = rewardDistributor;
        currentRewardRate = rewardRate;
        currentPeriodFinish = periodFinish;
        currentTotalStaked = totalStaked;
    }

    // -------------------------------------------------------------------------
    // Administration
    // -------------------------------------------------------------------------

    /**
     * @notice Update the address allowed to fund reward emissions.
     */
    function setRewardDistributor(
        address newDistributor
    )
        external
        onlyOwner
    {
        require(
            newDistributor != address(0),
            "Staking: zero distributor"
        );

        address previous = rewardDistributor;

        rewardDistributor = newDistributor;

        emit RewardDistributorUpdated(
            previous,
            newDistributor
        );
    }

    /**
     * @notice Pause new staking and reward compounding.
     *
     * Withdrawals and reward claims remain available.
     */
    function pause()
        external
        onlyOwner
    {
        _pause();
    }

    /**
     * @notice Resume normal staking operations.
     */
    function unpause()
        external
        onlyOwner
    {
        _unpause();
    }

    /**
     * @notice Recover unrelated ERC20 tokens accidentally sent here.
     *
     * @dev
     * The staking token itself can never be recovered through this function.
     * This protects both user deposits and funded rewards.
     */
    function recoverERC20(
        address token,
        uint256 amount
    )
        external
        onlyOwner
    {
        require(
            token != address(stakingToken),
            "Staking: cannot recover staking token"
        );

        IERC20(token).safeTransfer(
            owner(),
            amount
        );

        emit Recovered(
            token,
            owner(),
            amount
        );
    }

    // -------------------------------------------------------------------------
    // Emergency withdrawal
    // -------------------------------------------------------------------------

    /**
     * @notice Emergency withdrawal without claiming rewards.
     *
     * @dev
     * This function intentionally does not update or distribute rewards.
     * The user's pending rewards remain forfeited.
     */
    function emergencyWithdraw()
        external
        nonReentrant
    {
        uint256 amount = balanceOf[msg.sender];

        require(
            amount > 0,
            "Staking: no stake"
        );

        balanceOf[msg.sender] = 0;
        totalStaked -= amount;

        rewards[msg.sender] = 0;
        userRewardPerTokenPaid[msg.sender] =
            rewardPerTokenStored;

        stakingToken.safeTransfer(
            msg.sender,
            amount
        );

        emit Withdrawn(
            msg.sender,
            amount,
            totalStaked
        );
    }

    // -------------------------------------------------------------------------
    // ETH handling
    // -------------------------------------------------------------------------

    receive() external payable {
        revert("Staking: no ETH");
    }

    fallback() external payable {
        revert("Staking: invalid call");
    }
}