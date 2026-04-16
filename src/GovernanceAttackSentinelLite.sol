// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";
import {VelocityEngine} from "./lib/VelocityEngine.sol";
import {RiskScorer} from "./lib/RiskScorer.sol";

/**
 * @title  Governance Attack Sentinel — Lite
 * @author DAOmindbreaker
 * @notice Lightweight Drosera Trap for governance manipulation detection.
 *         Optimized for free-tier RPC providers with minimal external calls.
 *
 * @dev    Lite version reduces collect() from ~10 RPC calls to 4:
 *         1. votesLength()
 *         2. getVote(latest)
 *         3. balanceOf(ARAGON_AGENT) for LDO
 *         4. totalSupply()
 *
 *         Removed: active vote loop (5 calls), Agent.balance() fallback,
 *         ETH balance check
 *
 *         Signal Matrix (6 signals):
 *           G1 (w:2000) Vote count spike
 *           G2 (w:1500) Treasury LDO change
 *           G3 (w:2500) Voting power concentration
 *           G4 (w:1800) Rapid yea growth
 *           G6 (w:2000) LDO supply anomaly
 *           G7 (w:1500) Rapid vote execution
 *
 * Contracts monitored (Lido DAO on Ethereum Mainnet):
 *   LDO Token      : 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32
 *   Aragon Voting  : 0x2e59A20f205bB85a89C53f1936454680651E618e
 *   Aragon Agent   : 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c
 */

// ─────────────────────────────────────────────
//  External interfaces
// ─────────────────────────────────────────────

interface ILDO {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IAragonVoting {
    function votesLength() external view returns (uint256);
    function getVote(uint256 voteId) external view returns (
        bool open,
        bool executed,
        uint64 startDate,
        uint64 snapshotBlock,
        uint64 supportRequired,
        uint64 minAcceptQuorum,
        uint256 yea,
        uint256 nay,
        uint256 votingPower,
        bytes memory script
    );
}

// ─────────────────────────────────────────────
//  Data structures
// ─────────────────────────────────────────────

/// @notice Lightweight governance snapshot (4 RPC calls only)
struct GovSnapshotLite {
    // ── Voting State ────────────────────────
    uint256 totalVotes;
    bool    latestVoteOpen;
    bool    latestVoteExecuted;
    uint256 latestVoteYea;
    uint256 latestVoteNay;
    uint256 latestVotePower;
    uint256 latestVoteConcentration;

    // ── Treasury State ──────────────────────
    uint256 treasuryLDO;

    // ── Token State ─────────────────────────
    uint256 ldoTotalSupply;

    // ── Metadata ────────────────────────────
    bool    valid;
}

// ─────────────────────────────────────────────
//  Trap contract
// ─────────────────────────────────────────────

contract GovernanceAttackSentinel is ITrap {

    // ── Contract Addresses (Mainnet) ────────

    address public constant LDO_TOKEN      = 0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32;
    address public constant ARAGON_VOTING  = 0x2e59A20f205bB85a89C53f1936454680651E618e;
    address public constant ARAGON_AGENT   = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;

    // ── Constants ───────────────────────────
    uint256 public constant BPS_DENOM = 10_000;

    // ── Signal Weights ──────────────────────
    uint256 public constant W1 = 2000;   // Vote count spike
    uint256 public constant W2 = 1500;   // Treasury LDO change
    uint256 public constant W3 = 2500;   // Voting power concentration
    uint256 public constant W4 = 1800;   // Rapid yea growth
    uint256 public constant W6 = 2000;   // LDO supply anomaly
    uint256 public constant W7 = 1500;   // Rapid vote execution

    // ── Thresholds ──────────────────────────
    uint256 public constant G2_TREASURY_CHANGE_BPS = 500;
    uint256 public constant G3_CONCENTRATION_BPS   = 5000;
    uint256 public constant G6_SUPPLY_CHANGE_BPS   = 100;

    // ── collect() ────────────────────────────

    /**
     * @notice Collects governance state with only 4 RPC calls.
     * @dev    1. votesLength()  2. getVote(latest)  3. balanceOf()  4. totalSupply()
     */
    function collect() external view returns (bytes memory) {
        GovSnapshotLite memory snap;

        // ── Call 1: Total votes count ───────
        try IAragonVoting(ARAGON_VOTING).votesLength() returns (uint256 total) {
            snap.totalVotes = total;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        if (snap.totalVotes == 0) {
            snap.valid = true;
            return abi.encode(snap);
        }

        // ── Call 2: Latest vote details ─────
        uint256 latestId = snap.totalVotes - 1;
        try IAragonVoting(ARAGON_VOTING).getVote(latestId) returns (
            bool open, bool executed, uint64, uint64, uint64, uint64,
            uint256 yea, uint256 nay, uint256 votingPower, bytes memory
        ) {
            snap.latestVoteOpen = open;
            snap.latestVoteExecuted = executed;
            snap.latestVoteYea = yea;
            snap.latestVoteNay = nay;
            snap.latestVotePower = votingPower;

            if (votingPower > 0) {
                uint256 dominant = yea > nay ? yea : nay;
                snap.latestVoteConcentration = (dominant * BPS_DENOM) / votingPower;
            }
        } catch {
            // Non-critical
        }

        // ── Call 3: Treasury LDO balance ────
        try ILDO(LDO_TOKEN).balanceOf(ARAGON_AGENT) returns (uint256 ldoBal) {
            snap.treasuryLDO = ldoBal;
        } catch {
            // Non-critical
        }

        // ── Call 4: LDO total supply ────────
        try ILDO(LDO_TOKEN).totalSupply() returns (uint256 supply) {
            snap.ldoTotalSupply = supply;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        snap.valid = true;
        return abi.encode(snap);
    }

    // ── shouldRespond() ──────────────────────

    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length < 3) return (false, bytes(""));

        GovSnapshotLite memory current = abi.decode(data[0], (GovSnapshotLite));
        GovSnapshotLite memory mid     = abi.decode(data[1], (GovSnapshotLite));
        GovSnapshotLite memory oldest  = abi.decode(data[2], (GovSnapshotLite));

        if (!current.valid || !mid.valid || !oldest.valid) {
            return (false, bytes(""));
        }

        VelocityEngine.Velocity memory voteCountV = VelocityEngine.calculateIncreasing(
            current.totalVotes, mid.totalVotes, oldest.totalVotes
        );

        uint256[16] memory signals;

        // G1: Vote count spike (2+ new proposals in sample window)
        if (voteCountV.declining && current.totalVotes > oldest.totalVotes) {
            uint256 newVotes = current.totalVotes - oldest.totalVotes;
            if (newVotes >= 2) {
                signals[0] = W1;
                if (voteCountV.accelerating) {
                    signals[0] = (signals[0] * 150) / 100;
                }
            }
        }

        // G2: Treasury LDO change (> 5%)
        if (oldest.treasuryLDO > 0 && current.treasuryLDO < oldest.treasuryLDO) {
            uint256 treasuryChangeBps = ((oldest.treasuryLDO - current.treasuryLDO) * BPS_DENOM)
                / oldest.treasuryLDO;
            signals[1] = RiskScorer.scoreThreshold(
                treasuryChangeBps, G2_TREASURY_CHANGE_BPS, W2, true
            );
        }

        // G3: Voting power concentration on open vote (> 50%)
        if (current.latestVoteOpen && current.latestVotePower > 0) {
            signals[2] = RiskScorer.scoreThreshold(
                current.latestVoteConcentration, G3_CONCENTRATION_BPS, W3, false
            );
        }

        // G4: Rapid yea growth (> 20% between samples)
        if (current.latestVoteOpen && mid.latestVoteOpen) {
            if (current.latestVoteYea > mid.latestVoteYea && mid.latestVoteYea > 0) {
                uint256 yeaGrowthBps = ((current.latestVoteYea - mid.latestVoteYea) * BPS_DENOM)
                    / mid.latestVoteYea;
                if (yeaGrowthBps > 2000) {
                    signals[3] = W4;
                }
            }
        }

        // G6: LDO supply anomaly (> 1% change)
        if (oldest.ldoTotalSupply > 0) {
            uint256 supplyChangeBps = VelocityEngine.divergence(
                current.ldoTotalSupply, oldest.ldoTotalSupply
            );
            signals[4] = RiskScorer.scoreThreshold(
                supplyChangeBps, G6_SUPPLY_CHANGE_BPS, W6, true
            );
        }

        // G7: Rapid vote execution
        if (current.latestVoteExecuted && !oldest.latestVoteExecuted) {
            if (current.totalVotes > oldest.totalVotes) {
                signals[5] = W7;
            }
        }

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 6);

        if (risk.riskLevel >= RiskScorer.RISK_HIGH) {
            return (true, RiskScorer.encodePayload(risk));
        }

        return (false, bytes(""));
    }

    // ── shouldAlert() ─────────────────────────

    function shouldAlert(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length < 2) return (false, bytes(""));

        GovSnapshotLite memory current = abi.decode(data[0], (GovSnapshotLite));
        GovSnapshotLite memory mid     = abi.decode(data[1], (GovSnapshotLite));

        if (!current.valid || !mid.valid) return (false, bytes(""));

        uint256[16] memory signals;

        // G1: New proposal created
        if (current.totalVotes > mid.totalVotes) {
            signals[0] = W1;
        }

        // G2: Treasury LDO drop > 2%
        if (mid.treasuryLDO > 0 && current.treasuryLDO < mid.treasuryLDO) {
            uint256 dropBps = ((mid.treasuryLDO - current.treasuryLDO) * BPS_DENOM)
                / mid.treasuryLDO;
            if (dropBps >= 200) {
                signals[1] = W2;
            }
        }

        // G3: High concentration on open vote
        if (current.latestVoteOpen && current.latestVoteConcentration >= G3_CONCENTRATION_BPS) {
            signals[2] = W3;
        }

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 6);

        if (risk.riskLevel >= RiskScorer.RISK_MED) {
            return (true, RiskScorer.encodePayload(risk));
        }

        return (false, bytes(""));
    }
}
