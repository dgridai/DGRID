// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library CalcMonthData {
    /// @notice Calculate the monthly delta of a staking or LLM emission.
    /// @param startTime The start timestamp of the monthly emission.
    /// @param endTime The end timestamp of the monthly emission.
    /// @param quota The total quota of the monthly emission.
    /// @param emitted The total amount of the monthly emission that has been emitted.
    /// @param fromTs The start timestamp of the monthly delta.
    /// @param toTs The end timestamp of the monthly delta.
    /// @return delta The monthly delta of the staking or LLM emission.
    /// @dev The monthly delta is calculated as the amount of the monthly emission that has been unlocked
    ///      between the fromTs and toTs.
    function calcMonthlyDelta(
        uint64 startTime,
        uint64 endTime,
        uint256 quota,
        uint256 emitted,
        uint256 fromTs,
        uint256 toTs
    ) internal pure returns (uint256 delta) {
        if (toTs <= startTime || fromTs >= endTime) return 0;

        uint256 segStart = fromTs > startTime ? fromTs : startTime;
        uint256 segEnd = toTs < endTime ? toTs : endTime;
        if (segEnd <= segStart) return 0;

        uint256 duration = uint256(endTime) - uint256(startTime);
        if (duration == 0) return 0; // Guard against division by zero

        uint256 unlockedEnd = (quota * (segEnd - uint256(startTime))) /
            duration;
        uint256 unlockedStart = (quota * (segStart - uint256(startTime))) /
            duration;
        delta = unlockedEnd - unlockedStart;

        uint256 remain = quota > emitted ? quota - emitted : 0;
        if (toTs >= endTime && remain > delta) {
            // Settle integer-division dust in the last settlement of the month.
            delta = remain;
        }
        if (delta > remain) delta = remain;
    }
}
