// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title PonsV2BurnMode
 * @author Pons.Family
 * @notice Experimental Burn Mode proposal for Pons V2.
 *
 * @dev
 * Burn Mode introduces an alternative destination for creator/developer fees:
 *
 *      DEV FEES
 *          |
 *          v
 *      FEE SOURCE
 *          |
 *        CLAIM
 *          |
 *          v
 *    BURN CONTROLLER
 *          |
 *       BUYBACK
 *          |
 *          v
 *       $TOKEN
 *          |
 *          v
 *     BURN WALLET
 *
 * The contract is intentionally standalone and acts as a proposal/testing
 * implementation. It does not modify the existing Pons V2 architecture.
 *
 * The production integration can later replace the fee source and buyback
 * adapter with the native Pons V2 fee/buyback mechanisms.
 *
 * IMPORTANT:
 * Tokens are sent to the immutable burn wallet rather than relying on an
 * ERC20 `burn()` implementation. The destination is permanently fixed at
 * deployment.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*//////////////////////////////////////////////////////////////
                            INTERFACES
//////////////////////////////////////////////////////////////*/

interface IPonsBurnFeeSource {
    /**
     * @notice Claims all available developer fees to msg.sender.
     *
     * @return amount Amount of quote asset claimed.
     */
    function claimFees() external returns (uint256 amount);

    /**
     * @notice Quote asset used by the fee source.
     */
    function quoteToken() external view returns (address);

    /**
     * @notice Launch token associated with the fees.
     */
    function token() external view returns (address);
}

interface IPonsBurnBuybackRouter {
    /**
     * @notice Executes a token buyback.
     *
     * @param token Token to purchase.
     * @param quoteToken Asset used to purchase the token.
     * @param quoteAmount Amount of quote asset to spend.
     * @param minTokenOut Minimum acceptable token output.
     *
     * @return tokenOut Amount of tokens purchased.
     */
    function buyback(
        address token,
        address quoteToken,
        uint256 quoteAmount,
        uint256 minTokenOut
    ) external returns (uint256 tokenOut);

    /**
     * @notice Returns the estimated output of a buyback.
     */
    function quoteBuyback(
        address token,
        address quoteToken,
        uint256 quoteAmount
    ) external view returns (uint256 tokenOut);
}

/*//////////////////////////////////////////////////////////////
                         PONS V2 BURN MODE
//////////////////////////////////////////////////////////////*/

contract PonsV2BurnMode is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BPS = 10_000;

    /**
     * @notice Permanent Pons Burn Wallet.
     *
     * This address is immutable and cannot be changed after deployment.
     */
    address public constant BURN_WALLET =
        0xDEAD83a9C5bCBaECe8300BEC83E85f25B2d0273F;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Token being bought back.
     */
    address public immutable token;

    /**
     * @notice Quote asset used to perform the buyback.
     */
    address public immutable quoteToken;

    /**
     * @notice Contract responsible for claiming developer fees.
     */
    address public immutable feeSource;

    /**
     * @notice Contract responsible for executing the buyback.
     */
    address public immutable buybackRouter;

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Whether Burn Mode is currently enabled.
     */
    bool public enabled;

    /**
     * @notice Total amount of developer fees claimed.
     */
    uint256 public totalFeesClaimed;

    /**
     * @notice Total amount of quote asset spent on buybacks.
     */
    uint256 public totalQuoteSpent;

    /**
     * @notice Total amount of tokens sent to the burn wallet.
     */
    uint256 public totalBurned;

    /**
     * @notice Number of successful buyback/burn executions.
     */
    uint256 public executionCount;

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidToken();
    error InvalidQuoteToken();
    error InvalidFeeSource();
    error InvalidBuybackRouter();

    error BurnModeDisabled();

    error NoFeesAvailable();
    error NoTokensReceived();
    error NothingToBurn();

    error InvalidQuoteAmount();
    error InsufficientQuoteBalance();
    error SlippageExceeded();

    error UnexpectedToken();
    error UnexpectedQuoteToken();

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event BurnModeEnabled();

    event BurnModeDisabled();

    event FeesClaimed(
        address indexed feeSource,
        uint256 amount
    );

    event BuybackExecuted(
        address indexed token,
        uint256 quoteSpent,
        uint256 tokenReceived
    );

    event TokensBurned(
        address indexed token,
        address indexed burnWallet,
        uint256 amount,
        uint256 cumulativeBurned
    );

    event BuybackAndBurnExecuted(
        address indexed token,
        uint256 feesClaimed,
        uint256 quoteSpent,
        uint256 tokensBought,
        uint256 tokensBurned
    );

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param initialOwner Administrative owner.
     * @param token_ Token being bought back and burned.
     * @param quoteToken_ Quote asset used by the buyback.
     * @param feeSource_ Developer-fee source.
     * @param buybackRouter_ Buyback execution adapter.
     */
    constructor(
        address initialOwner,
        address token_,
        address quoteToken_,
        address feeSource_,
        address buybackRouter_
    )
        Ownable(initialOwner)
    {
        if (initialOwner == address(0)) {
            revert ZeroAddress();
        }

        if (token_ == address(0)) {
            revert ZeroAddress();
        }

        if (quoteToken_ == address(0)) {
            revert ZeroAddress();
        }

        if (feeSource_ == address(0)) {
            revert ZeroAddress();
        }

        if (buybackRouter_ == address(0)) {
            revert ZeroAddress();
        }

        if (token_ == quoteToken_) {
            revert InvalidQuoteToken();
        }

        token = token_;
        quoteToken = quoteToken_;
        feeSource = feeSource_;
        buybackRouter = buybackRouter_;

        enabled = true;
    }

    /*//////////////////////////////////////////////////////////////
                         ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Enables Burn Mode.
     */
    function enable()
        external
        onlyOwner
    {
        enabled = true;

        emit BurnModeEnabled();
    }

    /**
     * @notice Disables Burn Mode.
     *
     * @dev
     * Already burned tokens remain permanently in the burn wallet.
     */
    function disable()
        external
        onlyOwner
    {
        enabled = false;

        emit BurnModeDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                          FEE CLAIMING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claims all available developer fees.
     *
     * @dev
     * The fee source must transfer the quote asset to this contract.
     */
    function claimFees()
        public
        nonReentrant
        returns (uint256 claimed)
    {
        if (!enabled) {
            revert BurnModeDisabled();
        }

        uint256 balanceBefore =
            IERC20(quoteToken).balanceOf(address(this));

        IPonsBurnFeeSource(feeSource).claimFees();

        uint256 balanceAfter =
            IERC20(quoteToken).balanceOf(address(this));

        if (balanceAfter <= balanceBefore) {
            revert NoFeesAvailable();
        }

        claimed = balanceAfter - balanceBefore;

        totalFeesClaimed += claimed;

        emit FeesClaimed(
            feeSource,
            claimed
        );
    }

    /*//////////////////////////////////////////////////////////////
                            BUYBACK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the estimated token output for a buyback.
     */
    function quoteBuyback(
        uint256 quoteAmount
    )
        public
        view
        returns (uint256 tokenOut)
    {
        if (quoteAmount == 0) {
            return 0;
        }

        tokenOut =
            IPonsBurnBuybackRouter(buybackRouter)
                .quoteBuyback(
                    token,
                    quoteToken,
                    quoteAmount
                );
    }

    /**
     * @notice Executes a buyback using quote tokens held by this contract.
     *
     * @param quoteAmount Amount of quote asset to spend.
     * @param minTokenOut Minimum amount of launch tokens accepted.
     *
     * @return tokensBought Number of tokens purchased.
     */
    function executeBuyback(
        uint256 quoteAmount,
        uint256 minTokenOut
    )
        public
        nonReentrant
        returns (uint256 tokensBought)
    {
        if (!enabled) {
            revert BurnModeDisabled();
        }

        if (quoteAmount == 0) {
            revert InvalidQuoteAmount();
        }

        uint256 quoteBalance =
            IERC20(quoteToken).balanceOf(address(this));

        if (quoteBalance < quoteAmount) {
            revert InsufficientQuoteBalance();
        }

        uint256 tokenBalanceBefore =
            IERC20(token).balanceOf(address(this));

        IERC20(quoteToken).forceApprove(
            buybackRouter,
            quoteAmount
        );

        IPonsBurnBuybackRouter(buybackRouter).buyback(
            token,
            quoteToken,
            quoteAmount,
            minTokenOut
        );

        uint256 tokenBalanceAfter =
            IERC20(token).balanceOf(address(this));

        if (tokenBalanceAfter <= tokenBalanceBefore) {
            revert NoTokensReceived();
        }

        tokensBought =
            tokenBalanceAfter - tokenBalanceBefore;

        if (tokensBought < minTokenOut) {
            revert SlippageExceeded();
        }

        IERC20(quoteToken).forceApprove(
            buybackRouter,
            0
        );

        totalQuoteSpent += quoteAmount;

        emit BuybackExecuted(
            token,
            quoteAmount,
            tokensBought
        );
    }

    /*//////////////////////////////////////////////////////////////
                              BURN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sends all tokens held by this contract to the permanent
     * burn wallet.
     *
     * @dev
     * The burn wallet is hard-coded as:
     *
     * 0xDEAD83a9C5bCBaECe8300BEC83E85f25B2d0273F
     *
     * There is intentionally no recovery mechanism for launch tokens
     * after they have been transferred to this address.
     */
    function burn()
        public
        nonReentrant
        returns (uint256 amount)
    {
        if (!enabled) {
            revert BurnModeDisabled();
        }

        amount =
            IERC20(token).balanceOf(address(this));

        if (amount == 0) {
            revert NothingToBurn();
        }

        IERC20(token).safeTransfer(
            BURN_WALLET,
            amount
        );

        totalBurned += amount;
        executionCount += 1;

        emit TokensBurned(
            token,
            BURN_WALLET,
            amount,
            totalBurned
        );
    }

    /*//////////////////////////////////////////////////////////////
                       COMPLETE BURN PIPELINE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Executes the complete Burn Mode lifecycle.
     *
     *      1. Claim developer fees
     *      2. Buy back the launch token
     *      3. Send bought-back tokens to the immutable burn wallet
     *
     * @param minTokenOut Minimum amount of tokens that must be received
     * from the buyback.
     *
     * @return feesClaimed Developer fees claimed.
     * @return quoteSpent Quote asset spent.
     * @return tokensBought Tokens purchased through buyback.
     * @return tokensBurned Tokens sent to the burn wallet.
     */
    function claimBuybackAndBurn(
        uint256 minTokenOut
    )
        external
        nonReentrant
        returns (
            uint256 feesClaimed,
            uint256 quoteSpent,
            uint256 tokensBought,
            uint256 tokensBurned
        )
    {
        if (!enabled) {
            revert BurnModeDisabled();
        }

        /*//////////////////////////////////////////////////////////////
                         STEP 1 — CLAIM FEES
        //////////////////////////////////////////////////////////////*/

        uint256 quoteBefore =
            IERC20(quoteToken).balanceOf(address(this));

        IPonsBurnFeeSource(feeSource).claimFees();

        uint256 quoteAfter =
            IERC20(quoteToken).balanceOf(address(this));

        if (quoteAfter <= quoteBefore) {
            revert NoFeesAvailable();
        }

        feesClaimed =
            quoteAfter - quoteBefore;

        totalFeesClaimed += feesClaimed;

        emit FeesClaimed(
            feeSource,
            feesClaimed
        );

        /*//////////////////////////////////////////////////////////////
                         STEP 2 — BUYBACK
        //////////////////////////////////////////////////////////////*/

        quoteSpent = feesClaimed;

        uint256 tokenBefore =
            IERC20(token).balanceOf(address(this));

        IERC20(quoteToken).forceApprove(
            buybackRouter,
            quoteSpent
        );

        IPonsBurnBuybackRouter(buybackRouter).buyback(
            token,
            quoteToken,
            quoteSpent,
            minTokenOut
        );

        uint256 tokenAfter =
            IERC20(token).balanceOf(address(this));

        if (tokenAfter <= tokenBefore) {
            revert NoTokensReceived();
        }

        tokensBought =
            tokenAfter - tokenBefore;

        if (tokensBought < minTokenOut) {
            revert SlippageExceeded();
        }

        IERC20(quoteToken).forceApprove(
            buybackRouter,
            0
        );

        totalQuoteSpent += quoteSpent;

        emit BuybackExecuted(
            token,
            quoteSpent,
            tokensBought
        );

        /*//////////////////////////////////////////////////////////////
                         STEP 3 — BURN
        //////////////////////////////////////////////////////////////*/

        tokensBurned =
            IERC20(token).balanceOf(address(this));

        if (tokensBurned == 0) {
            revert NothingToBurn();
        }

        IERC20(token).safeTransfer(
            BURN_WALLET,
            tokensBurned
        );

        totalBurned += tokensBurned;
        executionCount += 1;

        emit TokensBurned(
            token,
            BURN_WALLET,
            tokensBurned,
            totalBurned
        );

        emit BuybackAndBurnExecuted(
            token,
            feesClaimed,
            quoteSpent,
            tokensBought,
            tokensBurned
        );
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the quote asset currently held by the contract.
     */
    function availableFees()
        external
        view
        returns (uint256)
    {
        return IERC20(quoteToken).balanceOf(address(this));
    }

    /**
     * @notice Returns tokens waiting to be sent to the burn wallet.
     */
    function pendingBurn()
        external
        view
        returns (uint256)
    {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Returns the current token supply.
     */
    function currentSupply()
        external
        view
        returns (uint256)
    {
        return IERC20(token).totalSupply();
    }

    /**
     * @notice Returns the percentage of a reference supply that has
     * been sent to the burn wallet, expressed in basis points.
     *
     * Example:
     *
     * 10000 BPS = 100%
     *  1000 BPS = 10%
     */
    function burnedBps(
        uint256 referenceSupply
    )
        external
        view
        returns (uint256)
    {
        if (referenceSupply == 0) {
            return 0;
        }

        return
            (totalBurned * BPS) /
            referenceSupply;
    }

    /**
     * @notice Returns the complete immutable configuration.
     */
    function configuration()
        external
        view
        returns (
            address burnWallet,
            address tokenAddress,
            address quoteAsset,
            address feeSourceAddress,
            address buybackRouterAddress,
            bool burnModeEnabled
        )
    {
        return (
            BURN_WALLET,
            token,
            quoteToken,
            feeSource,
            buybackRouter,
            enabled
        );
    }

    /*//////////////////////////////////////////////////////////////
                         NATIVE TOKEN GUARD
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rejects accidental native ETH transfers.
     *
     * @dev
     * The Burn Mode proposal operates on ERC20 quote assets.
     * Native ETH should therefore not accumulate here.
     */
    receive() external payable {
        revert();
    }
}