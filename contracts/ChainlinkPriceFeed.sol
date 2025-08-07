// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

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

contract ChainlinkPriceFeed is Ownable {
    // Add price feed mapping
    mapping(address => AggregatorV3Interface) public priceFeeds;
    mapping(address => uint8) public feedDecimals;
    uint32 public immutable heartbeat; // max allow time to update price
    uint256 public constant TARGET_DIGITS = 18;
    uint256 public constant MAX_PRICE_DEVIATION = 5e17; // 50%

    // price cache
    mapping(address => uint256) public lastPrice;
    mapping(address => uint256) public lastTimestamp;
    mapping(address => uint80) public lastRoundId;
    mapping(address => uint256) public lastBlock;

    error PriceFeed__Stale();
    error PriceFeed__Deviation();
    error PriceFeed__Invalid();

    constructor(
        address[] memory _tokens,
        address[] memory _aggregators,
        uint32 _heartbeat
    ) Ownable(msg.sender) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            priceFeeds[_tokens[i]] = AggregatorV3Interface(_aggregators[i]);
            feedDecimals[_tokens[i]] = priceFeeds[_tokens[i]].decimals();
        }
        heartbeat = _heartbeat;
    }

    /// @notice get latest price (auto cache, only get once in one block)
    function fetchPrice(address asset) public returns (uint256) {
        // if price is cached in this block, return directly
        if (lastBlock[asset] == block.number && lastPrice[asset] != 0) {
            return lastPrice[asset];
        }

        (uint80 roundId, int256 answer, , uint256 updatedAt, ) = priceFeeds[
            asset
        ].latestRoundData();
        require(answer > 0, "Invalid answer");
        require(updatedAt <= block.timestamp, "Future price");
        require(updatedAt != 0, "No timestamp");

        // heartbeat check
        if (block.timestamp - updatedAt > heartbeat) revert PriceFeed__Stale();

        uint256 scaledPrice = _scalePrice(uint256(answer), feedDecimals[asset]);
        // price deviation check (optional, enable as needed)
        if (lastPrice[asset] != 0 && lastRoundId[asset] != 0) {
            uint256 minP = scaledPrice < lastPrice[asset]
                ? scaledPrice
                : lastPrice[asset];
            uint256 maxP = scaledPrice > lastPrice[asset]
                ? scaledPrice
                : lastPrice[asset];
            uint256 deviation = ((maxP - minP) * 1e18) / maxP;
            if (deviation > MAX_PRICE_DEVIATION) revert PriceFeed__Deviation();
        }

        // update cache
        lastPrice[asset] = scaledPrice;
        lastTimestamp[asset] = updatedAt;
        lastRoundId[asset] = roundId;
        lastBlock[asset] = block.number;

        return scaledPrice;
    }

    /// @notice get last cached price (18 decimals)
    function getLastPrice(address asset) public view returns (uint256) {
        return lastPrice[asset];
    }

    /// @notice get oracle original decimals
    function getDecimals(address asset) public view returns (uint8) {
        return feedDecimals[asset];
    }

    /// @notice get oracle description
    function getDescription(address asset) public view returns (string memory) {
        return priceFeeds[asset].description();
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

    function setPriceFeed(address asset, address priceFeed) external onlyOwner {
        priceFeeds[asset] = AggregatorV3Interface(priceFeed);
        feedDecimals[asset] = priceFeeds[asset].decimals();
    }
}
