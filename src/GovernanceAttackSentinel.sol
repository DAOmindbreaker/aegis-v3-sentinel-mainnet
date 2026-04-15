// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";
import {VelocityEngine} from "./lib/VelocityEngine.sol";
import {RiskScorer} from "./lib/RiskScorer.sol";

/**
 * @title  Governance Attack Sentinel
 * @author DAOmindbreaker
 * @notice Drosera Trap that detects governance manipulation, hostile takeover
 *         attempts, and abnormal voting patterns in the Lido DAO through
 *         on-chain behavioral analysis.
 *
 * @dev    This trap monitors non-smart-contract exploit vectors using only
 *         on-chain signals. Governance attacks are multi-block by nature:
 *         accumulate tokens -> create/influence proposal -> vote -> execute.
 *
 *         Signal Matrix (8 signals):
 *           G1 (w:2000) Vote count spike — new proposals created rapidly
 *           G2 (w:1500) Treasury LDO change — large LDO movement from treasury
 *           G3 (w:2500) Voting power concentration — single address dominance
 *           G4 (w:1800) Active vote + power shift — proposal with unusual power
 *           G5 (w:1200) Treasury ETH drain — ETH leaving DAO agent
 *           G6 (w:2000) LDO supply anomaly — unexpected supply changes
 *           G7 (w:1500) Rapid vote execution — votes executed unusually fast
 *           G8 (w:1000) Multi-proposal coordination — many proposals at once
 *
 *         Risk Levels -> Drosera mapping:
 *           HIGH (>= 6000) -> shouldRespond = true
 *           MED  (>= 3000) -> shouldAlert = true
 *           LOW  (> 0)     -> no action
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

interface IAragonAgent {
    function balance(address token) external view returns (uint256);
}

// ─────────────────────────────────────────────
//  Data structures
// ─────────────────────────────────────────────

/// @notice Governance state snapshot
struct GovSnapshot {
    // ── Voting State ────────────────────────
    uint256 totalVotes;              // Total proposals ever created
    uint256 activeVoteCount;         // Number of currently open votes
    bool    latestVoteOpen;          // Is the newest vote still open
    bool    latestVoteExecuted;      // Was the newest vote executed
    uint256 latestVoteYea;           // Yea votes on latest proposal
    uint256 latestVoteNay;           // Nay votes on latest proposal
    uint256 latestVotePower;         // Total voting power on latest
    uint256 latestVoteConcentration; // Largest single-side % (yea or nay / total power)

    // ── Treasury State ──────────────────────
    uint256 treasuryLDO;             // LDO held by Aragon Agent
    uint256 treasuryETH;             // ETH held by Aragon Agent

    // ── Token State ─────────────────────────
    uint256 ldoTotalSupply;          // LDO total supply

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
    uint256 public constant W4 = 1800;   // Active vote + power shift
    uint256 public constant W5 = 1200;   // Treasury ETH drain
    uint256 public constant W6 = 2000;   // LDO supply anomaly
    uint256 public constant W7 = 1500;   // Rapid vote execution
    uint256 public constant W8 = 1000;   // Multi-proposal coordination

    // ── Signal Thresholds ───────────────────
    uint256 public constant G2_TREASURY_CHANGE_BPS = 500;    // 5% treasury LDO change
    uint256 public constant G3_CONCENTRATION_BPS   = 5000;   // 50% voting power concentration
    uint256 public constant G5_ETH_DRAIN_BPS       = 1000;   // 10% ETH drain
    uint256 public constant G6_SUPPLY_CHANGE_BPS   = 100;    // 1% supply change
    uint256 public constant G8_MULTI_PROPOSAL      = 3;      // 3+ active proposals

    // ── How many recent votes to check for active status
    uint256 public constant RECENT_VOTES_CHECK = 5;

    // ── collect() ────────────────────────────

    /**
     * @notice Collects governance state from Lido DAO contracts.
     * @dev    Checks latest vote details, treasury balances, and token supply.
     *         Counts active (open) votes among the most recent proposals.
     */
    function collect() external view returns (bytes memory) {
        GovSnapshot memory snap;

        // ── Total votes count ───────────────
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

        // ── Latest vote details ─────────────
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

            // Voting power concentration: max(yea, nay) / votingPower
            if (votingPower > 0) {
                uint256 dominant = yea > nay ? yea : nay;
                snap.latestVoteConcentration = (dominant * BPS_DENOM) / votingPower;
            }
        } catch {
            // Non-critical: continue without vote details
        }

        // ── Count active (open) votes among recent ──
        uint256 checkFrom = snap.totalVotes > RECENT_VOTES_CHECK
            ? snap.totalVotes - RECENT_VOTES_CHECK
            : 0;

        for (uint256 i = checkFrom; i < snap.totalVotes; ) {
            try IAragonVoting(ARAGON_VOTING).getVote(i) returns (
                bool open, bool, uint64, uint64, uint64, uint64,
                uint256, uint256, uint256, bytes memory
            ) {
                if (open) {
                    unchecked { ++snap.activeVoteCount; }
                }
            } catch {
                // Skip
            }
            unchecked { ++i; }
        }

        // ── Treasury LDO balance ────────────
        try IAragonAgent(ARAGON_AGENT).balance(LDO_TOKEN) returns (uint256 ldoBal) {
            snap.treasuryLDO = ldoBal;
        } catch {
            // Try direct balanceOf as fallback
            try ILDO(LDO_TOKEN).balanceOf(ARAGON_AGENT) returns (uint256 ldoBal2) {
                snap.treasuryLDO = ldoBal2;
            } catch {
                // Non-critical
            }
        }

        // ── Treasury ETH balance ────────────
        snap.treasuryETH = ARAGON_AGENT.balance;

        // ── LDO total supply ────────────────
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

    /**
     * @notice Evaluates 3 consecutive governance snapshots for attack patterns.
     * @dev    Detects:
     *         - Rapid proposal creation (flash governance setup)
     *         - Treasury drain (LDO or ETH leaving DAO agent)
     *         - Voting power concentration (single entity dominance)
     *         - Supply manipulation (unexpected minting/burning)
     *         - Multi-proposal coordination (flooding governance)
     */
    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length < 3) return (false, bytes(""));

        GovSnapshot memory current = abi.decode(data[0], (GovSnapshot));
        GovSnapshot memory mid     = abi.decode(data[1], (GovSnapshot));
        GovSnapshot memory oldest  = abi.decode(data[2], (GovSnapshot));

        if (!current.valid || !mid.valid || !oldest.valid) {
            return (false, bytes(""));
        }

        // ── Calculate velocities ────────────
        VelocityEngine.Velocity memory voteCountV = VelocityEngine.calculateIncreasing(
            current.totalVotes, mid.totalVotes, oldest.totalVotes
        );

        uint256[16] memory signals;

        // G1: Vote count spike (new proposals created rapidly)
        if (voteCountV.declining && current.totalVotes > oldest.totalVotes) {
            uint256 newVotes = current.totalVotes - oldest.totalVotes;
            if (newVotes >= 2) {
                signals[0] = W1;
                if (voteCountV.accelerating) {
                    signals[0] = (signals[0] * 150) / 100;
                }
            }
        }

        // G2: Treasury LDO change (large movement)
        if (oldest.treasuryLDO > 0) {
            uint256 treasuryChangeBps;
            if (current.treasuryLDO < oldest.treasuryLDO) {
                treasuryChangeBps = ((oldest.treasuryLDO - current.treasuryLDO) * BPS_DENOM)
                    / oldest.treasuryLDO;
            }
            signals[1] = RiskScorer.scoreThreshold(
                treasuryChangeBps, G2_TREASURY_CHANGE_BPS, W2, true
            );
        }

        // G3: Voting power concentration on latest vote
        if (current.latestVoteOpen && current.latestVotePower > 0) {
            signals[2] = RiskScorer.scoreThreshold(
                current.latestVoteConcentration, G3_CONCENTRATION_BPS, W3, false
            );
        }

        // G4: Active vote + power shift (proposal with unusual dynamics)
        if (current.latestVoteOpen && mid.latestVoteOpen) {
            // Vote power grew significantly between samples
            if (current.latestVoteYea > mid.latestVoteYea && mid.latestVoteYea > 0) {
                uint256 yeaGrowthBps = ((current.latestVoteYea - mid.latestVoteYea) * BPS_DENOM)
                    / mid.latestVoteYea;
                if (yeaGrowthBps > 2000) {
                    signals[3] = W4; // 20%+ yea growth in one interval
                }
            }
        }

        // G5: Treasury ETH drain
        if (oldest.treasuryETH > 0) {
            uint256 ethDrainBps;
            if (current.treasuryETH < oldest.treasuryETH) {
                ethDrainBps = ((oldest.treasuryETH - current.treasuryETH) * BPS_DENOM)
                    / oldest.treasuryETH;
            }
            signals[4] = RiskScorer.scoreThreshold(
                ethDrainBps, G5_ETH_DRAIN_BPS, W5, true
            );
        }

        // G6: LDO supply anomaly (unexpected changes)
        if (oldest.ldoTotalSupply > 0) {
            uint256 supplyChangeBps = VelocityEngine.divergence(
                current.ldoTotalSupply, oldest.ldoTotalSupply
            );
            signals[5] = RiskScorer.scoreThreshold(
                supplyChangeBps, G6_SUPPLY_CHANGE_BPS, W6, true
            );
        }

        // G7: Rapid vote execution (vote created and executed within sample window)
        if (current.latestVoteExecuted && !oldest.latestVoteExecuted) {
            // Vote was executed between oldest and current sample
            if (current.totalVotes > oldest.totalVotes) {
                // New vote created AND executed in same window
                signals[6] = W7;
            }
        }

        // G8: Multi-proposal coordination (many active proposals)
        if (current.activeVoteCount >= G8_MULTI_PROPOSAL) {
            signals[7] = RiskScorer.scoreThreshold(
                current.activeVoteCount, G8_MULTI_PROPOSAL, W8, true
            );
        }

        // ── Evaluate risk ───────────────────
        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 8);

        if (risk.riskLevel >= RiskScorer.RISK_HIGH) {
            return (true, RiskScorer.encodePayload(risk));
        }

        return (false, bytes(""));
    }

    // ── shouldAlert() ─────────────────────────

    /**
     * @notice Early warning for governance anomalies.
     * @dev    Uses 2 snapshots for faster detection.
     */
    function shouldAlert(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length < 2) return (false, bytes(""));

        GovSnapshot memory current = abi.decode(data[0], (GovSnapshot));
        GovSnapshot memory mid     = abi.decode(data[1], (GovSnapshot));

        if (!current.valid || !mid.valid) return (false, bytes(""));

        uint256[16] memory signals;

        // G1: New proposal created
        if (current.totalVotes > mid.totalVotes) {
            signals[0] = W1;
        }

        // G2: Treasury LDO drop
        if (mid.treasuryLDO > 0 && current.treasuryLDO < mid.treasuryLDO) {
            uint256 dropBps = ((mid.treasuryLDO - current.treasuryLDO) * BPS_DENOM)
                / mid.treasuryLDO;
            if (dropBps >= 200) { // 2% alert threshold
                signals[1] = W2;
            }
        }

        // G3: High concentration on open vote
        if (current.latestVoteOpen && current.latestVoteConcentration >= G3_CONCENTRATION_BPS) {
            signals[2] = W3;
        }

        // G5: ETH leaving treasury
        if (mid.treasuryETH > 0 && current.treasuryETH < mid.treasuryETH) {
            uint256 ethDropBps = ((mid.treasuryETH - current.treasuryETH) * BPS_DENOM)
                / mid.treasuryETH;
            if (ethDropBps >= 500) { // 5% alert threshold
                signals[4] = W5;
            }
        }

        // G8: Multiple active proposals
        if (current.activeVoteCount >= 2) {
            signals[7] = W8;
        }

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 8);

        if (risk.riskLevel >= RiskScorer.RISK_MED) {
            return (true, RiskScorer.encodePayload(risk));
        }

        return (false, bytes(""));
    }
}
