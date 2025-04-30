// SPDX-License-Identifier: MIT
// Have our invariant aka properties

// What are our invariants

// 1. The total supply of DSC should be less than the total value of collateral

// 2. Getter view functions should never revert < evergreen invariant>

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentStablecoin.sol";
import {HelperConfig} from "../../script/Helper.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract Invariant is StdInvariant, Test {
    DeployDsc deployer;
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDsc();
        (dsc, engine, config) = deployer.run();
        (, , weth, wbtc, ) = config.activeNetworkConfig();
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
        //targetContract(address(engine));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value: ", wethValue);
        console.log("wbtc value: ", wbtcValue);

        console.log("Total Supply: ", totalSupply);
        console.log("Times mint is called: ", handler.timesMintsCalled());

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        engine.getDscBalance(msg.sender);
        engine.getPrecision();
        engine.getAdditionalFeedPrecision();
        engine.getLiquidationThreshold();
        engine.getLiquidationBonus();
        engine.getLiquidationPrecision();
        engine.getMinHealthFactor();
        engine.getCollateralTokens();
        engine.getDsc();
        engine.getHealthFactor(msg.sender);
    }
}
