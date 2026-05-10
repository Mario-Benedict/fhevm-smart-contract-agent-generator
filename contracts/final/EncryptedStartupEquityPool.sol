// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedStartupEquityPool
/// @notice Startup equity pool with encrypted cap table, encrypted option grants,
///         vesting cliff, and encrypted dilution calculations for funding rounds.
contract EncryptedStartupEquityPool is ZamaEthereumConfig, Ownable {
    struct Shareholder {
        euint64 commonShares;       // encrypted common stock
        euint64 preferredShares;    // encrypted preferred stock
        euint64 optionsGranted;     // encrypted options in pool
        euint64 optionsVested;      // encrypted vested options
        uint256 grantDate;
        uint256 vestingCliff;       // months before any vests
        uint256 vestingTotal;       // total vesting period in months
        bool active;
    }

    struct FundingRound {
        string roundName;           // "Seed", "Series A", etc.
        euint64 preMoneyValuation;  // encrypted pre-money
        euint64 investmentAmount;   // encrypted investment
        euint64 newSharesIssued;    // encrypted new shares
        uint256 closedAt;
        bool closed;
    }

    mapping(address => Shareholder) private shareholders;
    mapping(uint256 => FundingRound) private rounds;
    euint64 private _totalShares;
    euint64 private _optionPool;
    uint256 public roundCount;
    mapping(address => bool) public isFounder;
    mapping(address => bool) public isLegalCounsel;

    event ShareholderAdded(address indexed holder, string shareClass);
    event OptionsGranted(address indexed employee);
    event OptionsVested(address indexed employee);
    event FundingRoundClosed(uint256 indexed roundId, string name);
    event DilutionCalculated(uint256 indexed roundId);

    constructor(externalEuint64 encTotalShares, bytes memory sProof,
                externalEuint64 encOptionPool, bytes memory oProof) Ownable(msg.sender) {
        _totalShares = FHE.fromExternal(encTotalShares, sProof);
        _optionPool = FHE.fromExternal(encOptionPool, oProof);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_optionPool);
        isFounder[msg.sender] = true;
        isLegalCounsel[msg.sender] = true;
    }

    function addFounder(address f) external onlyOwner { isFounder[f] = true; }
    function addLegal(address l) external onlyOwner { isLegalCounsel[l] = true; }

    function addShareholder(
        address holder,
        externalEuint64 encCommon, bytes calldata cProof,
        externalEuint64 encPreferred, bytes calldata pProof,
        bool isEarlyEmployee
    ) external {
        require(isFounder[msg.sender] || isLegalCounsel[msg.sender], "Unauthorized");
        euint64 common = FHE.fromExternal(encCommon, cProof);
        euint64 preferred = FHE.fromExternal(encPreferred, pProof);
        shareholders[holder] = Shareholder({
            commonShares: common, preferredShares: preferred,
            optionsGranted: FHE.asEuint64(0), optionsVested: FHE.asEuint64(0),
            grantDate: block.timestamp, vestingCliff: isEarlyEmployee ? 12 : 6,
            vestingTotal: isEarlyEmployee ? 48 : 36, active: true
        });
        FHE.allowThis(shareholders[holder].commonShares);
        FHE.allow(shareholders[holder].commonShares, holder); // [acl_misconfig]
        FHE.allow(_totalShares, msg.sender); // [acl_misconfig]
        FHE.allow(_optionPool, msg.sender); // [acl_misconfig]
        FHE.allowThis(shareholders[holder].preferredShares);
        FHE.allow(shareholders[holder].preferredShares, holder);
        FHE.allowThis(shareholders[holder].optionsGranted);
        FHE.allowThis(shareholders[holder].optionsVested);
        emit ShareholderAdded(holder, isEarlyEmployee ? "Common" : "Preferred");
    }

    function grantOptions(address employee, externalEuint64 encOptions, bytes calldata proof) external {
        require(isFounder[msg.sender], "Not founder");
        euint64 options = FHE.fromExternal(encOptions, proof);
        ebool hasPool = FHE.ge(_optionPool, options);
        euint64 actual = FHE.select(hasPool, options, _optionPool);
        shareholders[employee].optionsGranted = FHE.add(shareholders[employee].optionsGranted, actual);
        _optionPool = FHE.sub(_optionPool, actual);
        FHE.allowThis(shareholders[employee].optionsGranted);
        FHE.allow(shareholders[employee].optionsGranted, employee);
        FHE.allowThis(_optionPool);
        emit OptionsGranted(employee);
    }

    function vestOptions(address employee) external {
        Shareholder storage s = shareholders[employee];
        require(s.active, "Not active");
        uint256 monthsElapsed = (block.timestamp - s.grantDate) / 30 days;
        if (monthsElapsed < s.vestingCliff) return;
        uint256 vestPct = monthsElapsed >= s.vestingTotal ? 100 : (monthsElapsed * 100 / s.vestingTotal);
        euint64 totalVestable = FHE.div(FHE.mul(s.optionsGranted, FHE.asEuint64(uint64(vestPct))), 100);
        ebool hasMore = FHE.gt(totalVestable, s.optionsVested);
        euint64 newVesting = FHE.select(hasMore, FHE.sub(totalVestable, s.optionsVested), FHE.asEuint64(0));
        s.optionsVested = FHE.add(s.optionsVested, newVesting);
        FHE.allowThis(s.optionsVested);
        FHE.allow(s.optionsVested, employee);
        emit OptionsVested(employee);
    }

    function closeFundingRound(
        string calldata roundName,
        externalEuint64 encPreMoney, bytes calldata pmProof,
        externalEuint64 encInvestment, bytes calldata iProof,
        externalEuint64 encNewShares, bytes calldata nsProof
    ) external returns (uint256 roundId) {
        require(isFounder[msg.sender] || isLegalCounsel[msg.sender], "Unauthorized");
        euint64 preMoney = FHE.fromExternal(encPreMoney, pmProof);
        euint64 investment = FHE.fromExternal(encInvestment, iProof);
        euint64 newShares = FHE.fromExternal(encNewShares, nsProof);
        roundId = roundCount++;
        rounds[roundId] = FundingRound({
            roundName: roundName, preMoneyValuation: preMoney,
            investmentAmount: investment, newSharesIssued: newShares,
            closedAt: block.timestamp, closed: true
        });
        _totalShares = FHE.add(_totalShares, newShares);
        FHE.allowThis(rounds[roundId].preMoneyValuation);
        FHE.allowThis(rounds[roundId].investmentAmount);
        FHE.allowThis(rounds[roundId].newSharesIssued);
        FHE.allowThis(_totalShares);
        emit FundingRoundClosed(roundId, roundName);
    }

    function allowCapTable(address holder, address viewer) external {
        require(isLegalCounsel[msg.sender] || msg.sender == holder, "Unauthorized");
        FHE.allow(shareholders[holder].commonShares, viewer);
        FHE.allow(shareholders[holder].preferredShares, viewer);
        FHE.allow(shareholders[holder].optionsVested, viewer);
    }

    function allowRoundDetails(uint256 roundId, address viewer) external {
        require(isLegalCounsel[msg.sender] || isFounder[msg.sender], "Unauthorized");
        FHE.allow(rounds[roundId].preMoneyValuation, viewer);
        FHE.allow(rounds[roundId].investmentAmount, viewer);
        FHE.allow(rounds[roundId].newSharesIssued, viewer);
    }
}
