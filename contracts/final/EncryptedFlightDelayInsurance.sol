// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedFlightDelayInsurance
/// @notice Parametric flight delay insurance: encrypted premium paid, encrypted delay threshold,
///         automatic encrypted payout triggered when oracle reports delay.
contract EncryptedFlightDelayInsurance is ZamaEthereumConfig, Ownable {
    struct Policy {
        address insured;
        string flightNumber;
        euint64 premiumPaid;       // encrypted premium
        euint64 payoutAmount;      // encrypted max payout
        euint16 delayThresholdMin; // encrypted trigger threshold in minutes
        uint256 flightDate;
        bool active;
        bool paid;
    }

    struct FlightStatus {
        string flightNumber;
        euint16 actualDelayMin;    // encrypted actual delay reported by oracle
        bool reported;
    }

    mapping(uint256 => Policy) private policies;
    mapping(bytes32 => FlightStatus) private flightStatuses;
    mapping(address => uint256[]) private insuredPolicies;
    uint256 public policyCount;
    euint64 private _totalPremiumsCollected;
    euint64 private _totalPayoutsIssued;
    address public flightOracle;

    event PolicyIssued(uint256 indexed id, address insured, string flight);
    event DelayReported(string flightNumber);
    event PayoutTriggered(uint256 indexed id, address insured);
    event ClaimDenied(uint256 indexed id);

    modifier onlyOracle() {
        require(msg.sender == flightOracle || msg.sender == owner(), "Not oracle");
        _;
    }

    constructor(address oracle) Ownable(msg.sender) {
        flightOracle = oracle;
        _totalPremiumsCollected = FHE.asEuint64(0);
        _totalPayoutsIssued = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumsCollected);
        FHE.allowThis(_totalPayoutsIssued);
    }

    function issuePolicy(
        address insured,
        string calldata flightNumber,
        externalEuint64 encPremium, bytes calldata pmProof,
        externalEuint64 encPayout, bytes calldata pyProof,
        externalEuint16 encThreshold, bytes calldata tProof,
        uint256 flightDate
    ) external onlyOwner returns (uint256 id) {
        euint64 premium = FHE.fromExternal(encPremium, pmProof);
        euint64 payout = FHE.fromExternal(encPayout, pyProof);
        euint16 threshold = FHE.fromExternal(encThreshold, tProof);
        id = policyCount++;
        policies[id] = Policy({
            insured: insured, flightNumber: flightNumber,
            premiumPaid: premium, payoutAmount: payout, delayThresholdMin: threshold,
            flightDate: flightDate, active: true, paid: false
        });
        _totalPremiumsCollected = FHE.add(_totalPremiumsCollected, premium);
        FHE.allowThis(policies[id].premiumPaid);
        FHE.allow(policies[id].premiumPaid, insured);
        FHE.allowThis(policies[id].payoutAmount);
        FHE.allow(policies[id].payoutAmount, insured);
        FHE.allowThis(policies[id].delayThresholdMin);
        FHE.allowThis(_totalPremiumsCollected);
        insuredPolicies[insured].push(id);
        emit PolicyIssued(id, insured, flightNumber);
    }

    function reportFlightDelay(string calldata flightNumber, externalEuint16 encDelay, bytes calldata proof) external onlyOracle {
        bytes32 key = keccak256(abi.encodePacked(flightNumber));
        euint16 delay = FHE.fromExternal(encDelay, proof);
        flightStatuses[key] = FlightStatus({ flightNumber: flightNumber, actualDelayMin: delay, reported: true });
        FHE.allowThis(flightStatuses[key].actualDelayMin);
        emit DelayReported(flightNumber);
    }

    function triggerPayout(uint256 policyId) external {
        Policy storage pol = policies[policyId];
        require(pol.active && !pol.paid, "Invalid");
        bytes32 key = keccak256(abi.encodePacked(pol.flightNumber));
        require(flightStatuses[key].reported, "Not reported");
        ebool triggered = FHE.ge(flightStatuses[key].actualDelayMin, pol.delayThresholdMin);
        if (FHE.isInitialized(triggered)) {
            pol.paid = true;
            pol.active = false;
            _totalPayoutsIssued = FHE.add(_totalPayoutsIssued, pol.payoutAmount);
            FHE.allowThis(_totalPayoutsIssued);
            FHE.allow(pol.payoutAmount, pol.insured);
            emit PayoutTriggered(policyId, pol.insured);
        } else {
            emit ClaimDenied(policyId);
        }
    }

    function allowPolicyDetails(uint256 policyId, address viewer) external {
        require(policies[policyId].insured == msg.sender || msg.sender == owner(), "Unauthorized");
        FHE.allow(policies[policyId].premiumPaid, viewer);
        FHE.allow(policies[policyId].payoutAmount, viewer);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_totalPremiumsCollected, viewer);
        FHE.allow(_totalPayoutsIssued, viewer);
    }
}
