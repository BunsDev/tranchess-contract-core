// SPDX-License-Identifier: MIT
pragma solidity >=0.6.10 <0.8.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../interfaces/ILiquidityGauge.sol";
import "../interfaces/IChessSchedule.sol";
import "../interfaces/IChessController.sol";
import "../interfaces/IFundV3.sol";
import "../interfaces/ITrancheIndexV2.sol";
import "../interfaces/IStableSwap.sol";
import "../interfaces/IVotingEscrow.sol";

import "../utils/CoreUtility.sol";
import "../utils/SafeDecimalMath.sol";

interface ISwapRewards {
    function rewardToken() external view returns (address);

    function getReward() external;
}

struct Distribution {
    uint256 totalQ;
    uint256 totalB;
    uint256 totalR;
    uint256 totalU;
    uint256 totalSupply;
}

contract LiquidityGauge is ILiquidityGauge, ITrancheIndexV2, CoreUtility, Ownable, ERC20 {
    using Math for uint256;
    using SafeMath for uint256;
    using SafeDecimalMath for uint256;
    using SafeERC20 for IERC20;

    event Transfer(address indexed from, address indexed to, uint256 value);

    uint256 private constant MAX_ITERATIONS = 500;
    uint256 private constant QUOTE_ASSET = 3;
    uint256 private constant MAX_BOOSTING_FACTOR = 3e18;
    uint256 private constant MAX_BOOSTING_FACTOR_MINUS_ONE = MAX_BOOSTING_FACTOR - 1e18;

    IChessSchedule public immutable chessSchedule;
    IChessController public immutable chessController;
    IFundV3 public immutable fund;
    IVotingEscrow private immutable _votingEscrow;
    uint256 public immutable initialRebalanceVersion;
    address public immutable swapReward;

    uint256 private _workingSupply;
    mapping(address => uint256) private _workingBalances;

    uint256 private _checkpointTimestamp;

    uint256 public currentRebalanceSize;
    mapping(address => uint256[TRANCHE_COUNT + 1]) public claimableAssets;
    mapping(address => uint256) public distributionVersions;
    mapping(uint256 => Distribution) public distributions;

    uint256 private _chessIntegral;
    mapping(address => uint256) private _chessUserIntegrals;
    mapping(address => uint256) private _claimableChess;

    uint256 private _rewardIntegral;
    mapping(address => uint256) private _rewardUserIntegral;
    mapping(address => uint256) private _claimableRewards;

    constructor(
        string memory name_,
        string memory symbol_,
        address chessSchedule_,
        address chessController_,
        address fund_,
        address votingEscrow_,
        address swapReward_
    ) public ERC20(name_, symbol_) {
        chessSchedule = IChessSchedule(chessSchedule_);
        chessController = IChessController(chessController_);
        fund = IFundV3(fund_);
        _votingEscrow = IVotingEscrow(votingEscrow_);
        swapReward = swapReward_;
        _checkpointTimestamp = block.timestamp;
        initialRebalanceVersion = IFundV3(fund_).getRebalanceSize();
    }

    // ------------------------------ ERC20 ------------------------------------

    function mint(address account, uint256 amount) external override onlyOwner {
        uint256 currentWorkingSupply = _workingSupply;
        uint256 workingBalance = _workingBalances[account];
        _checkpoint(currentWorkingSupply);
        _tokenCheckpoint(account, workingBalance);
        uint256 balance = balanceOf(account);
        _assetCheckpoint(account, balance);
        _rewardCheckpoint(account, balance);

        _mint(account, amount);

        _updateWorkingBalance(
            account,
            workingBalance,
            currentWorkingSupply,
            balanceOf(account),
            totalSupply()
        );
        emit Transfer(address(0), account, amount);
    }

    function burnFrom(address account, uint256 amount) external override onlyOwner {
        uint256 currentWorkingSupply = _workingSupply;
        uint256 workingBalance = _workingBalances[account];
        _checkpoint(currentWorkingSupply);
        _tokenCheckpoint(account, workingBalance);
        uint256 balance = balanceOf(account);
        _assetCheckpoint(account, balance);
        _rewardCheckpoint(account, balance);

        _burn(account, amount);

        _updateWorkingBalance(
            account,
            workingBalance,
            currentWorkingSupply,
            balanceOf(account),
            totalSupply()
        );
        emit Transfer(account, address(0), amount);
    }

    function _transfer(
        address,
        address,
        uint256
    ) internal override {
        revert("Transfer is not allow");
    }

    // ---------------------------- LP Token -----------------------------------

    function workingBalanceOf(address account) external view override returns (uint256) {
        return _workingBalances[account];
    }

    function workingSupply() external view override returns (uint256) {
        return _workingSupply;
    }

    function claimableTokenAndAssetAndReward(address account)
        external
        override
        returns (
            uint256 amountToken,
            uint256 amountReward,
            uint256 amountQ,
            uint256 amountB,
            uint256 amountR,
            uint256 amountU
        )
    {
        _checkpoint(_workingSupply);
        amountToken = _tokenCheckpoint(account, _workingBalances[account]);
        uint256 balance = balanceOf(account);
        (amountQ, amountB, amountR, amountU) = _assetCheckpoint(account, balance);
        amountReward = _rewardCheckpoint(account, balance);
    }

    function claimTokenAndAssetAndReward(address account) external override {
        uint256 currentWorkingSupply = _workingSupply;
        _checkpoint(currentWorkingSupply);
        uint256 workingBalance = _workingBalances[account];
        uint256 amountToken = _tokenCheckpoint(account, workingBalance);
        uint256 balance = balanceOf(account);
        (uint256 amountQ, uint256 amountB, uint256 amountR, uint256 amountU) =
            _assetCheckpoint(account, balance);
        uint256 amountReward = _rewardCheckpoint(account, balance);
        _updateWorkingBalance(
            account,
            workingBalance,
            currentWorkingSupply,
            balance,
            totalSupply()
        );

        chessSchedule.mint(account, amountToken);
        delete _claimableChess[account];

        address rewardToken = ISwapRewards(swapReward).rewardToken();
        IERC20(rewardToken).safeTransfer(account, amountReward);
        delete _claimableRewards[account];

        IERC20(fund.tokenQ()).safeTransfer(account, amountQ);
        IERC20(fund.tokenB()).safeTransfer(account, amountB);
        IERC20(fund.tokenR()).safeTransfer(account, amountR);
        IERC20(IStableSwap(owner()).quoteAddress()).safeTransfer(account, amountU);
        delete claimableAssets[account];
    }

    function userCheckpoint(address account) public override {
        uint256 currentWorkingSupply = _workingSupply;
        _checkpoint(currentWorkingSupply);
        uint256 workingBalance = _workingBalances[account];
        _tokenCheckpoint(account, workingBalance);
        uint256 balance = balanceOf(account);
        _assetCheckpoint(account, balance);
        _rewardCheckpoint(account, balance);
        _updateWorkingBalance(
            account,
            workingBalance,
            currentWorkingSupply,
            balance,
            totalSupply()
        );
    }

    function syncWithVotingEscrow(address account) external {
        uint256 currentWorkingSupply = _workingSupply;
        _checkpoint(currentWorkingSupply);
        uint256 workingBalance = _workingBalances[account];
        _tokenCheckpoint(account, workingBalance);
        uint256 balance = balanceOf(account);
        _assetCheckpoint(account, balance);
        _rewardCheckpoint(account, balance);

        _updateWorkingBalance(
            account,
            _workingBalances[account],
            _workingSupply,
            balance,
            totalSupply()
        );
    }

    function _checkpoint(uint256 currentWorkingSupply) private {
        uint256 timestamp_ = _checkpointTimestamp;

        // calculate overall integral till now
        if (currentWorkingSupply != 0) {
            uint256 overallIntegral_ = _chessIntegral;
            for (uint256 i = 0; i < MAX_ITERATIONS && timestamp_ < block.timestamp; i++) {
                uint256 endWeek = _endOfWeek(timestamp_);
                uint256 rate = chessSchedule.getRate(endWeek.sub(1 weeks));
                uint256 relativeWeight =
                    chessController.getFundRelativeWeight(address(this), endWeek.sub(1 weeks));
                uint256 endTimestamp = endWeek.min(block.timestamp);
                if (relativeWeight > 0) {
                    overallIntegral_ = overallIntegral_.add(
                        rate
                            .mul(relativeWeight)
                            .mul(endTimestamp.sub(timestamp_))
                            .decimalToPreciseDecimal()
                            .div(currentWorkingSupply)
                    );
                }
                timestamp_ = endTimestamp;
            }
            _chessIntegral = overallIntegral_;
        }

        // update global state
        _checkpointTimestamp = block.timestamp;
    }

    function _tokenCheckpoint(address account, uint256 workingBalance)
        private
        returns (uint256 amountToken)
    {
        // claim governance token till now
        uint256 claimableToken =
            workingBalance.multiplyDecimalPrecise(_chessIntegral.sub(_chessUserIntegrals[account]));
        amountToken = _claimableChess[account].add(claimableToken);
        // update per-user state
        _claimableChess[account] = amountToken;
        _chessUserIntegrals[account] = _chessIntegral;
    }

    function _updateWorkingBalance(
        address account,
        uint256 oldWorkingBalance,
        uint256 oldWorkingSupply,
        uint256 newBalance,
        uint256 newTotalSupply
    ) private {
        uint256 newWorkingBalance = newBalance;
        uint256 veBalance = _votingEscrow.balanceOf(account);
        if (veBalance > 0) {
            uint256 veTotalSupply = _votingEscrow.totalSupply();
            uint256 maxWorkingBalance = newWorkingBalance.multiplyDecimal(MAX_BOOSTING_FACTOR);
            uint256 boostedWorkingBalance =
                newWorkingBalance.add(
                    newTotalSupply
                        .mul(veBalance)
                        .multiplyDecimal(MAX_BOOSTING_FACTOR_MINUS_ONE)
                        .div(veTotalSupply)
                );
            newWorkingBalance = maxWorkingBalance.min(boostedWorkingBalance);
        }
        _workingSupply = oldWorkingSupply.sub(oldWorkingBalance).add(newWorkingBalance);
        _workingBalances[account] = newWorkingBalance;
    }

    // ----------------------------- Rewards -----------------------------------

    function _rewardCheckpoint(address account, uint256 balance)
        private
        returns (uint256 amountReward)
    {
        // Update reward integrals (no gauge weights involved: easy)
        address rewardToken = ISwapRewards(swapReward).rewardToken();

        uint256 rewardDelta = IERC20(rewardToken).balanceOf(address(this));
        ISwapRewards(swapReward).getReward();
        rewardDelta = IERC20(rewardToken).balanceOf(address(this)) - rewardDelta;

        uint256 totalSupply_ = totalSupply();
        uint256 delta = totalSupply_ > 0 ? rewardDelta.divideDecimal(totalSupply_) : 0;
        uint256 newRewardIntegral = _rewardIntegral + delta;
        _rewardIntegral = newRewardIntegral;
        amountReward = _claimableRewards[account].add(
            balance.multiplyDecimal(newRewardIntegral - _rewardUserIntegral[account])
        );
        _claimableRewards[account] = amountReward;
        _rewardUserIntegral[account] = newRewardIntegral;
    }

    // ----------------------- Asset Distribution ------------------------------

    function snapshot(
        uint256 amountQ,
        uint256 amountB,
        uint256 amountR,
        uint256 amountU,
        uint256 rebalanceVersion
    ) external override onlyOwner {
        uint256 index = rebalanceVersion.sub(1);
        distributions[index].totalQ = amountQ;
        distributions[index].totalB = amountB;
        distributions[index].totalR = amountR;
        distributions[index].totalU = amountU;
        distributions[index].totalSupply = totalSupply();
        currentRebalanceSize = rebalanceVersion;
    }

    function _assetCheckpoint(address account, uint256 balance)
        private
        returns (
            uint256 amountQ,
            uint256 amountB,
            uint256 amountR,
            uint256 amountU
        )
    {
        uint256 version = distributionVersions[account];
        uint256 rebalanceVersion = currentRebalanceSize;
        if (rebalanceVersion == 0 || version == rebalanceVersion) {
            return (0, 0, 0, 0);
        }

        amountQ = claimableAssets[account][TRANCHE_Q];
        amountB = claimableAssets[account][TRANCHE_B];
        amountR = claimableAssets[account][TRANCHE_R];
        amountU = claimableAssets[account][QUOTE_ASSET];
        Distribution memory dist = distributions[version];
        if (dist.totalSupply > 0) {
            amountQ = amountQ.add(dist.totalQ.mul(balance).div(dist.totalSupply));
            amountB = amountB.add(dist.totalB.mul(balance).div(dist.totalSupply));
            amountR = amountR.add(dist.totalR.mul(balance).div(dist.totalSupply));
            amountU = amountU.add(dist.totalU.mul(balance).div(dist.totalSupply));
        }
        version++;
        for (; version < rebalanceVersion; version++) {
            (amountQ, amountB, amountR) = fund.doRebalance(amountQ, amountB, amountR, version);
            dist = distributions[version];
            if (dist.totalSupply > 0) {
                amountQ = amountQ.add(dist.totalQ.mul(balance).div(dist.totalSupply));
                amountB = amountB.add(dist.totalB.mul(balance).div(dist.totalSupply));
                amountR = amountR.add(dist.totalR.mul(balance).div(dist.totalSupply));
                amountU = amountU.add(dist.totalU.mul(balance).div(dist.totalSupply));
            }
        }

        claimableAssets[account][TRANCHE_Q] = amountQ;
        claimableAssets[account][TRANCHE_B] = amountB;
        claimableAssets[account][TRANCHE_R] = amountR;
        claimableAssets[account][QUOTE_ASSET] = amountU;
        distributionVersions[account] = rebalanceVersion;
    }
}
