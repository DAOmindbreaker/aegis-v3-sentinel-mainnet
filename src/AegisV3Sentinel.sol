// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";

/**
 * @title  Aegis V3 Sentinel — Mainnet
 * @author DAOmindbreaker
 * @notice Drosera Trap that monitors the Lido V3 stVaults ecosystem on Ethereum
 *         Mainnet and triggers when protocol-level risk conditions are detected
 *         across multiple consecutive block samples.
 *
 * @dev    All five checks encode to a single generic payload:
 *           abi.encode(uint8 checkId, uint256 a, uint256 b, uint256 c)
 *         This matches the single TOML response_function entrypoint:
 *           handleRisk(uint8,uint256,uint256,uint256)
 *
 *         Check ID mapping:
 *           1 = Bad Debt Spike        (CRITICAL)
 *           2 = Protocol Pause        (CRITICAL)
 *           3 = Vault Health Degradation (HIGH)
 *           4 = wstETH Rate Drop      (HIGH)
 *           5 = External Ratio Breach (CRITICAL)
 *
 * @dev    Mainnet differences from Hoodi testnet:
 *         - VaultHub address updated to mainnet proxy
 *         - Accounting functions (getExternalShares, getMaxExternalRatioBP) are
 *           integrated into stETH contract on mainnet (not separate contract)
 *         - VaultHub.vaultByIndex() is 1-indexed on mainnet (not 0-indexed)
 *         - stETH and wstETH use mainnet addresses
 *
 * Contracts monitored (Lido V3 on Ethereum Mainnet):
 *   VaultHub    : 0x1d201BE093d847f6446530Efb0E8Fb426d176709
 *   stETH       : 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84
 *   wstETH      : 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
 *
 * @dev    On mainnet, Accounting functions are part of stETH contract:
 *         - stETH.getExternalShares() returns total external shares
 *         - stETH.getMaxExternalRatioBP() returns max external ratio cap
 */

// ─────────────────────────────────────────────
//  External interfaces
// ─────────────────────────────────────────────

interface IVaultHub {
    function vaultsCount() external view returns (uint256);
    function badDebtToInternalize() external view returns (uint256);
    function isPaused() external view returns (bool);
    function vaultByIndex(uint256 index) external view returns (address);
    function isVaultHealthy(address vault) external view returns (bool);
    function healthShortfallShares(address vault) external view returns (uint256);
}

/// @notice On mainnet, Accounting functions are integrated into stETH contract
interface IStETH {
    function getTotalPooledEther() external view returns (uint256);
    function getTotalShares() external view returns (uint256);
    function getExternalShares() external view returns (uint256);
    function getMaxExternalRatioBP() external view returns (uint256);
}

interface IWstETH {
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
}

// ─────────────────────────────────────────────
//  Data structures
// ─────────────────────────────────────────────

/// @notice Full snapshot of Lido V3 stVaults ecosystem state at a given block sample
struct AegisSnapshot {
    // ── VaultHub state ──────────────────────
    uint256 vaultsCount;
    uint256 badDebt;
    bool    protocolPaused;
    uint256 unhealthyVaults;
    uint256 totalShortfallShares;
    uint256 sampleSize;

    // ── wstETH / stETH state ─────────────────
    uint256 wstEthRate;
    uint256 totalPooledEther;
    uint256 totalShares;

    // ── Accounting cross-check ───────────────
    uint256 externalShares;
    uint256 maxExternalRatioBp;
    uint256 externalRatioBps;

    // ── Metadata ────────────────────────────
    bool    valid;
}

// ─────────────────────────────────────────────
//  Trap contract
// ─────────────────────────────────────────────

contract AegisV3Sentinel is ITrap {

    // ── Constants ────────────────────────────

    /// @notice Lido VaultHub proxy (Ethereum Mainnet)
    address public constant VAULT_HUB = 0x1d201BE093d847f6446530Efb0E8Fb426d176709;

    /// @notice Lido stETH proxy (Ethereum Mainnet)
    /// @dev    On mainnet, stETH also provides Accounting functions:
    ///         getExternalShares() and getMaxExternalRatioBP()
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /// @notice Lido wstETH (Ethereum Mainnet)
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice Number of vaults to sample per collect() call
    uint256 public constant VAULT_SAMPLE_SIZE = 25;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOM = 10_000;

    /// @notice Trigger Check D if wstETH rate drops more than 300 bps (3%)
    uint256 public constant RATE_DROP_BPS = 300;

    /// @notice Alert if wstETH rate drops more than 100 bps (1%)
    uint256 public constant RATE_ALERT_BPS = 100;

    /// @notice Alert if external ratio is within 500 bps of the cap
    uint256 public constant EXTERNAL_RATIO_ALERT_BUFFER_BPS = 500;

    /// @notice Check C: trigger if unhealthy vaults >= 12% of sample (proportional)
    uint256 public constant UNHEALTHY_RATIO_BPS = 1_200;

    // ── collect() ────────────────────────────

    /**
     * @notice Collects an AegisSnapshot from VaultHub, stETH, wstETH.
     * @dev    On mainnet, Accounting data comes from stETH contract directly.
     *         VaultHub.vaultByIndex() is 1-indexed on mainnet.
     *         Vault sampling uses stride pattern for distributed index coverage.
     */
    function collect() external view returns (bytes memory) {
        AegisSnapshot memory snap;

        // ── VaultHub global state ─────────────
        try IVaultHub(VAULT_HUB).vaultsCount() returns (uint256 count) {
            snap.vaultsCount = count;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        try IVaultHub(VAULT_HUB).badDebtToInternalize() returns (uint256 debt) {
            snap.badDebt = debt;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        try IVaultHub(VAULT_HUB).isPaused() returns (bool paused) {
            snap.protocolPaused = paused;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── Adaptive vault sampling (stride pattern, 1-indexed) ──
        // Mainnet VaultHub uses 1-indexed vaultByIndex (index 0 reverts with ZeroArgument)
        uint256 sampleSize = snap.vaultsCount < VAULT_SAMPLE_SIZE
            ? snap.vaultsCount
            : VAULT_SAMPLE_SIZE;

        snap.sampleSize = sampleSize;

        uint256 stride = sampleSize > 0 && snap.vaultsCount > sampleSize
            ? snap.vaultsCount / sampleSize
            : 1;

        for (uint256 i = 0; i < sampleSize; ) {
            // 1-indexed: first vault is at index 1
            uint256 vaultIndex = (i * stride) + 1;

            if (vaultIndex > snap.vaultsCount) {
                unchecked { ++i; }
                continue;
            }

            address vault;
            try IVaultHub(VAULT_HUB).vaultByIndex(vaultIndex) returns (address v) {
                vault = v;
            } catch {
                unchecked { ++i; }
                continue;
            }

            if (vault == address(0)) {
                unchecked { ++i; }
                continue;
            }

            try IVaultHub(VAULT_HUB).isVaultHealthy(vault) returns (bool healthy) {
                if (!healthy) {
                    unchecked { ++snap.unhealthyVaults; }
                }
            } catch {
                unchecked { ++i; }
                continue;
            }

            try IVaultHub(VAULT_HUB).healthShortfallShares(vault) returns (uint256 shortfall) {
                snap.totalShortfallShares += shortfall;
            } catch {
                // Non-critical — skip without invalidating
            }

            unchecked { ++i; }
        }

        // ── wstETH redemption rate ────────────
        try IWstETH(WSTETH).getPooledEthByShares(1e18) returns (uint256 rate) {
            snap.wstEthRate = rate;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── stETH pool ────────────────────────
        try IStETH(STETH).getTotalPooledEther() returns (uint256 pooled) {
            snap.totalPooledEther = pooled;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        try IStETH(STETH).getTotalShares() returns (uint256 shares) {
            snap.totalShares = shares;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── Accounting cross-check (from stETH contract on mainnet) ─
        try IStETH(STETH).getExternalShares() returns (uint256 extShares) {
            snap.externalShares = extShares;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        try IStETH(STETH).getMaxExternalRatioBP() returns (uint256 maxRatio) {
            snap.maxExternalRatioBp = maxRatio;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // Derive actual external ratio in bps
        if (snap.totalShares > 0 && snap.externalShares > 0) {
            snap.externalRatioBps = (snap.externalShares * BPS_DENOM) / snap.totalShares;
        }

        snap.valid = true;
        return abi.encode(snap);
    }

    // ── shouldRespond() ──────────────────────

    /**
     * @notice Analyses 3 consecutive AegisSnapshots for protocol risk conditions.
     * @dev    All checks encode to handleRisk(uint8,uint256,uint256,uint256).
     *
     *         Check A (id=1) — Bad Debt Spike (CRITICAL)
     *           Payload: (1, badDebt, unhealthyVaults, totalShortfallShares)
     *
     *         Check B (id=2) — Protocol Pause (CRITICAL)
     *           Payload: (2, vaultsCount, badDebt, 0)
     *
     *         Check C (id=3) — Vault Health Degradation (HIGH)
     *           Proportional threshold: unhealthyVaults/sampleSize >= UNHEALTHY_RATIO_BPS
     *           Payload: (3, unhealthyVaults, totalShortfallShares, midUnhealthyVaults)
     *
     *         Check D (id=4) — wstETH Rate Drop (HIGH)
     *           3-snapshot sustained decline. > RATE_DROP_BPS from oldest to current.
     *           Payload: (4, currentRate, oldestRate, dropBps)
     *
     *         Check E (id=5) — External Ratio Breach (CRITICAL)
     *           Sustained breach across all 3 snapshots.
     *           Payload: (5, externalRatioBps, maxExternalRatioBp, externalShares)
     */
    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {

        if (data.length < 3) return (false, bytes(""));

        AegisSnapshot memory current = abi.decode(data[0], (AegisSnapshot));
        AegisSnapshot memory mid     = abi.decode(data[1], (AegisSnapshot));
        AegisSnapshot memory oldest  = abi.decode(data[2], (AegisSnapshot));

        if (!current.valid || !mid.valid || !oldest.valid) {
            return (false, bytes(""));
        }

        // ── Check A: Bad debt spike ───────────
        if (current.badDebt > 0) {
            return (true, abi.encode(
                uint8(1),
                current.badDebt,
                current.unhealthyVaults,
                current.totalShortfallShares
            ));
        }

        // ── Check B: Protocol pause ───────────
        if (current.protocolPaused && !mid.protocolPaused) {
            return (true, abi.encode(
                uint8(2),
                current.vaultsCount,
                current.badDebt,
                uint256(0)
            ));
        }

        // ── Check C: Vault health degradation (proportional) ─
        bool currentDegraded = current.sampleSize > 0 &&
            (current.unhealthyVaults * BPS_DENOM) / current.sampleSize >= UNHEALTHY_RATIO_BPS;

        bool midDegraded = mid.sampleSize > 0 &&
            (mid.unhealthyVaults * BPS_DENOM) / mid.sampleSize >= UNHEALTHY_RATIO_BPS;

        if (currentDegraded && midDegraded) {
            return (true, abi.encode(
                uint8(3),
                current.unhealthyVaults,
                current.totalShortfallShares,
                mid.unhealthyVaults
            ));
        }

        // ── Check D: wstETH rate drop ─────────
        if (oldest.wstEthRate > 0 && current.wstEthRate < oldest.wstEthRate) {
            uint256 rateDropBps =
                ((oldest.wstEthRate - current.wstEthRate) * BPS_DENOM)
                    / oldest.wstEthRate;

            bool midAlsoDropped = mid.wstEthRate < oldest.wstEthRate;

            if (rateDropBps >= RATE_DROP_BPS && midAlsoDropped) {
                return (true, abi.encode(
                    uint8(4),
                    current.wstEthRate,
                    oldest.wstEthRate,
                    rateDropBps
                ));
            }
        }

        // ── Check E: External shares ratio breach ─
        if (
            current.maxExternalRatioBp > 0 &&
            current.externalRatioBps > current.maxExternalRatioBp &&
            mid.externalRatioBps     > mid.maxExternalRatioBp &&
            oldest.externalRatioBps  > oldest.maxExternalRatioBp
        ) {
            return (true, abi.encode(
                uint8(5),
                current.externalRatioBps,
                current.maxExternalRatioBp,
                current.externalShares
            ));
        }

        return (false, bytes(""));
    }

    // ── shouldAlert() ─────────────────────────

    /**
     * @notice Early warning system — fires before shouldRespond() thresholds.
     * @dev    Alert payloads also use handleRisk encoding with IDs 10–13.
     *
     *         Alert A (id=10) — Any unhealthy vault (≥1, sustained)
     *         Alert B (id=11) — wstETH rate drop > 100 bps
     *         Alert C (id=12) — External ratio approaching cap (within 500 bps)
     *         Alert D (id=13) — Pre-bad-debt shortfall signal
     */
    function shouldAlert(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {

        if (data.length < 2) return (false, bytes(""));

        AegisSnapshot memory current = abi.decode(data[0], (AegisSnapshot));
        AegisSnapshot memory mid     = abi.decode(data[1], (AegisSnapshot));

        if (!current.valid || !mid.valid) return (false, bytes(""));

        // ── Alert A: Any unhealthy vault ──────
        if (current.unhealthyVaults > 0 && mid.unhealthyVaults > 0) {
            return (true, abi.encode(
                uint8(10),
                current.unhealthyVaults,
                current.totalShortfallShares,
                mid.unhealthyVaults
            ));
        }

        // ── Alert B: Early rate drop (>100 bps) ──
        if (mid.wstEthRate > 0 && current.wstEthRate < mid.wstEthRate) {
            uint256 alertDropBps =
                ((mid.wstEthRate - current.wstEthRate) * BPS_DENOM)
                    / mid.wstEthRate;

            if (alertDropBps >= RATE_ALERT_BPS) {
                return (true, abi.encode(
                    uint8(11),
                    current.wstEthRate,
                    mid.wstEthRate,
                    alertDropBps
                ));
            }
        }

        // ── Alert C: External ratio approaching cap ──
        if (
            current.maxExternalRatioBp > EXTERNAL_RATIO_ALERT_BUFFER_BPS &&
            current.externalRatioBps > 0 &&
            current.externalRatioBps >= current.maxExternalRatioBp - EXTERNAL_RATIO_ALERT_BUFFER_BPS &&
            current.externalRatioBps < current.maxExternalRatioBp
        ) {
            return (true, abi.encode(
                uint8(12),
                current.externalRatioBps,
                current.maxExternalRatioBp,
                current.externalShares
            ));
        }

        // ── Alert D: Pre-bad-debt shortfall ──
        if (
            current.badDebt == 0 &&
            current.totalShortfallShares > 0 &&
            mid.totalShortfallShares > 0
        ) {
            return (true, abi.encode(
                uint8(13),
                current.totalShortfallShares,
                mid.totalShortfallShares,
                current.unhealthyVaults
            ));
        }

        return (false, bytes(""));
    }
}
