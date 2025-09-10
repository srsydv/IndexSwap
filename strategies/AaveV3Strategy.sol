// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../utils/SafeTransferLib.sol";
import "../interfaces/IStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Minimal Aave v3 types to read aToken from getReserveData
library DataTypes {
    struct ReserveConfigurationMap {
        uint256 data;
    }

    struct ReserveData {
        ReserveConfigurationMap configuration; // uint256
        uint128 liquidityIndex; // u128
        uint128 currentLiquidityRate; // u128
        uint128 variableBorrowIndex; // u128
        uint128 currentVariableBorrowRate; // u128
        uint128 currentStableBorrowRate; // u128
        uint40 lastUpdateTimestamp; // u40
        uint16 id; // u16  <-- position matters
        address aTokenAddress; // address
        address stableDebtTokenAddress; // address
        address variableDebtTokenAddress; // address
        address interestRateStrategyAddress; // address
        uint128 accruedToTreasury; // u128  <-- present on v3
        uint128 unbacked; // u128
        uint128 isolationModeTotalDebt; // u128
    }
}

interface IAavePool {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);

    function getReserveData(
        address asset
    ) external view returns (DataTypes.ReserveData memory);


contract AaveV3Strategy is IStrategy {
    using SafeTransferLib for address;

    address public immutable vault;
    address public immutable wantToken;
    IERC20 public immutable aToken;
    IAavePool public immutable aave;

    modifier onlyVault() {
        require(msg.sender == vault, "NOT_VAULT");
        _;
    }

    constructor(address _vault, address _want, address _aavePool) {
        require(
            _vault != address(0) &&
                _want != address(0) &&
                _aavePool != address(0),
            "BAD_ADDR"
        );
        vault = _vault;
        wantToken = _want;
        aave = IAavePool(_aavePool);
        // derive aToken from pool to avoid mismatches
        DataTypes.ReserveData memory rd = aave.getReserveData(_want);
        aToken = IERC20(rd.aTokenAddress);
    }

    // --- Views ---
    function want() external view override returns (address) {
        return wantToken;
    }

     function totalAssets() public view override returns (uint256) {
        // return IERC20(aToken).balanceOf(address(this));
        uint256 raw = IERC20(address(aToken)).balanceOf(address(this));

        uint8 aDec = IERC20Metadata(address(aToken)).decimals();
        uint8 wantDec = IERC20Metadata(wantToken).decimals();

        // return _scaleDecimals(raw, aDec, wantDec);
    }

}
}
