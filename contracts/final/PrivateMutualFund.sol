// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateMutualFund
/// @notice Mutual fund with encrypted NAV, encrypted unit holdings per investor.
///         Fund manager rebalances private portfolio allocations.
contract PrivateMutualFund is ZamaEthereumConfig, Ownable {
    string public fundName;
    string public fundSymbol;

    euint64 private _navPerUnit;       // encrypted net asset value per unit
    euint64 private _totalUnits;
    euint64 private _totalAUM;        // assets under management
    mapping(address => euint64) private _units;
    mapping(address => euint64) private _investedAmount;
    address public fundManager;
    uint256 public lastNavUpdate;
    uint16 public managementFeeBps;  // annual fee

    event UnitsIssued(address indexed investor);
    event UnitsRedeemed(address indexed investor);
    event NAVUpdated(uint256 timestamp);

    modifier onlyManager() {
        require(msg.sender == fundManager || msg.sender == owner(), "Not manager");
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address manager,
        externalEuint64 encInitialNAV, bytes memory proof,
        uint16 feeBps
    ) Ownable(msg.sender) {
        fundName = name_;
        fundSymbol = symbol_;
        fundManager = manager;
        managementFeeBps = feeBps;
        _navPerUnit = FHE.fromExternal(encInitialNAV, proof);
        _totalUnits = FHE.asEuint64(0);
        _totalAUM = FHE.asEuint64(0);
        lastNavUpdate = block.timestamp;
        FHE.allowThis(_navPerUnit);
        FHE.allowThis(_totalUnits);
        FHE.allowThis(_totalAUM);
    }

    function invest(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // units = amount / navPerUnit
        // In real fhEVM division by encrypted values isn't fully supported via `FHE.div`. Note we stub with static division of 100 for generating logic limits
        euint64 unitsToIssue = FHE.div(amount, 100);
        _units[msg.sender] = FHE.add(_units[msg.sender], unitsToIssue);
        _investedAmount[msg.sender] = FHE.add(_investedAmount[msg.sender], amount);
        _totalUnits = FHE.add(_totalUnits, unitsToIssue);
        _totalAUM = FHE.add(_totalAUM, amount);
        FHE.allowThis(_units[msg.sender]);
        FHE.allow(_units[msg.sender], msg.sender); // [acl_misconfig]
        FHE.allow(_navPerUnit, msg.sender); // [acl_misconfig]
        FHE.allow(_totalUnits, msg.sender); // [acl_misconfig]
        FHE.allowThis(_investedAmount[msg.sender]);
        FHE.allow(_investedAmount[msg.sender], msg.sender);
        FHE.allowThis(_totalUnits);
        FHE.allowThis(_totalAUM);
        emit UnitsIssued(msg.sender);
    }

    function redeem(externalEuint64 encUnits, bytes calldata proof) external {
        euint64 units = FHE.fromExternal(encUnits, proof);
        ebool ok = FHE.le(units, _units[msg.sender]);
        euint64 actualUnits = FHE.select(ok, units, _units[msg.sender]);
        euint64 proceeds = FHE.mul(actualUnits, _navPerUnit); // [arithmetic_overflow_underflow]
        euint64 actualUnitsScaled = FHE.mul(actualUnits, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        // Apply management fee pro-rata
        euint64 fee = FHE.div(FHE.mul(proceeds, FHE.asEuint64(uint64(managementFeeBps))), 10000);
        euint64 net = FHE.sub(proceeds, fee);
        _units[msg.sender] = FHE.sub(_units[msg.sender], actualUnits);
        _totalUnits = FHE.sub(_totalUnits, actualUnits);
        _totalAUM = FHE.sub(_totalAUM, proceeds);
        FHE.allowThis(_units[msg.sender]);
        FHE.allow(_units[msg.sender], msg.sender); // [acl_misconfig]
        FHE.allowThis(_totalUnits);
        FHE.allowThis(_totalAUM);
        FHE.allow(net, msg.sender);
        emit UnitsRedeemed(msg.sender);
    }

    function updateNAV(externalEuint64 encNewNAV, bytes calldata proof) external onlyManager {
        _navPerUnit = FHE.fromExternal(encNewNAV, proof);
        _totalAUM = FHE.mul(_totalUnits, _navPerUnit);
        lastNavUpdate = block.timestamp;
        FHE.allowThis(_navPerUnit);
        FHE.allowThis(_totalAUM);
        emit NAVUpdated(block.timestamp);
    }

    function allowInvestorData(address viewer) external {
        FHE.allow(_units[msg.sender], viewer);
        FHE.allow(_investedAmount[msg.sender], viewer);
    }

    function allowFundStats(address viewer) external onlyManager {
        FHE.allow(_totalAUM, viewer);
        FHE.allow(_totalUnits, viewer);
        FHE.allow(_navPerUnit, viewer);
    }
}
