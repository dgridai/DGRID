// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPancakeV3Pool} from "./Interfaces/IPancakeV3Pool.sol";
import {TickMath} from "./libraries/TickMath8.sol";
import {FullMath} from "./libraries/FullMath8.sol";

contract DgridPriceFeed is Initializable, OwnableUpgradeable {
    uint32 public TWAP_PERIOD;
    uint256 public constant Q96 = 2 ** 96;
    address public tDGAI;
    IPancakeV3Pool public pool;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _tDGAI,
        address _pool
    ) public initializer {
        __Ownable_init(_owner);
        require(_tDGAI != address(0), "tDGAI is zero address");
        require(_pool != address(0), "pool is zero address");
        tDGAI = _tDGAI;
        pool = IPancakeV3Pool(_pool);
        address t0 = pool.token0();
        address t1 = pool.token1();
        require(t0 == tDGAI || t1 == tDGAI, "pool !tDGAI");
        TWAP_PERIOD = 1800; // 30 minutes
    }

    function getBNBPrice18() public view returns (uint256) {}

    function getTDGAITwapPrice18() public view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_PERIOD;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 secs = int56(uint56(TWAP_PERIOD));
        int24 twapTick = int24(delta / secs);
        if (delta < 0 && (delta % secs != 0)) {
            twapTick--; // round towards -infinity
        }

        address token0 = pool.token0();
        address token1 = pool.token1();
        require(token0 == tDGAI || token1 == tDGAI, "pool !tDGAI");

        uint8 decimals0 = ERC20(token0).decimals();
        uint8 decimals1 = ERC20(token1).decimals();
        require(decimals0 <= 18 && decimals1 <= 18, "dec>18");
        // price: token1 per token0 (18 decimals)
        uint256 price = getPriceFromTick(twapTick, decimals0, decimals1);

        if (token1 == tDGAI) {
            // want stable per tDGAI → invert, keep 18 decimals
            price = (1e36) / price;
        }
        return price; // 18 decimals
    }

    function getPriceFromTick(
        int24 tick,
        uint8 decimals0,
        uint8 decimals1
    ) internal pure returns (uint256) {
        uint256 sqrtP = uint256(TickMath.getSqrtRatioAtTick(tick)); // Q96
        // price1_per_0_18 = (sqrtP^2 / Q192) * 10^dec0 / 10^dec1 * 1e18
        uint256 base = FullMath.mulDiv(1e18 * (10 ** decimals0), sqrtP, Q96);
        return FullMath.mulDiv(base, sqrtP, Q96 * (10 ** decimals1));
    }

    function setTDGAIPool(address _pool) external onlyOwner {
        require(_pool != address(0), "pool=0");
        pool = IPancakeV3Pool(_pool);
        address t0 = pool.token0();
        address t1 = pool.token1();
        require(t0 == tDGAI || t1 == tDGAI, "pool !tDGAI");
    }

    function setTDGAI(address _tDGAI) external onlyOwner {
        require(_tDGAI != address(0), "tDGAI is zero address");
        tDGAI = _tDGAI;
        address t0 = pool.token0();
        address t1 = pool.token1();
        require(t0 == tDGAI || t1 == tDGAI, "pool !tDGAI");
    }

    function setTWAPPeriod(uint32 _TWAP_PERIOD) external onlyOwner {
        require(_TWAP_PERIOD > 0, "TWAP_PERIOD=0");
        TWAP_PERIOD = _TWAP_PERIOD;
    }
}
