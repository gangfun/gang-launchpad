// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {CreatorFeeTest} from "../gang/CreatorFee.t.sol";
import {GradTargetTest} from "../gang/GradTarget.t.sol";
import {GradTargetPricingTest} from "../gang/GradTargetPricing.t.sol";
import {OriginTraderTest} from "../gang/OriginTrader.t.sol";
import {GangBondTest} from "../gang/GangBond.t.sol";
import {GangBondPairTaxTest} from "../gang/GangBondPairTax.t.sol";
import {GangBuybackSplitterTest} from "../gang/GangBuybackSplitter.t.sol";
import {GangBuybackSplitterPairTaxTest} from "../gang/GangBuybackSplitterPairTax.t.sol";
import {GangComboSplitterTest} from "../gang/GangComboSplitter.t.sol";
import {GangComboSplitterPairTaxTest} from "../gang/GangComboSplitterPairTax.t.sol";
import {GangLiquiditySplitterTest} from "../gang/GangLiquiditySplitter.t.sol";
import {GangLiquiditySplitterPairTaxTest} from "../gang/GangLiquiditySplitterPairTax.t.sol";
import {GangSplitModuleTest} from "../gang/GangSplitModule.t.sol";
import {GangPadRegistryTest} from "../gang/GangPadRegistry.t.sol";
import {MergeGuardsTest} from "../merge/MergeGuards.t.sol";
import {GangGatewayTest} from "../router/GangGateway.t.sol";
import {GangGatewayPhishingTest} from "../router/GangGatewayPhishing.t.sol";
import {GangRouterPoolTest} from "../router/GangRouterPool.t.sol";
import {GangRouterReviewPoCTest} from "../router/GangRouterReviewPoC.t.sol";

/// @notice GangLaunchpad 3.0 parity: every GangFixture suite of 2.0 re-run with the pad deployed as 3.0 (implementation
///         behind a TransparentUpgradeableProxy, `GangFixture._newPad3`). Same tests, same expectations: 3.0's first
///         rule set must behave exactly as 2.0 for creators, traders, routers, the Gateway, the Registry and every module.
contract CreatorFee3Test is CreatorFeeTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GradTarget3Test is GradTargetTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GradTargetPricing3Test is GradTargetPricingTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract OriginTrader3Test is OriginTraderTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangBond3Test is GangBondTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangBondPairTax3Test is GangBondPairTaxTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangBuybackSplitter3Test is GangBuybackSplitterTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangBuybackSplitterPairTax3Test is GangBuybackSplitterPairTaxTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangComboSplitter3Test is GangComboSplitterTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangComboSplitterPairTax3Test is GangComboSplitterPairTaxTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangLiquiditySplitter3Test is GangLiquiditySplitterTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangLiquiditySplitterPairTax3Test is GangLiquiditySplitterPairTaxTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangSplitModule3Test is GangSplitModuleTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangPadRegistry3Test is GangPadRegistryTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract MergeGuards3Test is MergeGuardsTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    /// @dev 3.0's new events, next to 2.0's own: TokenVersionSet (every create), TradeV1 (every curve trade).
    function _extraPadEvents() internal pure override returns (string[] memory s) {
        s = new string[](2);
        s[0] = "event TokenVersionSet(address indexed token, uint8 version)";
        s[1] =
            "event TradeV1(address indexed token, address indexed trader, bool isBuy, uint256 quoteAmount, uint256 tokenAmount, uint256 protocolFee, uint256 creatorFee, uint256 postPrice, uint256 realQuote, uint256 sold)";
    }
}

contract GangGateway3Test is GangGatewayTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangGatewayPhishing3Test is GangGatewayPhishingTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangRouterPool3Test is GangRouterPoolTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}

contract GangRouterReviewPoC3Test is GangRouterReviewPoCTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }
}
