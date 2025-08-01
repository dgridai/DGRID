// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);

    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract ChainlinkPriceFeed {
    AggregatorV3Interface public priceFeed;
    uint8 public immutable feedDecimals;
    uint32 public immutable heartbeat; // max allow time to update price
    uint256 public constant TARGET_DIGITS = 18;
    uint256 public constant MAX_PRICE_DEVIATION = 5e17; // 50%

    // price cache
    uint256 public lastPrice; // 18 decimals
    uint256 public lastTimestamp; // oracle update time
    uint80 public lastRoundId;
    uint256 public lastBlock; // cache block number

    error PriceFeed__Stale();
    error PriceFeed__Deviation();
    error PriceFeed__Invalid();

    constructor(address _aggregator, uint32 _heartbeat) {
        priceFeed = AggregatorV3Interface(_aggregator);
        feedDecimals = priceFeed.decimals();
        heartbeat = _heartbeat;
    }

    /// @notice get latest price (auto cache, only get once in one block)
    function fetchPrice() public returns (uint256) {
        // if price is cached in this block, return directly
        if (lastBlock == block.number && lastPrice != 0) {
            return lastPrice;
        }

        (uint80 roundId, int256 answer, , uint256 updatedAt, ) = priceFeed
            .latestRoundData();
        require(answer > 0, "Invalid answer");
        require(updatedAt <= block.timestamp, "Future price");
        require(updatedAt != 0, "No timestamp");

        // heartbeat check
        if (block.timestamp - updatedAt > heartbeat) revert PriceFeed__Stale();

        uint256 scaledPrice = _scalePrice(uint256(answer), feedDecimals);
        // price deviation check (optional, enable as needed)
        if (lastPrice != 0 && lastRoundId != 0) {
            uint256 minP = scaledPrice < lastPrice ? scaledPrice : lastPrice;
            uint256 maxP = scaledPrice > lastPrice ? scaledPrice : lastPrice;
            uint256 deviation = ((maxP - minP) * 1e18) / maxP;
            if (deviation > MAX_PRICE_DEVIATION) revert PriceFeed__Deviation();
        }

        // update cache
        lastPrice = scaledPrice;
        lastTimestamp = updatedAt;
        lastRoundId = roundId;
        lastBlock = block.number;

        return scaledPrice;
    }

    /// @notice get last cached price (18 decimals)
    function getLastPrice() public view returns (uint256) {
        return lastPrice;
    }

    /// @notice get oracle original decimals
    function getDecimals() public view returns (uint8) {
        return feedDecimals;
    }

    /// @notice get oracle description
    function getDescription() public view returns (string memory) {
        return priceFeed.description();
    }

    /// @dev scale price to 18 decimals
    function _scalePrice(
        uint256 price,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == TARGET_DIGITS) {
            return price;
        } else if (decimals < TARGET_DIGITS) {
            return price * (10 ** (TARGET_DIGITS - decimals));
        } else {
            return price / (10 ** (decimals - TARGET_DIGITS));
        }
    }
}
