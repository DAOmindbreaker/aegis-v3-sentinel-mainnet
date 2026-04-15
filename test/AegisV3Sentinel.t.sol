// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AegisV3Sentinel.sol";
import "../src/AegisV3Response.sol";

/**
 * @title  AegisV3Sentinel Tests
 * @notice Fork tests against Ethereum Mainnet state
 * @dev    Run with: forge test --fork-url https://eth.llamarpc.com -vvv
 */
contract AegisV3SentinelTest is Test {
    AegisV3Sentinel public trap;
    AegisV3Response public response;

    function setUp() public {
        trap = new AegisV3Sentinel();
        response = new AegisV3Response();
    }

    // ═══════════════════════════════════════════
    //  Constants Verification
    // ═══════════════════════════════════════════

    function test_Constants() public view {
        assertEq(trap.VAULT_HUB(), 0x1d201BE093d847f6446530Efb0E8Fb426d176709);
        assertEq(trap.STETH(), 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
        assertEq(trap.WSTETH(), 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        assertEq(trap.VAULT_SAMPLE_SIZE(), 25);
        assertEq(trap.BPS_DENOM(), 10_000);
        assertEq(trap.RATE_DROP_BPS(), 300);
        assertEq(trap.RATE_ALERT_BPS(), 100);
        assertEq(trap.EXTERNAL_RATIO_ALERT_BUFFER_BPS(), 500);
        assertEq(trap.UNHEALTHY_RATIO_BPS(), 1_200);
    }

    // ═══════════════════════════════════════════
    //  collect() Tests
    // ═══════════════════════════════════════════

    function test_Collect_ReturnsValidSnapshot() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory snap = abi.decode(data, (AegisSnapshot));

        assertTrue(snap.valid, "Snapshot should be valid");
        assertGt(snap.vaultsCount, 0, "vaultsCount should be > 0");
        assertGt(snap.wstEthRate, 0, "wstEthRate should be > 0");
        assertGt(snap.totalPooledEther, 0, "totalPooledEther should be > 0");
        assertGt(snap.totalShares, 0, "totalShares should be > 0");
    }

    function test_Collect_VaultsCountMatchesMainnet() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory snap = abi.decode(data, (AegisSnapshot));

        // Mainnet currently has 12+ vaults
        assertGe(snap.vaultsCount, 10, "Should have 10+ vaults on mainnet");
    }

    function test_Collect_ProtocolNotPaused() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory snap = abi.decode(data, (AegisSnapshot));

        assertFalse(snap.protocolPaused, "Protocol should not be paused under normal conditions");
    }

    function test_Collect_NoBadDebt() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory snap = abi.decode(data, (AegisSnapshot));

        assertEq(snap.badDebt, 0, "Should be no bad debt under normal conditions");
    }

    function test_Collect_SampleSizeCorrect() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory snap = abi.decode(data, (AegisSnapshot));

        // sampleSize = min(vaultsCount, VAULT_SAMPLE_SIZE)
        uint256 expected = snap.vaultsCount < 25 ? snap.vaultsCount : 25;
        assertEq(snap.sampleSize, expected, "sampleSize should be min(vaultsCount, 25)");
    }

    function test_Collect_ExternalRatioWithinCap() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory snap = abi.decode(data, (AegisSnapshot));

        assertGt(snap.maxExternalRatioBp, 0, "maxExternalRatioBp should be > 0");
        assertLt(snap.externalRatioBps, snap.maxExternalRatioBp, "External ratio should be within cap");
    }

    function test_Collect_AccountingDataFromStETH() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory snap = abi.decode(data, (AegisSnapshot));

        // Verify accounting functions work from stETH contract
        assertGt(snap.externalShares, 0, "externalShares should be > 0 (stVaults active)");
        assertEq(snap.maxExternalRatioBp, 3000, "maxExternalRatioBp should be 3000 (30%)");
    }

    // ═══════════════════════════════════════════
    //  shouldRespond() Tests
    // ═══════════════════════════════════════════

    function test_ShouldRespond_NormalConditions_ReturnsFalse() public {
        bytes memory data = trap.collect();
        bytes[] memory samples = new bytes[](3);
        samples[0] = data;
        samples[1] = data;
        samples[2] = data;

        (bool respond,) = trap.shouldRespond(samples);
        assertFalse(respond, "Should not respond under normal conditions");
    }

    function test_ShouldRespond_InsufficientSamples() public {
        bytes[] memory samples = new bytes[](2);
        samples[0] = trap.collect();
        samples[1] = trap.collect();

        (bool respond,) = trap.shouldRespond(samples);
        assertFalse(respond, "Should not respond with < 3 samples");
    }

    function test_ShouldRespond_InvalidSnapshot() public {
        AegisSnapshot memory invalidSnap;
        invalidSnap.valid = false;

        bytes[] memory samples = new bytes[](3);
        samples[0] = abi.encode(invalidSnap);
        samples[1] = trap.collect();
        samples[2] = trap.collect();

        (bool respond,) = trap.shouldRespond(samples);
        assertFalse(respond, "Should not respond with invalid snapshot");
    }

    function test_ShouldRespond_CheckA_BadDebt() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory current = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory mid = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory oldest = abi.decode(data, (AegisSnapshot));

        // Simulate bad debt
        current.badDebt = 100 ether;

        bytes[] memory samples = new bytes[](3);
        samples[0] = abi.encode(current);
        samples[1] = abi.encode(mid);
        samples[2] = abi.encode(oldest);

        (bool respond, bytes memory payload) = trap.shouldRespond(samples);
        assertTrue(respond, "Should respond to bad debt");

        (uint8 checkId,,,) = abi.decode(payload, (uint8, uint256, uint256, uint256));
        assertEq(checkId, 1, "Check ID should be 1 (Bad Debt)");
    }

    function test_ShouldRespond_CheckB_ProtocolPause() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory current = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory mid = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory oldest = abi.decode(data, (AegisSnapshot));

        // Simulate pause transition
        current.protocolPaused = true;
        mid.protocolPaused = false;

        bytes[] memory samples = new bytes[](3);
        samples[0] = abi.encode(current);
        samples[1] = abi.encode(mid);
        samples[2] = abi.encode(oldest);

        (bool respond, bytes memory payload) = trap.shouldRespond(samples);
        assertTrue(respond, "Should respond to protocol pause transition");

        (uint8 checkId,,,) = abi.decode(payload, (uint8, uint256, uint256, uint256));
        assertEq(checkId, 2, "Check ID should be 2 (Protocol Pause)");
    }

    function test_ShouldRespond_CheckB_AlreadyPaused_ReturnsFalse() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory current = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory mid = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory oldest = abi.decode(data, (AegisSnapshot));

        // Both paused — not a transition
        current.protocolPaused = true;
        mid.protocolPaused = true;

        bytes[] memory samples = new bytes[](3);
        samples[0] = abi.encode(current);
        samples[1] = abi.encode(mid);
        samples[2] = abi.encode(oldest);

        (bool respond,) = trap.shouldRespond(samples);
        // Check A not triggered (badDebt=0), Check B not triggered (not a transition)
        // Other checks may or may not trigger depending on simulated data
        // This test verifies Check B specifically doesn't fire for already-paused state
        if (respond) {
            (, bytes memory payload) = trap.shouldRespond(samples);
            (uint8 checkId,,,) = abi.decode(payload, (uint8, uint256, uint256, uint256));
            assertTrue(checkId != 2, "Check B should not fire when already paused");
        }
    }

    function test_ShouldRespond_CheckC_VaultDegradation() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory current = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory mid = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory oldest = abi.decode(data, (AegisSnapshot));

        // Simulate 20% unhealthy vaults (above 12% threshold)
        current.sampleSize = 10;
        current.unhealthyVaults = 3; // 30%
        mid.sampleSize = 10;
        mid.unhealthyVaults = 2; // 20%

        bytes[] memory samples = new bytes[](3);
        samples[0] = abi.encode(current);
        samples[1] = abi.encode(mid);
        samples[2] = abi.encode(oldest);

        (bool respond, bytes memory payload) = trap.shouldRespond(samples);
        assertTrue(respond, "Should respond to vault health degradation");

        (uint8 checkId,,,) = abi.decode(payload, (uint8, uint256, uint256, uint256));
        assertEq(checkId, 3, "Check ID should be 3 (Vault Health Degradation)");
    }

    function test_ShouldRespond_CheckD_RateDrop() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory current = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory mid = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory oldest = abi.decode(data, (AegisSnapshot));

        // Simulate sustained 4% rate drop
        current.wstEthRate = (oldest.wstEthRate * 96) / 100;
        mid.wstEthRate = (oldest.wstEthRate * 98) / 100;

        bytes[] memory samples = new bytes[](3);
        samples[0] = abi.encode(current);
        samples[1] = abi.encode(mid);
        samples[2] = abi.encode(oldest);

        (bool respond, bytes memory payload) = trap.shouldRespond(samples);
        assertTrue(respond, "Should respond to sustained rate drop");

        (uint8 checkId,,,) = abi.decode(payload, (uint8, uint256, uint256, uint256));
        assertEq(checkId, 4, "Check ID should be 4 (wstETH Rate Drop)");
    }

    function test_ShouldRespond_CheckE_ExternalRatioBreach() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory current = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory mid = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory oldest = abi.decode(data, (AegisSnapshot));

        // Simulate sustained external ratio breach
        current.externalRatioBps = 3500;
        current.maxExternalRatioBp = 3000;
        mid.externalRatioBps = 3200;
        mid.maxExternalRatioBp = 3000;
        oldest.externalRatioBps = 3100;
        oldest.maxExternalRatioBp = 3000;

        bytes[] memory samples = new bytes[](3);
        samples[0] = abi.encode(current);
        samples[1] = abi.encode(mid);
        samples[2] = abi.encode(oldest);

        (bool respond, bytes memory payload) = trap.shouldRespond(samples);
        assertTrue(respond, "Should respond to sustained external ratio breach");

        (uint8 checkId,,,) = abi.decode(payload, (uint8, uint256, uint256, uint256));
        assertEq(checkId, 5, "Check ID should be 5 (External Ratio Breach)");
    }

    // ═══════════════════════════════════════════
    //  shouldAlert() Tests
    // ═══════════════════════════════════════════

    function test_ShouldAlert_NormalConditions_ReturnsFalse() public {
        bytes memory data = trap.collect();
        bytes[] memory samples = new bytes[](2);
        samples[0] = data;
        samples[1] = data;

        (bool alert,) = trap.shouldAlert(samples);
        assertFalse(alert, "Should not alert under normal conditions");
    }

    function test_ShouldAlert_AlertA_UnhealthyVault() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory current = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory mid = abi.decode(data, (AegisSnapshot));

        // Simulate sustained unhealthy vault
        current.unhealthyVaults = 1;
        mid.unhealthyVaults = 1;

        bytes[] memory samples = new bytes[](2);
        samples[0] = abi.encode(current);
        samples[1] = abi.encode(mid);

        (bool alert, bytes memory payload) = trap.shouldAlert(samples);
        assertTrue(alert, "Should alert on sustained unhealthy vault");

        (uint8 alertId,,,) = abi.decode(payload, (uint8, uint256, uint256, uint256));
        assertEq(alertId, 10, "Alert ID should be 10");
    }

    function test_ShouldAlert_AlertB_RateSoftDrop() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory current = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory mid = abi.decode(data, (AegisSnapshot));

        // Simulate 1.5% rate drop
        current.wstEthRate = (mid.wstEthRate * 985) / 1000;

        bytes[] memory samples = new bytes[](2);
        samples[0] = abi.encode(current);
        samples[1] = abi.encode(mid);

        (bool alert, bytes memory payload) = trap.shouldAlert(samples);
        assertTrue(alert, "Should alert on 1.5% rate drop");

        (uint8 alertId,,,) = abi.decode(payload, (uint8, uint256, uint256, uint256));
        assertEq(alertId, 11, "Alert ID should be 11");
    }

    function test_ShouldAlert_AlertC_RatioApproachingCap() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory current = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory mid = abi.decode(data, (AegisSnapshot));

        // Simulate ratio at 2600 bps with cap at 3000 (within 500 bps buffer)
        current.externalRatioBps = 2600;
        current.maxExternalRatioBp = 3000;
        current.externalShares = 1000;

        bytes[] memory samples = new bytes[](2);
        samples[0] = abi.encode(current);
        samples[1] = abi.encode(mid);

        (bool alert, bytes memory payload) = trap.shouldAlert(samples);
        assertTrue(alert, "Should alert when ratio approaching cap");

        (uint8 alertId,,,) = abi.decode(payload, (uint8, uint256, uint256, uint256));
        assertEq(alertId, 12, "Alert ID should be 12");
    }

    function test_ShouldAlert_AlertD_PreBadDebtShortfall() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory current = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory mid = abi.decode(data, (AegisSnapshot));

        // Simulate shortfall without bad debt
        current.badDebt = 0;
        current.totalShortfallShares = 100e18;
        current.unhealthyVaults = 0;
        mid.totalShortfallShares = 50e18;
        mid.unhealthyVaults = 0;

        bytes[] memory samples = new bytes[](2);
        samples[0] = abi.encode(current);
        samples[1] = abi.encode(mid);

        (bool alert, bytes memory payload) = trap.shouldAlert(samples);
        assertTrue(alert, "Should alert on pre-bad-debt shortfall");

        (uint8 alertId,,,) = abi.decode(payload, (uint8, uint256, uint256, uint256));
        assertEq(alertId, 13, "Alert ID should be 13");
    }

    // ═══════════════════════════════════════════
    //  Response Contract Tests
    // ═══════════════════════════════════════════

    function test_Response_InitialState() public view {
        assertEq(response.totalRiskEvents(), 0);
        assertEq(response.lastRiskBlock(), 0);
        assertEq(response.lastCheckId(), 0);
        assertFalse(response.hasRecordedRisk());
    }

    function test_Response_AllCheckIds() public {
        for (uint8 i = 1; i <= 5; i++) {
            response.handleRisk(i, 100, 200, 300);
            assertEq(response.lastCheckId(), i);
        }
        assertEq(response.totalRiskEvents(), 5);
        assertTrue(response.hasRecordedRisk());
    }

    function test_Response_UnknownCheckId() public {
        response.handleRisk(99, 1, 2, 3);
        assertEq(response.totalRiskEvents(), 1);
        assertEq(response.lastCheckId(), 99);
    }

    // ═══════════════════════════════════════════
    //  Priority Tests
    // ═══════════════════════════════════════════

    function test_ShouldRespond_CheckA_HasHighestPriority() public {
        bytes memory data = trap.collect();
        AegisSnapshot memory current = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory mid = abi.decode(data, (AegisSnapshot));
        AegisSnapshot memory oldest = abi.decode(data, (AegisSnapshot));

        // Trigger Check A and Check B simultaneously
        current.badDebt = 100 ether;
        current.protocolPaused = true;
        mid.protocolPaused = false;

        bytes[] memory samples = new bytes[](3);
        samples[0] = abi.encode(current);
        samples[1] = abi.encode(mid);
        samples[2] = abi.encode(oldest);

        (bool respond, bytes memory payload) = trap.shouldRespond(samples);
        assertTrue(respond);

        (uint8 checkId,,,) = abi.decode(payload, (uint8, uint256, uint256, uint256));
        assertEq(checkId, 1, "Check A (Bad Debt) should have highest priority");
    }
}
