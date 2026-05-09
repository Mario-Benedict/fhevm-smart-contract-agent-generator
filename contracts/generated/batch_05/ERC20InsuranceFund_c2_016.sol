// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20InsuranceFund_c2_016
/// @notice Insurance fund token: contributors earn shares; claims are processed
///         with encrypted payouts decided by an underwriter.
contract ERC20InsuranceFund_c2_016 is ZamaEthereumConfig, Ownable {
    string public name = "Insurance Fund Share";
    string public symbol = "IFS";

    address public underwriter;
    euint64 private _fundReserve;
    euint64 private _totalShares;
    mapping(address => euint64) private _shares;
    mapping(address => euint64) private _premiumsPaid;

    struct Claim {
        address claimant;
        euint64 requestedAmount;
        euint64 approvedAmount;
        bool processed;
    }

    Claim[] public claims;

    event ContributionReceived(address indexed contributor);
    event ClaimSubmitted(uint256 indexed claimId);
    event ClaimProcessed(uint256 indexed claimId, bool approved);

    modifier onlyUnderwriter() {
        require(msg.sender == underwriter, "Not underwriter");
        _;
    }

    constructor(address _underwriter) Ownable(msg.sender) {
        underwriter = _underwriter;
        _fundReserve = FHE.asEuint64(0);
        _totalShares = FHE.asEuint64(0);
        FHE.allowThis(_fundReserve);
        FHE.allowThis(_totalShares);
    }

    function contribute(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 newShares = amount; // 1:1 simplified
        _shares[msg.sender] = FHE.add(_shares[msg.sender], newShares);
        _premiumsPaid[msg.sender] = FHE.add(_premiumsPaid[msg.sender], amount);
        _fundReserve = FHE.add(_fundReserve, amount);
        _totalShares = FHE.add(_totalShares, newShares);
        FHE.allowThis(_shares[msg.sender]);
        FHE.allow(_shares[msg.sender], msg.sender);
        FHE.allowThis(_premiumsPaid[msg.sender]);
        FHE.allow(_premiumsPaid[msg.sender], msg.sender);
        FHE.allowThis(_fundReserve);
        FHE.allowThis(_totalShares);
        emit ContributionReceived(msg.sender);
    }

    function submitClaim(externalEuint64 encAmount, bytes calldata proof) external returns (uint256) {
        euint64 requested = FHE.fromExternal(encAmount, proof);
        uint256 claimId = claims.length;
        claims.push(Claim({
            claimant: msg.sender,
            requestedAmount: requested,
            approvedAmount: FHE.asEuint64(0),
            processed: false
        }));
        FHE.allowThis(claims[claimId].requestedAmount);
        FHE.allow(claims[claimId].requestedAmount, underwriter);
        FHE.allowThis(claims[claimId].approvedAmount);
        emit ClaimSubmitted(claimId);
        return claimId;
    }

    function processClaim(uint256 claimId, externalEuint64 encApproved, bytes calldata proof, bool approve)
        external onlyUnderwriter
    {
        Claim storage c = claims[claimId];
        require(!c.processed, "Already processed");
        c.processed = true;
        if (approve) {
            euint64 approved = FHE.fromExternal(encApproved, proof);
            ebool reserveOk = FHE.ge(_fundReserve, approved);
            euint64 actual = FHE.select(reserveOk, approved, _fundReserve);
            c.approvedAmount = actual;
            _fundReserve = FHE.sub(_fundReserve, actual);
            FHE.allowThis(c.approvedAmount);
            FHE.allow(c.approvedAmount, c.claimant);
            FHE.allowThis(_fundReserve);
        }
        emit ClaimProcessed(claimId, approve);
    }

    function allowFundReserve(address viewer) external onlyOwner {
        FHE.allow(_fundReserve, viewer);
    }

    function allowShares(address viewer) external {
        FHE.allow(_shares[msg.sender], viewer);
    }
}
