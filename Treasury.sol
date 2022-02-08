// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./math/Math.sol";
import "./interfaces/IERC20.sol";
import "./ERC20/SafeERC20.sol";
import "./utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";

contract Treasury is ContractGuard, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    // uint256 public constant PERIOD = 6 hours;
    uint256 public constant PERIOD = 10 minutes;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // exclusions from total supply
    address[] public excludedFromTotalSupply = [
        address(0x70f06eE97717C28d29F10DCB562C34EDe28c2b05) // PartialRewardPool
    ];

    // core components
    address public partial_;
    address public pbond_;
    address public pshare_;

    address public boardroom;
    address public partialOracle;

    // price
    uint256 public partialPriceOne;
    uint256 public partialPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of PARTIAL price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochPartialPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra PARTIAL during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 partialAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 partialAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition {
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch {
        require(now >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getPartialPrice() > partialPriceCeiling) ? 0 : getPartialCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator {
        require(
            IBasisAsset(partial_).operator() == address(this) &&
                IBasisAsset(pbond_).operator() == address(this) &&
                IBasisAsset(pshare_).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getPartialPrice() public view returns (uint256 partialPrice) {
        try IOracle(partialOracle).consult(partial_, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult PARTIAL price from the oracle");
        }
    }

    function getPartialUpdatedPrice() public view returns (uint256 _partialPrice) {
        try IOracle(partialOracle).twap(partial_, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult PARTIAL price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnablePartialLeft() public view returns (uint256 _burnablePartialLeft) {
        uint256 _partialPrice = getPartialPrice();
        if (_partialPrice <= partialPriceOne) {
            uint256 _partialSupply = getPartialCirculatingSupply();
            uint256 _bondMaxSupply = _partialSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(pbond_).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnablePartial = _maxMintableBond.mul(_partialPrice).div(1e18);
                _burnablePartialLeft = Math.min(epochSupplyContractionLeft, _maxBurnablePartial);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _partialPrice = getPartialPrice();
        if (_partialPrice > partialPriceCeiling) {
            uint256 _totalPartial = IERC20(partial_).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalPartial.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _partialPrice = getPartialPrice();
        if (_partialPrice <= partialPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = partialPriceOne.mul(2);
            } else {
                uint256 _bondAmount = partialPriceOne.mul(1e18).div(_partialPrice); // to burn 1 PARTIAL
                uint256 _discountAmount = _bondAmount.sub(partialPriceOne).mul(discountPercent).div(10000);
                _rate = partialPriceOne.add(_discountAmount).mul(2);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _partialPrice = getPartialPrice();
        if (_partialPrice > partialPriceCeiling) {
            uint256 _partialPricePremiumThreshold = partialPriceOne.mul(premiumThreshold).div(100);
            if (_partialPrice >= _partialPricePremiumThreshold) {
                //Price > 0.55
                uint256 _premiumAmount = _partialPrice.sub(partialPriceOne).mul(premiumPercent).div(10000);
                _rate = partialPriceOne.add(_premiumAmount).mul(2);
                if (maxPremiumRate > partialPriceOne && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = partialPriceOne.mul(2);
            }
        }
    }

    /* ========== GOVEPARTIALNCE ========== */

    function initialize(
        address _partial,
        address _pbond,
        address _pshare,
        address _partialOracle,
        address _boardroom,
        uint256 _startTime
    ) public notInitialized {
        partial_ = _partial;
        pbond_ = _pbond;
        pshare_ = _pshare;
        partialOracle = _partialOracle;
        boardroom = _boardroom;
        startTime = _startTime;

        partialPriceOne = (10**18) / 2;
        partialPriceCeiling = partialPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 500000 ether, 1000000 ether, 1500000 ether, 2000000 ether, 5000000 ether, 10000000 ether, 20000000 ether, 50000000 ether];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for boardroom
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn PARTIAL and mint pBOND)
        maxDebtRatioPercent = 3500; // Upto 35% supply of pBOND to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 28 epochs with 4.5% expansion
        // bootstrapEpochs = 28;
        bootstrapEpochs = 0;
        bootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(partial_).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setBoardoom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setPartialOracle(address _partialOracle) external onlyOperator {
        partialOracle = _partialOracle;
    }

    function setPartialPriceCeiling(uint256 _partialPriceCeiling) external onlyOperator {
        require(_partialPriceCeiling >= partialPriceOne && _partialPriceCeiling <= partialPriceOne.mul(120).div(100), "out of range"); // [$0.5, $0.6]
        partialPriceOne = _partialPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1], "Value has to be higher than previous tier's value");
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1], "Value has to be lower than next tier's value");
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 4000, "out of range"); // <= 40%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 1000, "out of range"); // <= 10%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= partialPriceCeiling, "_premiumThreshold exceeds partialPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updatePartialPrice() internal {
        try IOracle(partialOracle).update() {} catch {}
    }

    function getPartialCirculatingSupply() public view returns (uint256) {
        IERC20 partialErc20 = IERC20(partial_);
        uint256 totalSupply = partialErc20.totalSupply();
        uint256 balanceExcluded = 0;
        for (uint8 entryId = 0; entryId < excludedFromTotalSupply.length; ++entryId) {
            balanceExcluded = balanceExcluded.add(partialErc20.balanceOf(excludedFromTotalSupply[entryId]));
        }
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _partialAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator nonReentrant {
        require(_partialAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 partialPrice = getPartialPrice();
        require(partialPrice == targetPrice, "Treasury: PARTIAL price moved");
        require(
            partialPrice < partialPriceOne, // price < $0.5
            "Treasury: partialPrice not eligible for bond purchase"
        );

        require(_partialAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _partialAmount.mul(_rate).div(1e18);
        uint256 partialSupply = getPartialCirculatingSupply();
        uint256 newBondSupply = IERC20(pbond_).totalSupply().add(_bondAmount);
        require(newBondSupply <= partialSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(partial_).burnFrom(msg.sender, _partialAmount);
        bool mintBondSuccess = IBasisAsset(pbond_).mint(msg.sender, _bondAmount);
        require(mintBondSuccess, "Treasury: bond minting failed");

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_partialAmount);
        _updatePartialPrice();

        emit BoughtBonds(msg.sender, _partialAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 partialPrice = getPartialPrice();
        require(partialPrice == targetPrice, "Treasury: PARTIAL price moved");
        require(
            partialPrice > partialPriceCeiling, // price > 0.505
            "Treasury: partialPrice not eligible for bond redeem"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _partialAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(partial_).balanceOf(address(this)) >= _partialAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _partialAmount));

        IBasisAsset(pbond_).burnFrom(msg.sender, _bondAmount);
        IERC20(partial_).safeTransfer(msg.sender, _partialAmount);

        _updatePartialPrice();

        emit RedeemedBonds(msg.sender, _partialAmount, _bondAmount);
    }

    function _sendToBoardroom(uint256 _amount) internal {
        bool mintPartialSuccess = IBasisAsset(partial_).mint(address(this), _amount);
        require(mintPartialSuccess, "Treasury: partial minting failed");

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(partial_).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(partial_).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(now, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(partial_).safeDecreaseAllowance(boardroom, 0);
        IERC20(partial_).safeIncreaseAllowance(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);
        emit BoardroomFunded(now, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _partialSupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_partialSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updatePartialPrice();
        previousEpochPartialPrice = getPartialPrice();
        uint256 partialSupply = getPartialCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToBoardroom(partialSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochPartialPrice > partialPriceCeiling) {
                // Expansion ($PARTIAL Price > 0.505): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(pbond_).totalSupply();
                uint256 _percentage = previousEpochPartialPrice.sub(partialPriceOne);
                uint256 _savedForBond;
                uint256 _savedForBoardroom;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(partialSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForBoardroom = partialSupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = partialSupply.mul(_percentage).div(1e18);
                    _savedForBoardroom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForBoardroom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBoardroom > 0) {
                    _sendToBoardroom(_savedForBoardroom);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    bool mintPartialSuccess = IBasisAsset(partial_).mint(address(this), _savedForBond);
                    require(mintPartialSuccess, "Treasury: partial minting failed");
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(partial_), "partial");
        require(address(_token) != address(pbond_), "bond");
        require(address(_token) != address(pshare_), "share");
        _token.safeTransfer(_to, _amount);
    }

    function boardroomSetOperator(address _operator) external onlyOperator {
        IBoardroom(boardroom).setOperator(_operator);
    }

    function boardroomSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IBoardroom(boardroom).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function boardroomAllocateSeigniorage(uint256 amount) external onlyOperator {
        IBoardroom(boardroom).allocateSeigniorage(amount);
    }

    function boardroomGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IBoardroom(boardroom).governanceRecoverUnsupported(_token, _amount, _to);
    }
}