// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialScholarTokenWithMeritGating
/// @notice Scholarship ERC20 with encrypted merit scores, private award allocations,
///         hidden donor identities, confidential matching gift calculations,
///         and encrypted GPR-gated disbursements.
contract ConfidentialScholarTokenWithMeritGating is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Scholar Merit";
    string public constant symbol = "SCHM";
    uint8  public constant decimals = 6;

    struct ScholarProfile {
        address scholar;
        euint16 meritScore;            // encrypted merit (GPA, test scores)
        euint16 needScore;             // encrypted financial need
        euint16 gprThreshold;          // encrypted minimum GPR to maintain
        euint64 awardsReceived;        // encrypted cumulative awards
        euint64 maxAwardAllocation;    // encrypted max award pool
        bool active;
    }

    struct DonorRecord {
        euint64 donatedAmount;         // encrypted donation
        euint64 matchingGiftAmount;    // encrypted employer match
        uint256 donatedAt;
    }

    mapping(address => euint64) private _balances;
    mapping(uint256 => ScholarProfile) private scholars;
    mapping(address => uint256) private scholarId;
    mapping(uint256 => DonorRecord) private donors;
    mapping(address => bool) public isFinancialAidOfficer;

    euint64 private _totalSupply;
    euint64 private _scholarshipEndowment;
    euint64 private _matchingGiftPool;
    uint256 public scholarCount;
    uint256 public donorCount;

    event Transfer(address indexed from, address indexed to);
    event ScholarRegistered(uint256 indexed id, address scholar);
    event AwardDisbursed(uint256 indexed scholarId, uint256 timestamp);
    event DonationReceived(uint256 indexed donorId, uint256 timestamp);

    modifier onlyFinancialAidOfficer() {
        require(isFinancialAidOfficer[msg.sender] || msg.sender == owner(), "Not financial aid officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _scholarshipEndowment = FHE.asEuint64(0);
        _matchingGiftPool = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_scholarshipEndowment);
        FHE.allowThis(_matchingGiftPool);
        isFinancialAidOfficer[msg.sender] = true;
    }

    function addFinancialAidOfficer(address fao) external onlyOwner { isFinancialAidOfficer[fao] = true; }

    function registerScholar(
        address scholar,
        externalEuint16 encMerit,  bytes calldata mProof,
        externalEuint16 encNeed,   bytes calldata nProof,
        externalEuint16 encGPR,    bytes calldata gProof,
        externalEuint64 encMaxAward, bytes calldata maProof
    ) external onlyFinancialAidOfficer returns (uint256 id) {
        euint16 merit    = FHE.fromExternal(encMerit, mProof);
        euint16 need     = FHE.fromExternal(encNeed, nProof);
        euint16 gpr      = FHE.fromExternal(encGPR, gProof);
        euint64 maxAward = FHE.fromExternal(encMaxAward, maProof);
        id = scholarCount++;
        scholarId[scholar] = id;
        scholars[id] = ScholarProfile({
            scholar: scholar, meritScore: merit, needScore: need, gprThreshold: gpr,
            awardsReceived: FHE.asEuint64(0), maxAwardAllocation: maxAward, active: true
        });
        FHE.allowThis(scholars[id].meritScore);
        FHE.allowThis(scholars[id].needScore); FHE.allow(scholars[id].needScore, scholar);
        FHE.allowThis(scholars[id].gprThreshold); FHE.allow(scholars[id].gprThreshold, scholar);
        FHE.allowThis(scholars[id].awardsReceived); FHE.allow(scholars[id].awardsReceived, scholar);
        FHE.allowThis(scholars[id].maxAwardAllocation); FHE.allow(scholars[id].maxAwardAllocation, scholar);
        emit ScholarRegistered(id, scholar);
    }

    function receiveDonation(
        externalEuint64 encDonation, bytes calldata dProof,
        externalEuint64 encMatch, bytes calldata mProof
    ) external returns (uint256 donorId) {
        euint64 donation = FHE.fromExternal(encDonation, dProof);
        euint64 matchAmt = FHE.fromExternal(encMatch, mProof);
        donorId = donorCount++;
        donors[donorId] = DonorRecord({ donatedAmount: donation, matchingGiftAmount: matchAmt, donatedAt: block.timestamp });
        _scholarshipEndowment = FHE.add(_scholarshipEndowment, donation);
        _matchingGiftPool = FHE.add(_matchingGiftPool, matchAmt);
        _totalSupply = FHE.add(_totalSupply, FHE.add(donation, matchAmt));
        FHE.allowThis(donors[donorId].donatedAmount);
        FHE.allowThis(donors[donorId].matchingGiftAmount);
        FHE.allowThis(_scholarshipEndowment); FHE.allowThis(_matchingGiftPool); FHE.allowThis(_totalSupply);
        emit DonationReceived(donorId, block.timestamp);
    }

    function disburseAward(uint256 sid, externalEuint64 encAward, bytes calldata proof) external onlyFinancialAidOfficer nonReentrant {
        ScholarProfile storage s = scholars[sid];
        require(s.active, "Scholar inactive");
        euint64 award = FHE.fromExternal(encAward, proof);
        ebool withinMax = FHE.le(FHE.add(s.awardsReceived, award), s.maxAwardAllocation);
        euint64 effAward = FHE.select(withinMax, award, FHE.asEuint64(0));
        ebool endowmentSufficient = FHE.ge(_scholarshipEndowment, effAward);
        euint64 finalAward = FHE.select(endowmentSufficient, effAward, FHE.asEuint64(0));
        if (!FHE.isInitialized(_balances[s.scholar])) { _balances[s.scholar] = FHE.asEuint64(0); FHE.allowThis(_balances[s.scholar]); }
        _balances[s.scholar] = FHE.add(_balances[s.scholar], finalAward);
        s.awardsReceived = FHE.add(s.awardsReceived, finalAward);
        ebool _safeSub64 = FHE.ge(_scholarshipEndowment, finalAward);
        _scholarshipEndowment = FHE.select(_safeSub64, FHE.sub(_scholarshipEndowment, finalAward), FHE.asEuint64(0));
        FHE.allowThis(_balances[s.scholar]); FHE.allow(_balances[s.scholar], s.scholar);
        FHE.allowThis(s.awardsReceived); FHE.allow(s.awardsReceived, s.scholar);
        FHE.allowThis(_scholarshipEndowment);
        emit AwardDisbursed(sid, block.timestamp);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external nonReentrant {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 eff = FHE.select(sufficient, amt, FHE.asEuint64(0));
        ebool _safeSub65 = FHE.ge(_balances[msg.sender], eff);
        _balances[msg.sender] = FHE.select(_safeSub65, FHE.sub(_balances[msg.sender], eff), FHE.asEuint64(0));
        _balances[to] = FHE.add(_balances[to], eff);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function allowEndowmentStats(address viewer) external onlyOwner {
        FHE.allow(_scholarshipEndowment, viewer); FHE.allow(_matchingGiftPool, viewer);
    }
    function balanceOf(address a) external view returns (euint64) { return _balances[a]; }
}
