// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ERC20PrivateDividendReinvestment
/// @notice DRIP (Dividend Reinvestment Plan) token: encrypted quarterly dividends per share,
///         encrypted reinvestment elections, encrypted net asset value, and confidential DRIP pool.
contract ERC20PrivateDividendReinvestment is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public name = "PrivateDRIP Token";
    string public symbol = "PDRIP";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    struct ShareholderAccount {
        euint64 balance;             // encrypted token balance
        euint64 accruedDividends;    // encrypted unpaid dividends
        euint64 reinvestedAmount;    // encrypted lifetime reinvested
        euint64 reinvestmentBps;     // encrypted % to reinvest (0-10000)
        uint256 lastDividendEpoch;
        bool enrolled;
    }

    struct DividendEpoch {
        euint64 dividendPerShare;    // encrypted dividend per token
        euint64 totalDistributed;    // encrypted total pool
        uint256 snapshotBlock;
        bool finalized;
    }

    mapping(address => ShareholderAccount) private accounts;
    mapping(uint256 => DividendEpoch) private epochs;
    uint256 public epochCount;
    euint64 private _navPerShare;         // encrypted net asset value per share
    euint64 private _totalDRIPPool;       // encrypted total DRIP reinvestment pool
    mapping(address => bool) public isTrustee;

    event Transfer(address indexed from, address indexed to);
    event DividendEpochCreated(uint256 indexed epochId);
    event DividendClaimed(address indexed holder, uint256 epochId);
    event ReinvestmentElectionSet(address indexed holder);
    event NAVUpdated();

    constructor(uint256 initialSupply) Ownable(msg.sender) {
        totalSupply = initialSupply;
        _navPerShare = FHE.asEuint64(1000); // encrypted NAV starts at 1000 (scaled)
        _totalDRIPPool = FHE.asEuint64(0);
        FHE.allowThis(_navPerShare);
        FHE.allowThis(_totalDRIPPool);
        isTrustee[msg.sender] = true;
        // Mint to deployer
        accounts[msg.sender].balance = FHE.asEuint64(uint64(initialSupply));
        accounts[msg.sender].accruedDividends = FHE.asEuint64(0);
        accounts[msg.sender].reinvestedAmount = FHE.asEuint64(0);
        accounts[msg.sender].reinvestmentBps = FHE.asEuint64(0);
        accounts[msg.sender].enrolled = true;
        FHE.allowThis(accounts[msg.sender].balance);
        FHE.allowThis(accounts[msg.sender].accruedDividends);
        FHE.allowThis(accounts[msg.sender].reinvestedAmount);
        FHE.allowThis(accounts[msg.sender].reinvestmentBps);
        FHE.allow(accounts[msg.sender].balance, msg.sender);
    }

    modifier onlyTrustee() { require(isTrustee[msg.sender], "Not trustee"); _; }
    function addTrustee(address t) external onlyOwner { isTrustee[t] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function enroll(externalEuint64 encReinvestBps, bytes calldata proof) external whenNotPaused {
        euint64 bps = FHE.fromExternal(encReinvestBps, proof);
        ShareholderAccount storage acc = accounts[msg.sender];
        if (!acc.enrolled) {
            acc.balance = FHE.asEuint64(0);
            acc.accruedDividends = FHE.asEuint64(0);
            acc.reinvestedAmount = FHE.asEuint64(0);
            FHE.allowThis(acc.balance);
            FHE.allowThis(acc.accruedDividends);
            FHE.allowThis(acc.reinvestedAmount);
        }
        acc.reinvestmentBps = bps;
        acc.enrolled = true;
        FHE.allowThis(acc.reinvestmentBps);
        FHE.allow(acc.reinvestmentBps, msg.sender);
        emit ReinvestmentElectionSet(msg.sender);
    }

    function transfer(
        address to,
        externalEuint64 encAmount, bytes calldata proof
    ) external whenNotPaused nonReentrant {
        require(accounts[to].enrolled, "Recipient not enrolled");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasBal = FHE.ge(accounts[msg.sender].balance, amount);
        euint64 actual = FHE.select(hasBal, amount, accounts[msg.sender].balance);
        accounts[msg.sender].balance = FHE.sub(accounts[msg.sender].balance, actual);
        accounts[to].balance = FHE.add(accounts[to].balance, actual);
        FHE.allowThis(accounts[msg.sender].balance);
        FHE.allow(accounts[msg.sender].balance, msg.sender);
        FHE.allowThis(accounts[to].balance);
        FHE.allow(accounts[to].balance, to);
        emit Transfer(msg.sender, to);
    }

    function createDividendEpoch(
        externalEuint64 encDivPerShare, bytes calldata dProof,
        externalEuint64 encTotal, bytes calldata tProof
    ) external onlyTrustee returns (uint256 epochId) {
        euint64 divPerShare = FHE.fromExternal(encDivPerShare, dProof);
        euint64 total = FHE.fromExternal(encTotal, tProof);
        epochId = epochCount++;
        epochs[epochId] = DividendEpoch({
            dividendPerShare: divPerShare, totalDistributed: total,
            snapshotBlock: block.number, finalized: true
        });
        FHE.allowThis(epochs[epochId].dividendPerShare);
        FHE.allowThis(epochs[epochId].totalDistributed);
        emit DividendEpochCreated(epochId);
    }

    function claimDividend(uint256 epochId) external nonReentrant {
        DividendEpoch storage ep = epochs[epochId];
        require(ep.finalized, "Not finalized");
        ShareholderAccount storage acc = accounts[msg.sender];
        require(acc.enrolled && acc.lastDividendEpoch < epochId + 1, "Already claimed");
        // Calculate user dividend = balance * dividendPerShare / 1e18 (scaled)
        euint64 userDiv = FHE.div(FHE.mul(acc.balance, ep.dividendPerShare), 1_000_000);
        // Calculate reinvestment portion
        euint64 reinvestPortion = FHE.div(FHE.mul(userDiv, acc.reinvestmentBps), 10000);
        euint64 cashPortion = FHE.sub(userDiv, reinvestPortion);
        // Reinvest: add shares based on NAV
        euint64 newShares = FHE.div(reinvestPortion, _navPerShare);
        acc.balance = FHE.add(acc.balance, newShares);
        acc.accruedDividends = FHE.add(acc.accruedDividends, cashPortion);
        acc.reinvestedAmount = FHE.add(acc.reinvestedAmount, reinvestPortion);
        acc.lastDividendEpoch = epochId + 1;
        _totalDRIPPool = FHE.add(_totalDRIPPool, reinvestPortion);
        FHE.allowThis(acc.balance);
        FHE.allow(acc.balance, msg.sender);
        FHE.allowThis(acc.accruedDividends);
        FHE.allow(acc.accruedDividends, msg.sender);
        FHE.allowThis(acc.reinvestedAmount);
        FHE.allow(acc.reinvestedAmount, msg.sender);
        FHE.allowThis(_totalDRIPPool);
        emit DividendClaimed(msg.sender, epochId);
    }

    function updateNAV(externalEuint64 encNAV, bytes calldata proof) external onlyTrustee {
        _navPerShare = FHE.fromExternal(encNAV, proof);
        FHE.allowThis(_navPerShare);
        emit NAVUpdated();
    }
}
