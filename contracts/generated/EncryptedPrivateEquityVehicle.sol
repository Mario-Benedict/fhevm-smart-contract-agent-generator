// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivateEquityVehicle
/// @notice Private equity fund-of-funds: encrypted LP capital commitments, encrypted IRR projections,
///         encrypted DPI/RVPI metrics, and confidential management fee waterfalls.
contract EncryptedPrivateEquityVehicle is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct FundOfFund {
        string fundName;
        string vintage;
        euint64 targetSizeUSD;        // encrypted target fund size
        euint64 committedCapital;     // encrypted committed capital
        euint64 calledCapital;        // encrypted drawn capital
        euint64 navUSD;               // encrypted current NAV
        euint64 distributedUSD;       // encrypted total distributed
        euint64 projectedIRRBps;      // encrypted projected IRR
        euint64 managementFeeBps;     // encrypted annual management fee
        euint64 carriedInterestBps;   // encrypted carried interest rate
        euint64 preferredReturnBps;   // encrypted hurdle rate
        bool fundraisingClosed;
    }

    struct LimitedPartner {
        euint64 commitmentUSD;        // encrypted LP commitment
        euint64 calledCapital;        // encrypted drawn amount
        euint64 distributionsUSD;     // encrypted distributions received
        euint64 navShareUSD;          // encrypted NAV allocation
        euint64 dpiRatio;             // encrypted DPI (distributed/paid-in) scaled 1000
        euint64 rvpiRatio;            // encrypted RVPI (residual/paid-in) scaled 1000
        uint256 investmentDate;
        bool active;
    }

    struct CapitalCall {
        uint256 fundId;
        euint64 totalCallUSD;         // encrypted total call amount
        euint64 callPercentBps;       // encrypted % of commitment called
        uint256 callDate;
        uint256 dueDate;
        bool funded;
    }

    mapping(uint256 => FundOfFund) private funds;
    mapping(uint256 => mapping(address => LimitedPartner)) private lps;
    mapping(uint256 => CapitalCall[]) private calls;
    uint256 public fundCount;
    euint64 private _totalAUM;
    mapping(address => bool) public isGP;       // General Partner
    mapping(address => bool) public isFundAdmin;

    event FundCreated(uint256 indexed id, string name, string vintage);
    event LPCommitted(uint256 indexed fundId, address lp);
    event CapitalCalled(uint256 indexed fundId, uint256 callIdx);
    event DistributionMade(uint256 indexed fundId, address lp);
    event NAVUpdated(uint256 indexed fundId);

    constructor() Ownable(msg.sender) {
        _totalAUM = FHE.asEuint64(0);
        FHE.allowThis(_totalAUM);
        isGP[msg.sender] = true;
        isFundAdmin[msg.sender] = true;
    }

    function addGP(address g) external onlyOwner { isGP[g] = true; }
    function addFundAdmin(address a) external onlyOwner { isFundAdmin[a] = true; }

    function createFund(
        string calldata name, string calldata vintage,
        externalEuint64 encTarget, bytes calldata tProof,
        externalEuint64 encMgmtFee, bytes calldata mfProof,
        externalEuint64 encCarry, bytes calldata cProof,
        externalEuint64 encHurdle, bytes calldata hProof
    ) external returns (uint256 id) {
        require(isGP[msg.sender], "Not GP");
        euint64 target = FHE.fromExternal(encTarget, tProof);
        euint64 mgmtFee = FHE.fromExternal(encMgmtFee, mfProof);
        euint64 carry = FHE.fromExternal(encCarry, cProof);
        euint64 hurdle = FHE.fromExternal(encHurdle, hProof);
        id = fundCount++;
        funds[id] = FundOfFund({
            fundName: name, vintage: vintage, targetSizeUSD: target,
            committedCapital: FHE.asEuint64(0), calledCapital: FHE.asEuint64(0),
            navUSD: FHE.asEuint64(0), distributedUSD: FHE.asEuint64(0),
            projectedIRRBps: FHE.asEuint64(1500), managementFeeBps: mgmtFee,
            carriedInterestBps: carry, preferredReturnBps: hurdle, fundraisingClosed: false
        });
        FHE.allowThis(funds[id].targetSizeUSD);
        FHE.allowThis(funds[id].committedCapital);
        FHE.allowThis(funds[id].calledCapital);
        FHE.allowThis(funds[id].navUSD);
        FHE.allowThis(funds[id].distributedUSD);
        FHE.allowThis(funds[id].projectedIRRBps);
        FHE.allowThis(funds[id].managementFeeBps);
        FHE.allowThis(funds[id].carriedInterestBps);
        FHE.allowThis(funds[id].preferredReturnBps);
        emit FundCreated(id, name, vintage);
    }

    function commitLP(
        uint256 fundId,
        externalEuint64 encCommitment, bytes calldata proof
    ) external {
        FundOfFund storage fund = funds[fundId];
        require(!fund.fundraisingClosed, "Closed");
        euint64 commitment = FHE.fromExternal(encCommitment, proof);
        ebool withinTarget = FHE.le(FHE.add(fund.committedCapital, commitment), fund.targetSizeUSD);
        euint64 actual = FHE.select(withinTarget, commitment, FHE.sub(fund.targetSizeUSD, fund.committedCapital));
        lps[fundId][msg.sender] = LimitedPartner({
            commitmentUSD: actual, calledCapital: FHE.asEuint64(0),
            distributionsUSD: FHE.asEuint64(0), navShareUSD: FHE.asEuint64(0),
            dpiRatio: FHE.asEuint64(0), rvpiRatio: FHE.asEuint64(0),
            investmentDate: block.timestamp, active: true
        });
        fund.committedCapital = FHE.add(fund.committedCapital, actual);
        FHE.allowThis(lps[fundId][msg.sender].commitmentUSD);
        FHE.allowThis(lps[fundId][msg.sender].calledCapital);
        FHE.allowThis(lps[fundId][msg.sender].distributionsUSD);
        FHE.allowThis(lps[fundId][msg.sender].navShareUSD);
        FHE.allowThis(lps[fundId][msg.sender].dpiRatio);
        FHE.allowThis(lps[fundId][msg.sender].rvpiRatio);
        FHE.allow(lps[fundId][msg.sender].commitmentUSD, msg.sender);
        FHE.allow(lps[fundId][msg.sender].distributionsUSD, msg.sender);
        FHE.allow(lps[fundId][msg.sender].dpiRatio, msg.sender);
        FHE.allowThis(fund.committedCapital);
        _totalAUM = FHE.add(_totalAUM, actual);
        FHE.allowThis(_totalAUM);
        emit LPCommitted(fundId, msg.sender);
    }

    function issueCapitalCall(
        uint256 fundId,
        externalEuint64 encCallBps, bytes calldata proof,
        uint256 dueDate
    ) external returns (uint256 callIdx) {
        require(isGP[msg.sender], "Not GP");
        FundOfFund storage fund = funds[fundId];
        euint64 callBps = FHE.fromExternal(encCallBps, proof);
        euint64 callAmount = FHE.div(FHE.mul(fund.committedCapital, callBps), 10000);
        callIdx = calls[fundId].length;
        calls[fundId].push(CapitalCall({
            fundId: fundId, totalCallUSD: callAmount,
            callPercentBps: callBps, callDate: block.timestamp, dueDate: dueDate, funded: false
        }));
        fund.calledCapital = FHE.add(fund.calledCapital, callAmount);
        FHE.allowThis(calls[fundId][callIdx].totalCallUSD);
        FHE.allowThis(calls[fundId][callIdx].callPercentBps);
        FHE.allowThis(fund.calledCapital);
        emit CapitalCalled(fundId, callIdx);
    }

    function distributeToLP(
        uint256 fundId, address lp,
        externalEuint64 encDistribution, bytes calldata proof
    ) external nonReentrant {
        require(isGP[msg.sender] || isFundAdmin[msg.sender], "Not authorized");
        euint64 distribution = FHE.fromExternal(encDistribution, proof);
        LimitedPartner storage lpData = lps[fundId][lp];
        require(lpData.active, "Not active LP");
        lpData.distributionsUSD = FHE.add(lpData.distributionsUSD, distribution);
        funds[fundId].distributedUSD = FHE.add(funds[fundId].distributedUSD, distribution);
        // Update DPI = distributions / called capital
        ebool hasCalledCapital = FHE.gt(lpData.calledCapital, FHE.asEuint64(0));
        lpData.dpiRatio = FHE.select(hasCalledCapital,
            FHE.mul(lpData.distributionsUSD, FHE.asEuint64(1000)), FHE.asEuint64(0)); // simplified: calledCapital divisor omitted
        FHE.allowThis(lpData.distributionsUSD);
        FHE.allow(lpData.distributionsUSD, lp);
        FHE.allowThis(lpData.dpiRatio);
        FHE.allow(lpData.dpiRatio, lp);
        FHE.allowThis(funds[fundId].distributedUSD);
        FHE.allow(distribution, lp);
        emit DistributionMade(fundId, lp);
    }

    function updateNAV(uint256 fundId, externalEuint64 encNAV, bytes calldata proof) external {
        require(isFundAdmin[msg.sender], "Not admin");
        funds[fundId].navUSD = FHE.fromExternal(encNAV, proof);
        FHE.allowThis(funds[fundId].navUSD);
        FHE.allow(funds[fundId].navUSD, owner());
        emit NAVUpdated(fundId);
    }

    function updateProjectedIRR(uint256 fundId, externalEuint64 encIRR, bytes calldata proof) external {
        require(isFundAdmin[msg.sender], "Not admin");
        funds[fundId].projectedIRRBps = FHE.fromExternal(encIRR, proof);
        FHE.allowThis(funds[fundId].projectedIRRBps);
    }
}
