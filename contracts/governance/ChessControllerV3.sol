// SPDX-License-Identifier: MIT
pragma solidity >=0.6.10 <0.8.0;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../utils/CoreUtility.sol";
import "../utils/SafeDecimalMath.sol";
import "../interfaces/IChessController.sol";
import "../interfaces/IFund.sol";

contract ChessControllerV3 is IChessController, CoreUtility {
    /// @dev Reserved storage slots for future base contract upgrades
    uint256[192] private _reservedSlots;

    using Math for uint256;
    using SafeMath for uint256;
    using SafeDecimalMath for uint256;

    uint256 public constant WINDOW_SIZE = 2;
    uint256 public immutable minWeight;

    address public immutable fund0;
    address public immutable fund1;
    mapping(uint256 => mapping(address => uint256)) public weights;

    uint256 public immutable guardedLaunchStart;

    address public immutable fund2;
    uint256 public immutable guardedLaunchStart2;

    constructor(
        address fund0_,
        address fund1_,
        address fund2_,
        uint256 guardedLaunchStart_,
        uint256 guardedLaunchStart2_,
        uint256 minWeight_
    ) public {
        require(minWeight_ > 0 && minWeight_ < 1e18);
        fund0 = fund0_;
        fund1 = fund1_;
        fund2 = fund2_;
        guardedLaunchStart = guardedLaunchStart_;
        guardedLaunchStart2 = guardedLaunchStart2_;
        minWeight = minWeight_;
    }

    function initialize(uint256[] calldata guardedWeights0_) external {
        require(weights[guardedLaunchStart][fund0] == 0);
        require(guardedWeights0_.length > 0);
        require(_endOfWeek(guardedLaunchStart) == guardedLaunchStart + 1 weeks, "Not end of week");
        for (uint256 i = 0; i < guardedWeights0_.length; i++) {
            uint256 guardedWeight0 = guardedWeights0_[i];
            require(
                guardedWeight0 >= minWeight && guardedWeight0 <= 1e18 - minWeight,
                "Invalid weight"
            );
            weights[guardedLaunchStart + i * 1 weeks][fund0] = guardedWeight0;
            weights[guardedLaunchStart + i * 1 weeks][fund1] = 1e18 - guardedWeight0;
        }
    }

    function initializeV2(uint256[] calldata guardedWeights0_) external {
        require(weights[guardedLaunchStart2][fund2] == 0);
        require(guardedWeights0_.length > 0);
        require(
            _endOfWeek(guardedLaunchStart2) == guardedLaunchStart2 + 1 weeks,
            "Not end of week"
        );
        for (uint256 i = 0; i < guardedWeights0_.length; i++) {
            uint256 guardedWeight0 = guardedWeights0_[i];
            require(
                guardedWeight0 >= minWeight && guardedWeight0 <= 1e18 - minWeight,
                "Invalid weight"
            );
            weights[guardedLaunchStart2 + i * 1 weeks][fund2] = guardedWeight0;
        }
    }

    /// @notice Get Fund relative weight (not more than 1.0) normalized to 1e18
    ///         (e.g. 1.0 == 1e18).
    /// @return weight Value of relative weight normalized to 1e18
    function getFundRelativeWeight(address fundAddress, uint256 timestamp)
        external
        override
        returns (uint256)
    {
        require(timestamp <= block.timestamp, "Too soon");
        if (fundAddress != fund0 && fundAddress != fund1 && fundAddress != fund2) {
            return 0;
        }
        if (timestamp < guardedLaunchStart2 && fundAddress == fund2) {
            return 0;
        }

        uint256 weekTimestamp = _endOfWeek(timestamp).sub(1 weeks);
        uint256 weight = weights[weekTimestamp][fundAddress];
        if (weight != 0) {
            return weight;
        }

        (uint256 weight0, uint256 weight1, uint256 weight2) = _updateFundWeight(weekTimestamp);
        if (fundAddress == fund0) return weight0;
        else if (fundAddress == fund1) return weight1;
        else return weight2;
    }

    function _updateFundWeight(uint256 weekTimestamp)
        private
        returns (
            uint256 weightMovingAverage0,
            uint256 weightMovingAverage1,
            uint256 weightMovingAverage2
        )
    {
        uint256 currFundWeight2 = weights[weekTimestamp][fund2];
        uint256 fundValueLocked0 = getFundValueLocked(fund0, weekTimestamp);
        uint256 fundValueLocked1 = getFundValueLocked(fund1, weekTimestamp);
        uint256 totalValueLocked =
            fundValueLocked0.add(fundValueLocked1).add(getFundValueLocked(fund2, weekTimestamp));

        if (totalValueLocked == 0) {
            uint256 prevFundWeight0 = weights[weekTimestamp - 1 weeks][fund0];
            uint256 prevFundWeight1 = weights[weekTimestamp - 1 weeks][fund1];
            require(prevFundWeight0 != 0 && prevFundWeight1 != 0, "Previous week is empty");

            weightMovingAverage0 = prevFundWeight0;
            weightMovingAverage1 = prevFundWeight1;
            weightMovingAverage2 = weights[weekTimestamp - 1 weeks][fund2];
        } else if (currFundWeight2 != 0) {
            // guarded launch
            uint256 prevFundWeight0 = weights[weekTimestamp - 1 weeks][fund0];
            totalValueLocked = fundValueLocked0.add(fundValueLocked1);
            require(prevFundWeight0 != 0, "Previous week is empty");

            weightMovingAverage0 = (prevFundWeight0.mul(WINDOW_SIZE - 1).add(
                fundValueLocked0.divideDecimal(totalValueLocked)
            ) / WINDOW_SIZE)
                .max(minWeight)
                .min(1e18 - minWeight)
                .mul(1e18 - currFundWeight2)
                .div(1e18);
            weightMovingAverage1 = uint256(1e18).sub(currFundWeight2).sub(weightMovingAverage0);
        } else {
            uint256 prevFundWeight0 = weights[weekTimestamp - 1 weeks][fund0];
            uint256 prevFundWeight1 = weights[weekTimestamp - 1 weeks][fund1];
            require(prevFundWeight0 != 0 && prevFundWeight1 != 0, "Previous week is empty");

            weightMovingAverage0 = (prevFundWeight0.mul(WINDOW_SIZE - 1).add(
                fundValueLocked0.divideDecimal(totalValueLocked)
            ) / WINDOW_SIZE)
                .max(minWeight)
                .min(1e18 - minWeight);
            weightMovingAverage1 = (prevFundWeight1.mul(WINDOW_SIZE - 1).add(
                fundValueLocked1.divideDecimal(totalValueLocked)
            ) / WINDOW_SIZE)
                .max(minWeight)
                .min(1e18 - minWeight);
            weightMovingAverage2 = uint256(1e18).sub(weightMovingAverage0).sub(
                weightMovingAverage1
            );
        }

        weights[weekTimestamp][fund0] = weightMovingAverage0;
        weights[weekTimestamp][fund1] = weightMovingAverage1;
        weights[weekTimestamp][fund2] = weightMovingAverage2;
    }

    function getFundValueLocked(address fund, uint256 weekTimestamp)
        public
        view
        returns (uint256 fundValueLocked)
    {
        uint256 timestamp = (IFund(fund).currentDay() - 1 days).min(weekTimestamp);
        (uint256 navM, , ) = IFund(fund).historicalNavs(timestamp);
        fundValueLocked = IFund(fund).historicalTotalShares(timestamp).multiplyDecimal(navM);
    }
}
