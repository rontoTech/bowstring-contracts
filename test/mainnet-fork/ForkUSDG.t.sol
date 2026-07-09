// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {ForkBase} from "./ForkBase.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IUSDGPermitProbe {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(address owner) external view returns (uint256);
    function PERMIT_TYPEHASH() external view returns (bytes32);
}

/// @title ForkUSDG
/// @notice Empirically settles the `depositWithPermit` question for mainnet USDG.
///         Confirms USDG is 6-dec and probes its EIP-2612 surface in try/catch,
///         LOGGING whether permit is supported. `BaseVault.depositWithPermit`
///         calls `IERC20Permit(baseAsset).permit(...)`, so this is the ground
///         truth for whether that path works against real USDG.
contract ForkUSDG is ForkBase {
    // Standard EIP-2612 typehash: keccak256(
    //   "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    bytes32 internal constant STD_PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    function setUp() public {
        _initFork();
    }

    function test_usdg_decimalsIsSix() public {
        if (_skipIfNoFork()) return;
        assertEq(IERC20Metadata(USDG).decimals(), 6, "USDG must be 6 decimals");
        console.log("USDG symbol:", IERC20Metadata(USDG).symbol());
    }

    function test_usdg_permitSupport() public {
        if (_skipIfNoFork()) return;

        bool domainOk;
        bytes32 domainSep;
        try IUSDGPermitProbe(USDG).DOMAIN_SEPARATOR() returns (bytes32 ds) {
            domainSep = ds;
            domainOk = ds != bytes32(0);
        } catch {
            domainOk = false;
        }

        bool noncesOk;
        try IUSDGPermitProbe(USDG).nonces(address(0xdEaD)) returns (uint256) {
            noncesOk = true;
        } catch {
            noncesOk = false;
        }

        bool typehashOk;
        bytes32 typehash;
        try IUSDGPermitProbe(USDG).PERMIT_TYPEHASH() returns (bytes32 th) {
            typehash = th;
            typehashOk = true;
        } catch {
            typehashOk = false;
        }

        bool permitSupported = domainOk && noncesOk;

        console.log("=== USDG EIP-2612 probe ===");
        console.log("  DOMAIN_SEPARATOR() present:", domainOk);
        console.logBytes32(domainSep);
        console.log("  nonces(address) present:  ", noncesOk);
        console.log("  PERMIT_TYPEHASH() present: ", typehashOk);
        console.logBytes32(typehash);
        console.log("  => EIP-2612 permit supported:", permitSupported);

        // depositWithPermit depends on this being true. Assert so a future USDG
        // change that drops permit is caught loudly rather than silently breaking
        // the permit deposit path.
        assertTrue(permitSupported, "USDG must support EIP-2612 for depositWithPermit");
        if (typehashOk) {
            assertEq(typehash, STD_PERMIT_TYPEHASH, "USDG uses non-standard permit typehash");
        }
    }
}
