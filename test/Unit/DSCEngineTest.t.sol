// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentStablecoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/Helper.s.sol";
import {ERC20Mock} from "../Mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../Mocks/mockV3Aggregator.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {MockFailedTransferFrom} from "../Mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDSC} from "../Mocks/MockFailedMintDsc.sol";
import {MockFailedTransfer} from "../Mocks/MockFailedTransfer.sol";

contract DSCEngineTEst is Test {
    DeployDsc deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant COLLATERAL_AMOUNT = 200 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 2000 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 5000;
    uint256 public constant EXPECTED_HEALTH_FACTOR = 0.2e18; // 2e17

    uint256 amountToMint = 100 ether;
    uint256 amountCollateral = 500 ether;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDsc();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = config
            .activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////////
    /// Constructor Tests /////
    ///////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeed() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeTheSameLength
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////////
    /// Price Tests /////
    /////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 200 ether;
        uint256 expectedWeth = 0.1 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    //////////////////////////////////
    /// Deposit Collateral Tests /////
    //////////////////////////////////

    function testRevertIfTransferFromFails() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();
        tokenAddresses = [address(mockCollateralToken)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsc = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(dsc)
        );
        mockCollateralToken.mint(USER, amountCollateral);
        vm.startPrank(USER);
        ERC20Mock(address(mockCollateralToken)).approve(
            address(mockDsc),
            amountCollateral
        );
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsc.depositCollateral(
            address(mockCollateralToken),
            amountCollateral
        );
        vm.stopPrank();
    }

    function testRevertsIfCollateralisZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock numToken = new ERC20Mock("FLY", "FLY", USER, 100e18);
        vm.startPrank(USER);
        vm.expectRevert(
            (
                abi.encodeWithSelector(
                    DSCEngine.DSCEngine__TokenNotAllowed.selector,
                    address(numToken)
                )
            )
        );
        engine.depositCollateral(address(numToken), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), COLLATERAL_AMOUNT);
        //ERC20Mock(wbtc).approve(address(this), COLLATERAL_AMOUNT);
        engine.depositCollateral(weth, COLLATERAL_AMOUNT);
        //engine.depositCollateral(wbtc, COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine
            .getAccountInfo(USER);

        uint256 expectedDscMinted = 0;
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(COLLATERAL_AMOUNT, expectedDepositAmount);
    }

    function testDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        amountToMint =
            (amountCollateral *
                (uint256(price) * engine.getAdditionalFeedPrecision())) /
            engine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        uint256 expectedHealthFactor = engine.calculateHealthFactor(
            amountToMint,
            engine.getUsdValue(weth, amountCollateral)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral()
        public
        depositedCollateralAndMintedDsc
    {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintDsc Tests //
    ///////////////////////////////////

    function testRevertIfMintFails() public {
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.stopPrank();
    }

    function testRevertIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor()
        public
        depositedCollateral
    {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        amountToMint =
            (amountCollateral *
                (uint256(price) * engine.getAdditionalFeedPrecision())) /
            engine.getPrecision();

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                EXPECTED_HEALTH_FACTOR
            )
        );
        engine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(USER);
        engine.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnDsc Tests //
    ///////////////////////////////////

    function testIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    function testCanBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(engine), amountToMint);
        engine.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testBurnPartialDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);

        // Mint sample DSC
        uint256 mintAmount = 100e18;
        engine.mintDsc(mintAmount);

        // Burn Half
        uint256 burnAmount = 50e18;
        dsc.approve(address(engine), burnAmount);
        engine.burnDsc(burnAmount);

        uint256 remainingBalance = dsc.balanceOf(USER);
        assertEq(remainingBalance, mintAmount - burnAmount);
        vm.stopPrank();
    }

    function testBurnWithMultipleCollaterals() public {
        vm.startPrank(USER);

        // Approving and Depositing the Collateral
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        ERC20Mock(wbtc).approve(address(engine), amountCollateral);

        engine.depositCollateral(weth, amountCollateral);
        engine.depositCollateral(wbtc, amountCollateral);

        // Mint Dsc with both collateral
        uint256 mintAmount = 150e18;
        engine.mintDsc(mintAmount);

        // Partial burn
        uint256 burnAmount = 100e18;
        dsc.approve(address(engine), burnAmount);
        engine.burnDsc(burnAmount);

        // Checking Balance
        uint256 remainingAmount = dsc.balanceOf(USER);
        assertEq(remainingAmount, mintAmount - burnAmount);
        vm.stopPrank();
    }

    function testRevertWhenBurningMoreThanYouOwn() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);

        uint256 mintAmount = 200e18;
        engine.mintDsc(mintAmount);

        uint256 burnAmount = 250e18;
        dsc.approve(address(engine), burnAmount);
        vm.expectRevert();
        engine.burnDsc(burnAmount);

        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    function testRevertIfTransferFails() public {
        address owner = msg.sender;
        vm.prank(owner);

        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];

        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.mint(USER, amountCollateral);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));

        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(
            address(mockDsce),
            amountCollateral
        );
        mockDsce.depositCollateral(address(mockDsc), amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), amountCollateral);
        vm.stopPrank();
    }

    function testIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    // function testCanRedeemCollateral() public depositedCollateral {
    //     vm.startPrank(USER);
    //     uint256 userBalanceBeforeRedeem = engine.getCollateralBalanceOfUser(
    //         weth,
    //         USER
    //     );
    //     assertEq(
    //         userBalanceBeforeRedeem,
    //         amountCollateral,
    //         "Collateral balance mismatch"
    //     );
    //     vm.expectEmit(true, true, true, true);
    //     emit CollateralRedeemed(USER, USER, weth, amountCollateral);
    //     engine.redeemCollateral(weth, amountCollateral);
    //     uint256 userBalanceAfterRedeem = engine.getCollateralBalanceOfUser(
    //         weth,
    //         USER
    //     );
    //     assertEq(userBalanceAfterRedeem, 0);
    //     vm.stopPrank();
    // }

    // function testCollateralRedeemedWithCorrectArgs()
    //     public
    //     depositedCollateral
    // {
    //     vm.expectEmit(true, true, true, true, address(engine));
    //     emit CollateralRedeemed(USER, USER, weth, amountCollateral);
    //     vm.startPrank(USER);
    //     engine.redeemCollateral(weth, amountCollateral);
    //     vm.stopPrank();
    // }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////
}
