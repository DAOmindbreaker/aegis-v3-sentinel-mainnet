// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/lib/VelocityEngine.sol";
import "../src/lib/RiskScorer.sol";

/**
 * @title  VelocityEngine & RiskScorer Tests
 * @notice Unit tests for next-gen trap foundation libraries
 * @dev    Run with: forge test -vvv
 */

// ═══════════════════════════════════════════════
//  VelocityEngine Tests
// ═══════════════════════════════════════════════

contract VelocityEngineTest is Test {

    // ── calculate() — Declining Values ──────

    function test_Velocity_SteadyDecline() public pure {
        // 100 → 95 → 90 (steady 5% decline per interval)
        VelocityEngine.Velocity memory v = VelocityEngine.calculate(90, 95, 100);

        assertTrue(v.declining, "Should be declining");
        assertTrue(v.sustained, "Should be sustained");
        assertTrue(v.accelerating, "Relative decline is slightly accelerating due to shrinking base");
        assertEq(v.magnitudeBps, 1000, "Total decline should be 10% = 1000 bps");
    }

    function test_Velocity_AcceleratingDecline() public pure {
        // 100 → 98 → 93 (2% then 5% — accelerating)
        VelocityEngine.Velocity memory v = VelocityEngine.calculate(93, 98, 100);

        assertTrue(v.declining);
        assertTrue(v.sustained);
        assertTrue(v.accelerating, "Should detect acceleration");
        assertEq(v.magnitudeBps, 700, "Total decline = 7%");
        assertGt(v.recentBps, v.earlierBps, "Recent drop should be bigger");
    }

    function test_Velocity_DeceleratingDecline() public pure {
        // 100 → 93 → 91 (7% then ~2% — decelerating)
        VelocityEngine.Velocity memory v = VelocityEngine.calculate(91, 93, 100);

        assertTrue(v.declining);
        assertTrue(v.sustained);
        assertFalse(v.accelerating, "Should not be accelerating (decelerating)");
    }

    function test_Velocity_SingleIntervalDecline() public pure {
        // 100 → 102 → 95 (up then down — not sustained)
        VelocityEngine.Velocity memory v = VelocityEngine.calculate(95, 102, 100);

        assertTrue(v.declining, "Overall declining");
        assertFalse(v.sustained, "Not sustained - mid was higher");
        assertFalse(v.accelerating);
    }

    // ── calculate() — Stable/Increasing ─────

    function test_Velocity_Stable() public pure {
        VelocityEngine.Velocity memory v = VelocityEngine.calculate(100, 100, 100);

        assertFalse(v.declining);
        assertFalse(v.sustained);
        assertFalse(v.accelerating);
        assertEq(v.magnitudeBps, 0);
    }

    function test_Velocity_Increasing() public pure {
        // 100 → 105 → 110 (increasing)
        VelocityEngine.Velocity memory v = VelocityEngine.calculate(110, 105, 100);

        assertFalse(v.declining, "Should not be declining");
        assertEq(v.magnitudeBps, 1000, "10% increase");
    }

    // ── calculate() — Edge Cases ────────────

    function test_Velocity_ZeroOldest() public pure {
        VelocityEngine.Velocity memory v = VelocityEngine.calculate(100, 50, 0);

        assertFalse(v.declining);
        assertEq(v.magnitudeBps, 0, "Should return 0 for zero oldest");
    }

    function test_Velocity_AllZero() public pure {
        VelocityEngine.Velocity memory v = VelocityEngine.calculate(0, 0, 0);

        assertEq(v.magnitudeBps, 0);
        assertFalse(v.declining);
    }

    function test_Velocity_LargeValues() public pure {
        // Lido-scale: ~9.4M ETH
        uint256 oldest  = 9_400_000 ether;
        uint256 mid     = 9_350_000 ether;
        uint256 current = 9_280_000 ether;

        VelocityEngine.Velocity memory v = VelocityEngine.calculate(current, mid, oldest);

        assertTrue(v.declining);
        assertTrue(v.sustained);
        assertTrue(v.accelerating);
        // Total drop: 120K / 9.4M ≈ 1.27%
        assertGt(v.magnitudeBps, 100, "Should be > 1%");
        assertLt(v.magnitudeBps, 200, "Should be < 2%");
    }

    // ── calculateIncreasing() ───────────────

    function test_VelocityIncreasing_Rising() public pure {
        // Unhealthy vaults: 0 → 1 → 3 (increasing concern)
        VelocityEngine.Velocity memory v = VelocityEngine.calculateIncreasing(3, 1, 0);

        assertTrue(v.declining, "declining=true means concerning increase");
        assertTrue(v.sustained);
        assertTrue(v.accelerating, "2 new > 1 new = accelerating");
    }

    function test_VelocityIncreasing_Stable() public pure {
        VelocityEngine.Velocity memory v = VelocityEngine.calculateIncreasing(2, 2, 2);

        assertFalse(v.declining);
        assertEq(v.magnitudeBps, 0);
    }

    function test_VelocityIncreasing_Decreasing() public pure {
        // Unhealthy vaults: 5 → 3 → 1 (improving — not concerning)
        VelocityEngine.Velocity memory v = VelocityEngine.calculateIncreasing(1, 3, 5);

        assertFalse(v.declining, "Should not be concerning when improving");
    }

    // ── crossedThreshold() ──────────────────

    function test_CrossedThreshold_Upward() public pure {
        (bool crossed, bool direction) = VelocityEngine.crossedThreshold(150, 90, 100);

        assertTrue(crossed, "Should detect crossing");
        assertTrue(direction, "Should be upward crossing");
    }

    function test_CrossedThreshold_Downward() public pure {
        (bool crossed, bool direction) = VelocityEngine.crossedThreshold(90, 150, 100);

        assertTrue(crossed);
        assertFalse(direction, "Should be downward crossing");
    }

    function test_CrossedThreshold_NoCrossing() public pure {
        (bool crossed,) = VelocityEngine.crossedThreshold(110, 120, 100);

        assertFalse(crossed, "Both above threshold - no crossing");
    }

    // ── divergence() ────────────────────────

    function test_Divergence_Zero() public pure {
        uint256 div = VelocityEngine.divergence(1000, 1000);
        assertEq(div, 0, "Same values = 0 divergence");
    }

    function test_Divergence_1Percent() public pure {
        uint256 div = VelocityEngine.divergence(1010, 1000);
        assertEq(div, 100, "1% divergence = 100 bps");
    }

    function test_Divergence_Symmetric() public pure {
        uint256 div1 = VelocityEngine.divergence(1050, 1000);
        uint256 div2 = VelocityEngine.divergence(1000, 1050);
        // Both should be ~50 bps (slight difference due to different base)
        assertGt(div1, 0);
        assertGt(div2, 0);
    }

    function test_Divergence_ZeroBase() public pure {
        uint256 div = VelocityEngine.divergence(100, 0);
        assertEq(div, 0, "Zero base should return 0");
    }
}

// ═══════════════════════════════════════════════
//  RiskScorer Tests
// ═══════════════════════════════════════════════

contract RiskScorerTest is Test {

    // ── evaluate() ──────────────────────────

    function test_Evaluate_NoSignals() public pure {
        uint256[16] memory signals;
        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 10);

        assertEq(risk.totalScore, 0);
        assertEq(risk.riskLevel, 0, "Should be NONE");
        assertEq(risk.activeSignals, 0);
    }

    function test_Evaluate_SingleSignal_Low() public pure {
        uint256[16] memory signals;
        signals[0] = 1000; // below LOW threshold

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 10);

        assertEq(risk.totalScore, 1000);
        assertEq(risk.riskLevel, 1, "Should be LOW");
        assertEq(risk.activeSignals, 1);
        assertEq(risk.topSignalId, 1);
    }

    function test_Evaluate_MultiSignal_Medium() public pure {
        uint256[16] memory signals;
        signals[0] = 1500;
        signals[2] = 1800;

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 10);

        assertEq(risk.totalScore, 3300);
        assertEq(risk.riskLevel, 2, "Should be MED");
        assertEq(risk.activeSignals, 2);
        assertEq(risk.topSignalId, 3, "Signal 3 (index 2) should be top");
        assertEq(risk.topSignalScore, 1800);
    }

    function test_Evaluate_MultiSignal_High() public pure {
        uint256[16] memory signals;
        signals[0] = 2000;
        signals[1] = 1500;
        signals[3] = 1800;
        signals[5] = 1200;

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 10);

        assertEq(risk.totalScore, 6500);
        assertEq(risk.riskLevel, 3, "Should be HIGH");
        assertEq(risk.activeSignals, 4);
    }

    function test_Evaluate_ExactThreshold_Med() public pure {
        uint256[16] memory signals;
        signals[0] = 3000; // exactly LOW_THRESHOLD

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 10);

        assertEq(risk.riskLevel, 2, "Exact LOW_THRESHOLD should be MED");
    }

    function test_Evaluate_ExactThreshold_High() public pure {
        uint256[16] memory signals;
        signals[0] = 6000; // exactly HIGH_THRESHOLD

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 10);

        assertEq(risk.riskLevel, 3, "Exact HIGH_THRESHOLD should be HIGH");
    }

    // ── scoreVelocity() ─────────────────────

    function test_ScoreVelocity_BelowThreshold() public pure {
        uint256 score = RiskScorer.scoreVelocity(50, 100, 1000, false, false);
        assertEq(score, 0, "Below threshold should score 0");
    }

    function test_ScoreVelocity_AboveThreshold_Base() public pure {
        uint256 score = RiskScorer.scoreVelocity(150, 100, 1000, false, false);
        assertEq(score, 1000, "Should return base weight");
    }

    function test_ScoreVelocity_Sustained() public pure {
        uint256 score = RiskScorer.scoreVelocity(150, 100, 1000, true, false);
        assertEq(score, 1500, "Sustained should add 50%");
    }

    function test_ScoreVelocity_Accelerating() public pure {
        uint256 score = RiskScorer.scoreVelocity(150, 100, 1000, false, true);
        assertEq(score, 1300, "Accelerating should add 30%");
    }

    function test_ScoreVelocity_SustainedAndAccelerating() public pure {
        uint256 score = RiskScorer.scoreVelocity(150, 100, 1000, true, true);
        // base 1000 * 1.5 = 1500 * 1.3 = 1950
        assertEq(score, 1950, "Both bonuses should stack");
    }

    // ── scoreThreshold() ────────────────────

    function test_ScoreThreshold_Below() public pure {
        uint256 score = RiskScorer.scoreThreshold(50, 100, 2000, false);
        assertEq(score, 0);
    }

    function test_ScoreThreshold_Above_NoScale() public pure {
        uint256 score = RiskScorer.scoreThreshold(150, 100, 2000, false);
        assertEq(score, 2000, "Should return base weight");
    }

    function test_ScoreThreshold_Above_Scaled() public pure {
        uint256 score = RiskScorer.scoreThreshold(200, 100, 1000, true);
        // ratio = 200 * 100 / 100 = 200, score = 1000 * 200 / 100 = 2000
        assertEq(score, 2000, "2x threshold should give 2x score");
    }

    function test_ScoreThreshold_Scaled_Capped() public pure {
        uint256 score = RiskScorer.scoreThreshold(500, 100, 1000, true);
        // ratio = 500 * 100 / 100 = 500, capped at 300
        // score = 1000 * 300 / 100 = 3000
        assertEq(score, 3000, "Should cap at 3x");
    }

    // ── scoreTransition() ───────────────────

    function test_ScoreTransition_Changed() public pure {
        uint256 score = RiskScorer.scoreTransition(true, false, 1500);
        assertEq(score, 1500);
    }

    function test_ScoreTransition_NoChange() public pure {
        uint256 score = RiskScorer.scoreTransition(true, true, 1500);
        assertEq(score, 0);
    }

    // ── scoreProximity() ────────────────────

    function test_ScoreProximity_FarFromCap() public pure {
        uint256 score = RiskScorer.scoreProximity(1000, 3000, 500, 1000);
        assertEq(score, 0, "1000/3000 is far from cap");
    }

    function test_ScoreProximity_WithinBuffer() public pure {
        // cap=3000, buffer=5% of 3000=150, value=2900 (within 100 of cap)
        uint256 score = RiskScorer.scoreProximity(2900, 3000, 500, 1000);
        assertGt(score, 0, "Should score when within buffer");
    }

    function test_ScoreProximity_AtCap() public pure {
        uint256 score = RiskScorer.scoreProximity(3000, 3000, 500, 1000);
        assertEq(score, 1000, "At cap should return full weight");
    }

    function test_ScoreProximity_AboveCap() public pure {
        uint256 score = RiskScorer.scoreProximity(3500, 3000, 500, 1000);
        assertEq(score, 1000, "Above cap should return full weight");
    }

    function test_ScoreProximity_ZeroCap() public pure {
        uint256 score = RiskScorer.scoreProximity(100, 0, 500, 1000);
        assertEq(score, 0, "Zero cap should return 0");
    }

    // ── applyMultiplier() ───────────────────

    function test_ApplyMultiplier_Normal() public pure {
        uint256 adjusted = RiskScorer.applyMultiplier(1000, 10000);
        assertEq(adjusted, 1000, "1x multiplier = no change");
    }

    function test_ApplyMultiplier_Half() public pure {
        uint256 adjusted = RiskScorer.applyMultiplier(1000, 5000);
        assertEq(adjusted, 500, "0.5x multiplier");
    }

    function test_ApplyMultiplier_OneAndHalf() public pure {
        uint256 adjusted = RiskScorer.applyMultiplier(1000, 15000);
        assertEq(adjusted, 1500, "1.5x multiplier");
    }

    // ── encodePayload() ─────────────────────

    function test_EncodePayload() public pure {
        RiskScorer.RiskScore memory risk;
        risk.riskLevel = 3;
        risk.totalScore = 7500;
        risk.topSignalId = 5;
        risk.activeSignals = 4;

        bytes memory payload = RiskScorer.encodePayload(risk);

        (uint8 level, uint256 total, uint256 topId, uint256 active) =
            abi.decode(payload, (uint8, uint256, uint256, uint256));

        assertEq(level, 3);
        assertEq(total, 7500);
        assertEq(topId, 5);
        assertEq(active, 4);
    }

    // ── Integration: Full Scoring Pipeline ──

    function test_FullPipeline_SlowDrainAttack() public pure {
        // Simulate a slow drain attack detection
        uint256[16] memory signals;

        // S1: Pool velocity declining 150 bps, sustained, accelerating
        signals[0] = RiskScorer.scoreVelocity(150, 100, 1500, true, true);

        // S5: Rate consistency breach
        signals[4] = RiskScorer.scoreThreshold(75, 50, 2000, false);

        // S9: No pause transition
        signals[8] = RiskScorer.scoreTransition(false, false, 1500);

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 10);

        // S1: 1500 * 1.5 * 1.3 = 2925
        // S5: 2000
        // Total: 4925 → MED
        assertEq(risk.riskLevel, 2, "Slow drain should be MED risk");
        assertEq(risk.activeSignals, 2);
    }

    function test_FullPipeline_CriticalAttack() public pure {
        uint256[16] memory signals;

        // Multiple high-severity signals
        signals[0] = RiskScorer.scoreVelocity(400, 100, 2000, true, true);  // 3900
        signals[1] = RiskScorer.scoreThreshold(100, 50, 2500, false);       // 2500
        signals[4] = RiskScorer.scoreTransition(true, false, 1500);         // 1500

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 10);

        // 3900 + 2500 + 1500 = 7900 → HIGH
        assertEq(risk.riskLevel, 3, "Critical attack should be HIGH");
        assertGe(risk.totalScore, 6000);
    }
}
