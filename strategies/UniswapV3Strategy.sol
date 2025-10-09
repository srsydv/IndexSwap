// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "../utils/v7/SafeTransferLibV7.sol";
import "../interfaces/v7/IStrategyV7.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);

    function approve(address, uint256) external returns (bool);

    function transfer(address, uint256) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    function decimals() external view returns (uint8);
}

interface IExchangeHandler {
    // Implemented in your repo; routes swaps through whitelisted routers
    function swap(bytes calldata data) external returns (uint256 amountOut);
}

interface IOracleRouter {
    // Returns price of token in USD with 1e18 precision (or a common numeraire)
    function price(address token) external view returns (uint256);

    function isPriceStale(address token) external view returns (bool);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(
        MintParams calldata params
    )
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function increaseLiquidity(
        IncreaseLiquidityParams calldata params
    )
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    function collect(
        CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    function positions(
        uint256 tokenId
    )
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function token0() external view returns (address);

    function token1() external view returns (address);
}

/// @notice Strategy assumes `want` is either token0 or token1.
/// Manager/keeper should prepare amounts (swap via ExchangeHandler) before calling deposit here.
contract UniswapV3Strategy is IStrategy {
    using SafeTransferLib for address;

    address public immutable vault;
    address public immutable wantToken; // e.g., USDC
    INonfungiblePositionManager public immutable pm; // Uniswap's position manager
    IUniswapV3Pool public immutable pool; // pool for (token0, token1, fee)
    IExchangeHandler public immutable exchanger;
    IOracleRouter public immutable oracle; // for valuation to `want`

    uint256 public tokenId; // LP NFT id held by this strategy

    modifier onlyVault() {
        require(msg.sender == vault, "NOT_VAULT");
        _;
    }

    constructor(
        address _vault,
        address _want,
        address _pm,
        address _pool,
        address _exchanger,
        address _oracle
    ) {
        require(
            _vault != address(0) &&
                _want != address(0) &&
                _pm != address(0) &&
                _pool != address(0) &&
                _exchanger != address(0) &&
                _oracle != address(0),
            "BAD_ADDR"
        );
        vault = _vault;
        wantToken = _want;
        pm = INonfungiblePositionManager(_pm);
        pool = IUniswapV3Pool(_pool);
        exchanger = IExchangeHandler(_exchanger);
        oracle = IOracleRouter(_oracle);
    }

    function totalAssets() public view override returns (uint256) {
        // Value = current liquidity amounts + uncollected fees + idle want, all converted to `want`
        if (tokenId == 0) {
            return IERC20(wantToken).balanceOf(address(this));
        }

        (
            ,
            ,
            address token0,
            address token1,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            uint128 fees0,
            uint128 fees1
        ) = pm.positions(tokenId);

        if (liquidity == 0 && fees0 == 0 && fees1 == 0) {
            return IERC20(wantToken).balanceOf(address(this));
        }

        // Get current price
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        // Estimate amounts for liquidity.
        // Use Uniswap math libs to convert liquidity → token amounts
        (uint256 amt0, uint256 amt1) = math.getAmountsForLiquidity(
            sqrtPriceX96,
            math.getSqrtRatioAtTick(tickLower),
            math.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
        // For MVP, we conservatively value **only** uncollected fees + idle want to avoid complex math:
        // Add uncollected fees
        amt0 += fees0;
        amt1 += fees1;

        // Convert token0/token1 to `want` using oracle prices.
        uint256 valueInWant = _convertToWant(token0, amt0) +
            _convertToWant(token1, amt1);

        // Add idle want in the contract (e.g., dust from mint/collect)
        valueInWant += IERC20(wantToken).balanceOf(address(this));

        // emit totalAsset(amt0, amt1, fees0, fees1);
        return valueInWant;
    }

    function knowYourAssets() public returns (uint256) {
        // Value = current liquidity amounts + uncollected fees + idle want, all converted to `want`
        if (tokenId == 0) {
            return IERC20(wantToken).balanceOf(address(this));
        }

        (
            ,
            ,
            address token0,
            address token1,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            uint128 fees0,
            uint128 fees1
        ) = pm.positions(tokenId);

        if (liquidity == 0 && fees0 == 0 && fees1 == 0) {
            return IERC20(wantToken).balanceOf(address(this));
        }

        // Get current price
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        // Estimate amounts for liquidity.
        // Use Uniswap math libs to convert liquidity → token amounts
        (uint256 amt0, uint256 amt1) = math.getAmountsForLiquidity(
            sqrtPriceX96,
            math.getSqrtRatioAtTick(tickLower),
            math.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
        // For MVP, we conservatively value **only** uncollected fees + idle want to avoid complex math:
        // Add uncollected fees
        amt0 += fees0;
        amt1 += fees1;

        // Convert token0/token1 to `want` using oracle prices.
        uint256 valueInWant = _convertToWant(token0, amt0) +
            _convertToWant(token1, amt1);

        // Add idle want in the contract (e.g., dust from mint/collect)
        valueInWant += IERC20(wantToken).balanceOf(address(this));

        emit totalAsset(amt0, amt1, fees0, fees1);
        return valueInWant;
    }

     function deposit(
        uint256 amountWant,
        bytes[] calldata swaps
    ) external override onlyVault {
        if (amountWant > 0) {
            IERC20(wantToken).transferFrom(vault, address(this), amountWant);
        } else {
            return;
        }
    }

    // ---------------- Internals ----------------

    function _convertToWant(
        address token,
        uint256 amount
    ) internal view returns (uint256) {
        if (amount == 0) return 0;
        if (token == wantToken) return amount;

        // Convert via USD as numeraire using oracle
        uint256 pToken = oracle.price(token); // 1e18
        uint256 pWant = oracle.price(wantToken); // 1e18
        if (pToken == 0 || pWant == 0) return 0;
        // value_in_want = amount * pToken / pWant (adjust for token decimals if needed)
        return (amount * pToken) / pWant;
    }
}
