pragma solidity 0.5.10;
import "./lib/CompoundOracleInterface.sol";
import "./OptionsExchange.sol";
import "./OptionsUtils.sol";
import "./lib/UniswapFactoryInterface.sol";
import "./lib/UniswapExchangeInterface.sol";
import "./FixedPointUint256.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";


/**
 * @title Opyn's Options Contract
 * @author Opyn
 */
contract OptionsContract is Ownable, ERC20 {
    using FixedPointUint256 for uint256;

    // Keeps track of the weighted collateral and weighted debt for each vault.
    struct Vault {
        uint256 collateral;
        uint256 oTokensIssued;
        uint256 underlying;
        bool owned;
    }

    OptionsExchange public optionsExchange;

    mapping(address => Vault) internal vaults;

    address payable[] public vaultOwners;

    // The amount of reward paid out to the liquidatiors scaled by 1e18. Set at 1%.
    uint256 public liquidationIncentive = 1e16;

    /* Max amount that a Vault can be liquidated by i.e.
    max collateral that can be taken in one function call. 
    Scaled by 1e18. Set to 0.5 i.e half th vault */
    uint256 public liquidationFactor = 5 * 1e17;

    /* The minimum ratio of a Vault's collateral to insurance promised. Set at 100%
    The ratio is calculated as below:
    vault.collateral / (Vault.oTokensIssued * strikePrice) */
    uint256 public minCollateralizationRatio = 1e18;

    // The amount of insurance promised per oToken
    uint256 public strikePrice;

    /* UNIX time.
    Exercise period starts at `(expiry - windowSize)` and ends at `expiry` */
    uint256 internal windowSize;

    // The time of expiry of the options contract
    uint256 public expiry;

    // The collateral asset
    IERC20 public collateral;

    // The asset being protected by the insurance
    IERC20 public underlying;

    // The asset in which insurance is denominated in.
    IERC20 public strike;

    // The Oracle used for the contract
    CompoundOracleInterface public compoundOracle;

    // The name of  the contract
    string public name;

    // The symbol of  the contract
    string public symbol;

    // The uint256 of decimals of the contract
    uint8 public decimals = 18;

    /**
     * @param _collateral The collateral asset
     * @param _underlying The asset that is being protected
     * @param _strikePrice The amount of strike asset that will be paid out per oToken
     * @param _strike The asset in which the insurance is calculated
     * @param _expiry The time at which the insurance expires
     * @param _optionsExchange The contract which interfaces with the exchange + oracle
     * @param _oracleAddress The address of the oracle
     * @param _windowSize UNIX time. Exercise window is from `expiry - _windowSize` to `expiry`.
     */
    constructor(
        IERC20 _collateral,
        IERC20 _underlying,
        uint256 _strikePrice,
        IERC20 _strike,
        uint256 _expiry,
        OptionsExchange _optionsExchange,
        address _oracleAddress,
        uint256 _windowSize
    ) public {
        require(block.timestamp < _expiry, "Can't deploy an expired contract");
        require(
            _windowSize <= _expiry,
            "Exercise window can't be longer than the contract's lifespan"
        );

        collateral = _collateral;
        underlying = _underlying;

        strikePrice = _strikePrice;
        strike = _strike;

        expiry = _expiry;
        compoundOracle = CompoundOracleInterface(_oracleAddress);
        optionsExchange = _optionsExchange;
        windowSize = _windowSize;
    }

    /*** Events ***/
    event VaultOpened(address payable vaultOwner);
    event ETHCollateralAdded(
        address payable vaultOwner,
        uint256 amount,
        address payer
    );
    event ERC20CollateralAdded(
        address payable vaultOwner,
        uint256 amount,
        address payer
    );
    event IssuedOTokens(
        address issuedTo,
        uint256 oTokensIssued,
        address payable vaultOwner
    );
    event Liquidate(
        uint256 amtCollateralToPay,
        address payable vaultOwner,
        address payable liquidator
    );
    event Exercise(
        uint256 amtUnderlyingToPay,
        uint256 amtCollateralToPay,
        address payable exerciser,
        address payable vaultExercisedFrom
    );
    event RedeemVaultBalance(
        uint256 amtCollateralRedeemed,
        uint256 amtUnderlyingRedeemed,
        address payable vaultOwner
    );
    event BurnOTokens(address payable vaultOwner, uint256 oTokensBurned);
    event RemoveCollateral(uint256 amtRemoved, address payable vaultOwner);
    event UpdateParameters(
        uint256 liquidationIncentive,
        uint256 liquidationFactor,
        uint256 minCollateralizationRatio,
        address owner
    );
    event RemoveUnderlying(
        uint256 amountUnderlying,
        address payable vaultOwner
    );

    /**
     * @dev Throws if called Options contract is expired.
     */
    modifier notExpired() {
        require(!hasExpired(), "Options contract expired");
        _;
    }

    /**
     * @notice This function gets the length of vaultOwners array
     */
    function getVaultOwnersLength() public view returns (uint256) {
        return vaultOwners.length;
    }

    /**
     * @notice Can only be called by owner. Used to update the fees, minminCollateralizationRatio, etc
     * @param _liquidationIncentive The incentive paid to liquidator. 10 is 0.01 i.e. 1% incentive.
     * @param _liquidationFactor Max amount that a Vault can be liquidated by. 500 is 0.5.
     * @param _minCollateralizationRatio The minimum ratio of a Vault's collateral to insurance promised. 16 means 1.6.
     */
    function updateParameters(
        uint256 _liquidationIncentive,
        uint256 _liquidationFactor,
        uint256 _minCollateralizationRatio
    ) public onlyOwner {
        require(
            _liquidationIncentive <= 2 * 1e17,
            "Can't have >20% liquidation incentive"
        );
        require(
            _liquidationFactor <= 1e18,
            "Can't liquidate more than 100% of the vault"
        );
        require(
            _minCollateralizationRatio >= 1e18,
            "Can't have minCollateralizationRatio < 1"
        );

        liquidationIncentive.value = _liquidationIncentive;
        liquidationFactor.value = _liquidationFactor;
        minCollateralizationRatio.value = _minCollateralizationRatio;

        emit UpdateParameters(
            _liquidationIncentive,
            _liquidationFactor,
            _minCollateralizationRatio,
            owner()
        );
    }

    /**
     * @notice Can only be called by owner. Used to set the name, symbol and decimals of the contract
     * @param _name The name of the contract
     * @param _symbol The symbol of the contract
     */
    function setDetails(string memory _name, string memory _symbol)
        public
        onlyOwner
    {
        name = _name;
        symbol = _symbol;
    }

    /**
     * @notice Checks if a `owner` has already created a Vault
     * @param owner The address of the supposed owner
     * @return true or false
     */
    function hasVault(address payable owner) public view returns (bool) {
        return vaults[owner].owned;
    }

    /**
     * @notice Creates a new empty Vault and sets the owner of the vault to be the msg.sender.
     */
    function openVault() public notExpired returns (bool) {
        require(!hasVault(msg.sender), "Vault already created");

        vaults[msg.sender] = Vault(0, 0, 0, true);
        vaultOwners.push(msg.sender);

        emit VaultOpened(msg.sender);
        return true;
    }

    /**
     * @notice If the collateral type is ETH, anyone can call this function any time before
     * expiry to increase the amount of collateral in a Vault. Will fail if ETH is not the
     * collateral asset.
     * Remember that adding ETH collateral even if no oTokens have been created can put the owner at a
     * risk of losing the collateral if an exercise event happens.
     * Ensure that you issue and immediately sell oTokens to allow the owner to earn premiums.
     * (Either call the createAndSell function in the oToken contract or batch the
     * addERC20Collateral, issueOTokens and sell transactions and ensure they happen atomically to protect
     * the end user).
     * @param vaultOwner the index of the Vault to which collateral will be added.
     */
    function addETHCollateral(address payable vaultOwner)
        public
        payable
        notExpired
        returns (uint256)
    {
        require(isETH(collateral), "ETH is not the specified collateral type");
        require(hasVault(vaultOwner), "Vault does not exist");

        emit ETHCollateralAdded(vaultOwner, msg.value, msg.sender);
        return _addCollateral(vaultOwner, msg.value);
    }

    /**
     * @notice If the collateral type is any ERC20, anyone can call this function any time before
     * expiry to increase the amount of collateral in a Vault. Can only transfer in the collateral asset.
     * Will fail if ETH is the collateral asset.
     * The user has to allow the contract to handle their ERC20 tokens on his behalf before these
     * functions are called.
     * Remember that adding ERC20 collateral even if no oTokens have been created can put the owner at a
     * risk of losing the collateral. Ensure that you issue and immediately sell the oTokens!
     * (Either call the createAndSell function in the oToken contract or batch the
     * addERC20Collateral, issueOTokens and sell transactions and ensure they happen atomically to protect
     * the end user).
     * @param vaultOwner the index of the Vault to which collateral will be added.
     * @param amt the amount of collateral to be transferred in.
     */
    function addERC20Collateral(address payable vaultOwner, uint256 amt)
        public
        notExpired
        returns (uint256)
    {
        require(
            collateral.transferFrom(msg.sender, address(this), amt),
            "Could not transfer in collateral tokens"
        );
        require(hasVault(vaultOwner), "Vault does not exist");

        emit ERC20CollateralAdded(vaultOwner, amt, msg.sender);
        return _addCollateral(vaultOwner, amt);
    }

    /**
     * @notice Returns the amount of underlying to be transferred during an exercise call
     */
    function underlyingRequiredToExercise(uint256 oTokensToExercise)
        public
        view
        returns (uint256)
    {
        uint256 underlyingDecimals = getDecimals(address(underlying));
        require(
            underlyingDecimals <= 18,
            "Can't support underling assets with more than 18 decimals"
        );

        uint256 underlyingToExercise = oTokensToExercise.mul(
            10**underlyingDecimals
        );
        require(
            underlyingToExercise > 0,
            "Can't exercise by paying 0 underlying tokens"
        );

        return underlyingToExercise;
    }

    /**
     * @notice Returns true if exercise can be called
     */
    function isExerciseWindow() public view returns (bool) {
        return ((block.timestamp >= expiry.sub(windowSize)) &&
            (block.timestamp < expiry));
    }

    /**
     * @notice Returns true if the oToken contract has expired
     */
    function hasExpired() public view returns (bool) {
        return (block.timestamp >= expiry);
    }

    /**
     * @notice Called by anyone holding the oTokens and underlying during the
     * exercise window i.e. from `expiry - windowSize` time to `expiry` time. The caller
     * transfers in their oTokens and corresponding amount of underlying and gets
     * `strikePrice * oTokens` amount of collateral out. The collateral paid out is taken from
     * the each vault owner starting with the first and iterating until the oTokens to exercise
     * are found.
     * NOTE: This uses a for loop and hence could run out of gas if the array passed in is too big!
     * @param oTokensToExercise the uint256 of oTokens being exercised.
     * @param vaultsToExerciseFrom the array of vaults to exercise from.
     */
    function exercise(
        uint256 oTokensToExercise,
        address payable[] memory vaultsToExerciseFrom
    ) public payable {
        for (uint256 i = 0; i < vaultsToExerciseFrom.length; i++) {
            address payable vaultOwner = vaultsToExerciseFrom[i];
            require(
                hasVault(vaultOwner),
                "Cannot exercise from a vault that doesn't exist"
            );
            Vault storage vault = vaults[vaultOwner];
            if (oTokensToExercise == 0) {
                return;
            } else if (vault.oTokensIssued >= oTokensToExercise) {
                _exercise(oTokensToExercise, vaultOwner);
                return;
            } else {
                oTokensToExercise = oTokensToExercise.sub(vault.oTokensIssued);
                _exercise(vault.oTokensIssued, vaultOwner);
            }
        }
        require(
            oTokensToExercise == 0,
            "Specified vaults have insufficient collateral"
        );
    }

    /**
     * @notice This function allows the vault owner to remove their share of underlying after an exercise
     */
    function removeUnderlying() public {
        require(hasVault(msg.sender), "Vault does not exist");
        Vault storage vault = vaults[msg.sender];

        require(vault.underlying > 0, "No underlying balance");

        uint256 underlyingToTransfer = vault.underlying;
        vault.underlying = 0;

        transferUnderlying(msg.sender, underlyingToTransfer);
        emit RemoveUnderlying(underlyingToTransfer, msg.sender);
    }

    /**
     * @notice This function is called to issue the option tokens. Remember that issuing oTokens even if they
     * haven't been sold can put the owner at a risk of not making premiums on the oTokens. Ensure that you
     * issue and immidiately sell the oTokens! (Either call the createAndSell function in the oToken contract
     * of batch the issueOTokens transaction with a sell transaction and ensure it happens atomically).
     * @dev The owner of a Vault should only be able to have a max of
     * repo.collateral * collateralToStrike / (minminCollateralizationRatio * strikePrice) tokens issued.
     * @param oTokensToIssue The uint256 of o tokens to issue
     * @param receiver The address to send the oTokens to
     */
    function issueOTokens(uint256 oTokensToIssue, address receiver)
        public
        notExpired
    {
        //check that we're properly collateralized to mint this uint256, then call _mint(address account, uint256 amount)
        require(hasVault(msg.sender), "Vault does not exist");

        Vault storage vault = vaults[msg.sender];

        // checks that the vault is sufficiently collateralized
        uint256 newOTokensBalance = vault.oTokensIssued.add(oTokensToIssue);
        require(isSafe(vault.collateral, newOTokensBalance), "unsafe to mint");

        // issue the oTokens
        vault.oTokensIssued = newOTokensBalance;
        _mint(receiver, oTokensToIssue);

        emit IssuedOTokens(receiver, oTokensToIssue, msg.sender);
        return;
    }

    /**
     * @notice Returns the vault for a given address
     * @param vaultOwner the owner of the Vault to return
     */
    function getVault(address payable vaultOwner)
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            bool
        )
    {
        Vault storage vault = vaults[vaultOwner];
        return (
            vault.collateral,
            vault.oTokensIssued,
            vault.underlying,
            vault.owned
        );
    }

    /**
     * @notice Returns true if the given ERC20 is ETH.
     * @param _ierc20 the ERC20 asset.
     */
    function isETH(IERC20 _ierc20) public pure returns (bool) {
        return _ierc20 == IERC20(0);
    }

    /**
     * @notice allows the owner to burn their oTokens to increase the collateralization ratio of
     * their vault.
     * @param amtToBurn uint256 of oTokens to burn
     * @dev only want to call this function before expiry. After expiry, no benefit to calling it.
     */
    function burnOTokens(uint256 amtToBurn) public notExpired {
        require(hasVault(msg.sender), "Vault does not exist");

        Vault storage vault = vaults[msg.sender];

        vault.oTokensIssued = vault.oTokensIssued.sub(amtToBurn);
        _burn(msg.sender, amtToBurn);

        emit BurnOTokens(msg.sender, amtToBurn);
    }

    /**
     * @notice allows the owner to remove excess collateral from the vault before expiry. Removing collateral lowers
     * the collateralization ratio of the vault.
     * @param amtToRemove Amount of collateral to remove in 10^-18.
     */
    function removeCollateral(uint256 amtToRemove) public notExpired {
        require(amtToRemove > 0, "Cannot remove 0 collateral");
        require(hasVault(msg.sender), "Vault does not exist");

        Vault storage vault = vaults[msg.sender];
        require(
            amtToRemove <= getCollateral(msg.sender),
            "Can't remove more collateral than owned"
        );

        // check that vault will remain safe after removing collateral
        uint256 newCollateralBalance = vault.collateral.sub(amtToRemove);

        require(
            isSafe(newCollateralBalance, vault.oTokensIssued),
            "Vault is unsafe"
        );

        // remove the collateral
        vault.collateral = newCollateralBalance;
        transferCollateral(msg.sender, amtToRemove);

        emit RemoveCollateral(amtToRemove, msg.sender);
    }

    /**
     * @notice after expiry, each vault holder can get back their proportional share of collateral
     * from vaults that they own.
     * @dev The owner gets all of their collateral back if no exercise event took their collateral.
     */
    function redeemVaultBalance() public {
        require(hasExpired(), "Can't collect collateral until expiry");
        require(hasVault(msg.sender), "Vault does not exist");

        // pay out owner their share
        Vault storage vault = vaults[msg.sender];

        // To deal with lower precision
        uint256 collateralToTransfer = vault.collateral;
        uint256 underlyingToTransfer = vault.underlying;

        vault.collateral = 0;
        vault.oTokensIssued = 0;
        vault.underlying = 0;

        transferCollateral(msg.sender, collateralToTransfer);
        transferUnderlying(msg.sender, underlyingToTransfer);

        emit RedeemVaultBalance(
            collateralToTransfer,
            underlyingToTransfer,
            msg.sender
        );
    }

    /**
     * This function returns the maximum amount of collateral liquidatable if the given vault is unsafe
     * @param vaultOwner The index of the vault to be liquidated
     */
    function maxOTokensLiquidatable(address payable vaultOwner)
        public
        view
        returns (uint256)
    {
        if (isUnsafe(vaultOwner)) {
            Vault storage vault = vaults[vaultOwner];
            uint256 maxCollateralLiquidatable = vault
                .collateral
                .mul(liquidationFactor.value)
                .div(10**uint256(-liquidationFactor.exponent));

            uint256 one = 10**uint256(-liquidationIncentive.exponent);
            uint256 liqIncentive = uint256(
                liquidationIncentive.value.add(one),
                liquidationIncentive.exponent
            );
            return calculateOTokens(maxCollateralLiquidatable, liqIncentive);
        } else {
            return 0;
        }
    }

    /**
     * @notice This function can be called by anyone who notices a vault is undercollateralized.
     * The caller gets a reward for reducing the amount of oTokens in circulation.
     * @dev Liquidator comes with _oTokens. They get _oTokens * strikePrice * (incentive + fee)
     * amount of collateral out. They can liquidate a max of liquidationFactor * vault.collateral out
     * in one function call i.e. partial liquidations.
     * @param vaultOwner The index of the vault to be liquidated
     * @param oTokensToLiquidate The uint256 of oTokens being taken out of circulation
     */
    function liquidate(address payable vaultOwner, uint256 oTokensToLiquidate)
        public
        notExpired
    {
        require(hasVault(vaultOwner), "Vault does not exist");

        Vault storage vault = vaults[vaultOwner];

        // cannot liquidate a safe vault.
        require(isUnsafe(vaultOwner), "Vault is safe");

        // Owner can't liquidate themselves
        require(msg.sender != vaultOwner, "Owner can't liquidate themselves");

        uint256 amtCollateral = calculateCollateralToPay(
            oTokensToLiquidate,
            uint256(1, 0)
        );
        uint256 amtIncentive = calculateCollateralToPay(
            oTokensToLiquidate,
            liquidationIncentive
        );
        uint256 amtCollateralToPay = amtCollateral.add(amtIncentive);

        // calculate the maximum amount of collateral that can be liquidated
        uint256 maxCollateralLiquidatable = vault.collateral.mul(
            liquidationFactor.value
        );

        if (liquidationFactor.exponent > 0) {
            maxCollateralLiquidatable = maxCollateralLiquidatable.mul(
                10**uint256(liquidationFactor.exponent)
            );
        } else {
            maxCollateralLiquidatable = maxCollateralLiquidatable.div(
                10**uint256(-1 * liquidationFactor.exponent)
            );
        }

        require(
            amtCollateralToPay <= maxCollateralLiquidatable,
            "Can only liquidate liquidation factor at any given time"
        );

        // deduct the collateral and oTokensIssued
        vault.collateral = vault.collateral.sub(amtCollateralToPay);
        vault.oTokensIssued = vault.oTokensIssued.sub(oTokensToLiquidate);

        // transfer the collateral and burn the _oTokens
        _burn(msg.sender, oTokensToLiquidate);
        transferCollateral(msg.sender, amtCollateralToPay);

        emit Liquidate(amtCollateralToPay, vaultOwner, msg.sender);
    }

    /**
     * @notice checks if a vault is unsafe. If so, it can be liquidated
     * @param vaultOwner The uint256 of the vault to check
     * @return true or false
     */
    function isUnsafe(address payable vaultOwner) public view returns (bool) {
        bool stillUnsafe = !isSafe(
            getCollateral(vaultOwner),
            getOTokensIssued(vaultOwner)
        );
        return stillUnsafe;
    }

    /**
     * @notice This function calculates and returns the amount of collateral in the vault
     */
    function getCollateral(address payable vaultOwner)
        internal
        view
        returns (uint256)
    {
        Vault storage vault = vaults[vaultOwner];
        return vault.collateral;
    }

    /**
     * @notice This function calculates and returns the amount of puts issued by the Vault
     */
    function getOTokensIssued(address payable vaultOwner)
        internal
        view
        returns (uint256)
    {
        Vault storage vault = vaults[vaultOwner];
        return vault.oTokensIssued;
    }

    /**
     * @notice Called by anyone holding the oTokens and underlying during the
     * exercise window i.e. from `expiry - windowSize` time to `expiry` time. The caller
     * transfers in their oTokens and corresponding amount of underlying and gets
     * `strikePrice * oTokens` amount of collateral out. The collateral paid out is taken from
     * the specified vault holder. At the end of the expiry window, the vault holder can redeem their balance
     * of collateral. The vault owner can withdraw their underlying at any time.
     * The user has to allow the contract to handle their oTokens and underlying on his behalf before these functions are called.
     * @param oTokensToExercise the uint256 of oTokens being exercised.
     * @param vaultToExerciseFrom the address of the vaultOwner to take collateral from.
     * @dev oTokenExchangeRate is the uint256 of underlying tokens that 1 oToken protects.
     */
    function _exercise(
        uint256 oTokensToExercise,
        address payable vaultToExerciseFrom
    ) internal {
        // 1. before exercise window: revert
        require(
            isExerciseWindow(),
            "Can't exercise outside of the exercise window"
        );

        require(hasVault(vaultToExerciseFrom), "Vault does not exist");

        Vault storage vault = vaults[vaultToExerciseFrom];
        require(oTokensToExercise > 0, "Can't exercise 0 oTokens");
        // Check correct amount of oTokens passed in)
        require(
            oTokensToExercise <= vault.oTokensIssued,
            "Can't exercise more oTokens than the owner has"
        );
        // Ensure person calling has enough oTokens
        require(
            balanceOf(msg.sender) >= oTokensToExercise,
            "Not enough oTokens"
        );

        // 1. Check sufficient underlying
        // 1.1 update underlying balances
        uint256 amtUnderlyingToPay = underlyingRequiredToExercise(
            oTokensToExercise
        );
        vault.underlying = vault.underlying.add(amtUnderlyingToPay);

        // 2. Calculate Collateral to pay
        // 2.1 Payout enough collateral to get (strikePrice * oTokens) amount of collateral
        uint256 amtCollateralToPay = calculateCollateralToPay(
            oTokensToExercise,
            uint256(1, 0)
        );

        uint256 totalCollateralToPay = amtCollateralToPay;
        require(
            totalCollateralToPay <= vault.collateral,
            "Vault underwater, can't exercise"
        );

        // 3. Update collateral + oToken balances
        vault.collateral = vault.collateral.sub(totalCollateralToPay);
        vault.oTokensIssued = vault.oTokensIssued.sub(oTokensToExercise);

        // 4. Transfer in underlying, burn oTokens + pay out collateral
        // 4.1 Transfer in underlying
        if (isETH(underlying)) {
            require(msg.value == amtUnderlyingToPay, "Incorrect msg.value");
        } else {
            require(
                underlying.transferFrom(
                    msg.sender,
                    address(this),
                    amtUnderlyingToPay
                ),
                "Could not transfer in tokens"
            );
        }
        // 4.2 burn oTokens
        _burn(msg.sender, oTokensToExercise);

        // 4.3 Pay out collateral
        transferCollateral(msg.sender, amtCollateralToPay);

        emit Exercise(
            amtUnderlyingToPay,
            amtCollateralToPay,
            msg.sender,
            vaultToExerciseFrom
        );
    }

    /**
     * @notice adds `_amt` collateral to `vaultOwner` and returns the new balance of the vault
     * @param vaultOwner the index of the vault
     * @param amt the amount of collateral to add
     */
    function _addCollateral(address payable vaultOwner, uint256 amt)
        internal
        notExpired
        returns (uint256)
    {
        Vault storage vault = vaults[vaultOwner];
        vault.collateral = vault.collateral.add(amt);

        return vault.collateral;
    }

    /**
     * @notice checks if a hypothetical vault is safe with the given collateralAmt and oTokensIssued
     * @param collateralAmt The amount of collateral the hypothetical vault has
     * @param oTokensIssued The amount of oTokens generated by the hypothetical vault
     * @return true or false
     */
    function isSafe(uint256 collateralAmt, uint256 oTokensIssued)
        internal
        view
        returns (bool)
    {
        // get price from Oracle
        uint256 collateralToEthPrice = 1;
        uint256 strikeToEthPrice = 1;

        if (collateral != strike) {
            collateralToEthPrice = getPrice(address(collateral));
            strikeToEthPrice = getPrice(address(strike));
        }

        // check `oTokensIssued * minCollateralizationRatio * strikePrice <= collAmt * collateralToStrikePrice`
        uint256 liabilities = oTokensIssued.mul(minCollateralizationRatio).mul(
            strikePrice
        );

        uint256 collateralDecimals = getDecimals(address(collateral));
        require(
            collateralDecimals <= 18,
            "Can't support collateral with more than 18 decimal digits"
        );

        uint256 scalingFactor = 18.sub(collateralDecimals);
        uint256 assets = collateralAmt
            .mul(10**scalingFactor)
            .mul(collateralToEthPrice)
            .div(strikeToEthPrice);

        return liabilities <= assets;
    }

    function maxOTokensIssuable(uint256 collateralAmt)
        public
        view
        returns (uint256)
    {
        return calculateOTokens(collateralAmt, minCollateralizationRatio);
    }

    function calculateOTokens(uint256 collateralAmt, uint256 proportion)
        internal
        view
        returns (uint256)
    {
        uint256 collateralToEthPrice = 1;
        uint256 strikeToEthPrice = 1;

        if (collateral != strike) {
            collateralToEthPrice = getPrice(address(collateral));
            strikeToEthPrice = getPrice(address(strike));
        }

        uint256 collateralDecimals = getDecimals(address(collateral));
        require(
            collateralDecimals <= 18,
            "Can't support collateral with more than 18 decimal digits"
        );

        uint256 scalingFactor = 18.sub(collateralDecimals);

        return
            collateralAmt
                .mul(10**scalingFactor)
                .mul(collateralToEthPrice)
                .div(strikeToEthPrice)
                .div(strikePrice)
                .div(proportion);
    }

    function calculateCollateralToPay(uint256 _oTokens, uint256 proportion)
        internal
        view
        returns (uint256)
    {
        uint256 collateralToEthPrice = 1;
        uint256 strikeToEthPrice = 1;

        if (collateral != strike) {
            collateralToEthPrice = getPrice(address(collateral));
            strikeToEthPrice = getPrice(address(strike));
        }

        uint256 collateralDecimals = getDecimals(address(collateral));
        require(
            collateralDecimals <= 18,
            "Can't support collateral with more than 18 decimal digits"
        );

        uint256 scalingFactor = 18.sub(collateralDecimals);

        return
            _oTokens
                .mul(proportion)
                .mul(strikePrice)
                .mul(strikeToEthPrice)
                .div(collateralToEthPrice)
                .div(10**scalingFactor);
    }

    function transferCollateral(address payable _addr, uint256 _amt) internal {
        if (isETH(collateral)) {
            _addr.transfer(_amt);
        } else {
            collateral.transfer(_addr, _amt);
        }
    }

    function transferUnderlying(address payable _addr, uint256 _amt) internal {
        if (isETH(underlying)) {
            _addr.transfer(_amt);
        } else {
            underlying.transfer(_addr, _amt);
        }
    }

    function getPrice(address asset) internal view returns (uint256) {
        if (asset == address(0)) {
            return (10**18);
        } else {
            return compoundOracle.getPrice(asset);
        }
    }

    function getDecimals(address _asset) internal view returns (uint256) {
        if (_asset == address(0)) {
            return 18;
        }
        ERC20Detailed asset = ERC20Detailed(_asset);
        return uint256(asset.decimals());
    }
}
