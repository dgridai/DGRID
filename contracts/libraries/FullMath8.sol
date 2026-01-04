// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library FullMath {
    // calculate floor(a * b / denominator), no overflow in intermediate multiplication
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0; // low 256 bits
            uint256 prod1; // high 256 bits
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                require(denominator > 0, "div0");
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            // ensure result < 2^256, and denominator > prod1
            require(denominator > prod1, "overflow");

            // subtract remainder, ensure can be exactly divided
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // extract 2^n factor of denominator
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            // merge high bits to low bits
            prod0 |= prod1 * twos;

            // calculate modulo inverse of denominator in 2^256
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // 2
            inv *= 2 - denominator * inv; // 4
            inv *= 2 - denominator * inv; // 8
            inv *= 2 - denominator * inv; // 16
            inv *= 2 - denominator * inv; // 32
            inv *= 2 - denominator * inv; // 64

            // final result (equivalent to prod0 / denominator)
            result = prod0 * inv;
            return result;
        }
    }

    // rounding up version: ceil(a * b / denominator)
    function mulDivRoundingUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        unchecked {
            if (mulmod(a, b, denominator) > 0) {
                require(result < type(uint256).max, "round");
                result++;
            }
        }
    }
}
