// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../utils/SafeTransferLib.sol";

interface IERC20 {
    function totalSupply() external view returns (uint256);

    function balanceOf(address) external view returns (uint256);

    function transfer(address, uint256) external returns (bool);

    function allowance(address, address) external view returns (uint256);

    function approve(address, uint256) external returns (bool);

    function transferFrom(address, uint256) external returns (bool);

    function decimals() external view returns (uint8);
}



contract Vault {
    using SafeTransferLib for address;

    // --- Config ---
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    address public immutable asset; // ERC20 underlying (e.g., USDC)
    AccessController public access; // role control
    FeeModule public fees; // fee module
    IOracleRouter public oracle; // price sanity if needed

    // --- ERC4626-ish shares ---
    uint256 public totalSupply; // total shares
    mapping(address => uint256) public balanceOf;

    // --- Strategies ---
    IStrategy[] public strategies;
    mapping(IStrategy => uint16) public targetBps; // target allocation per strategy (sum <= 1e4)

    // --- Limits & Timers ---
    uint256 public depositCap; // max TVL
    uint256 public minHarvestInterval; // seconds
    uint256 public lastHarvest;

    event Deposit(
        address indexed from,
        address indexed to,
        uint256 assets,
        uint256 shares
    );
    event Withdraw(
        address indexed caller,
        address indexed to,
        uint256 assets,
        uint256 shares
    );
    event Harvest(
        uint256 realizedProfit,
        uint256 mgmtFee,
        uint256 perfFee,
        uint256 tvlAfter
    );

    event StrategySet(address strategy, uint16 bps);

    modifier onlyManager() {
        require(access.managers(msg.sender), "NOT_MANAGER");
        _;
    }
    modifier onlyKeeper() {
        require(access.keepers(msg.sender), "NOT_KEEPER");
        _;
    }

    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _access,
        address _fees,
        address _oracle,
        uint256 _depositCap,
        uint8 _decimals
    ) {
        asset = _asset;
        name = _name;
        symbol = _symbol;
        access = AccessController(_access);
        fees = FeeModule(_fees);
        oracle = IOracleRouter(_oracle);
        depositCap = _depositCap;
        decimals = _decimals;
    }


     // -----------------
    // User actions
    // -----------------
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares) {
        require(totalAssets() + assets <= depositCap, "CAP");
        asset.safeTransferFrom(msg.sender, address(this), assets);
        (uint256 net, uint256 entryFee) = fees.takeEntryFee(assets);
        if (entryFee > 0) IERC20(asset).transfer(fees.treasury(), entryFee);
        shares = convertToShares(net);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }
    


    // -----------------
    // View helpers
    // -----------------

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 ts = totalSupply;
        uint256 ta = totalAssets();
        return ts == 0 || ta == 0 ? assets : (assets * ts) / ta;
    }


    // -----------------
    // Internals
    // -----------------
    function _assetBal() internal view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }



}