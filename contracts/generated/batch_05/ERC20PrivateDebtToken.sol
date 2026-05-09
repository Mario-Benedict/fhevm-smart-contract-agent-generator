// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20PrivateDebtToken
/// @notice Tokenized debt instrument. Principal is encrypted, interest accrues in encrypted form.
///         Maturity date is public; debt holders can redeem at maturity for principal + interest.
contract ERC20PrivateDebtToken is ZamaEthereumConfig, Ownable {
    string public name = "Private Debt Token";
    string public symbol = "PDT";
    uint8 public decimals = 18;

    struct DebtPosition {
        euint64 principal;
        euint64 interestRateBps; // annual
        euint64 accruedInterest;
        uint256 issuedAt;
        uint256 maturityDate;
        bool redeemed;
    }

    mapping(address => DebtPosition) private positions;
    euint64 private _totalIssuance;
    mapping(address => euint64) private _balances;
    address[] public debtHolders;

    event DebtIssued(address indexed holder, uint256 maturity);
    event DebtRedeemed(address indexed holder);

    constructor() Ownable(msg.sender) {
        _totalIssuance = FHE.asEuint64(0);
        FHE.allowThis(_totalIssuance);
    }

    function issueDebt(
        address holder,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encRate, bytes calldata rProof,
        uint256 maturityDays
    ) external onlyOwner {
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 rate = FHE.fromExternal(encRate, rProof);
        positions[holder] = DebtPosition({
            principal: principal,
            interestRateBps: rate,
            accruedInterest: FHE.asEuint64(0),
            issuedAt: block.timestamp,
            maturityDate: block.timestamp + maturityDays * 1 days,
            redeemed: false
        });
        _balances[holder] = FHE.add(_balances[holder], principal);
        _totalIssuance = FHE.add(_totalIssuance, principal);
        FHE.allowThis(positions[holder].principal);
        FHE.allow(positions[holder].principal, holder);
        FHE.allowThis(positions[holder].interestRateBps);
        FHE.allowThis(positions[holder].accruedInterest);
        FHE.allow(positions[holder].accruedInterest, holder);
        FHE.allowThis(_balances[holder]);
        FHE.allow(_balances[holder], holder);
        FHE.allowThis(_totalIssuance);
        debtHolders.push(holder);
        emit DebtIssued(holder, block.timestamp + maturityDays * 1 days);
    }

    function accrueInterest(address holder) external {
        DebtPosition storage dp = positions[holder];
        require(!dp.redeemed, "Redeemed");
        uint256 yearsElapsed = (block.timestamp - dp.issuedAt) / 365 days;
        if (yearsElapsed == 0) return;
        euint64 interest = FHE.div(
            FHE.mul(FHE.mul(dp.principal, dp.interestRateBps), FHE.asEuint64(uint64(yearsElapsed))),
            10000
        );
        dp.accruedInterest = FHE.add(dp.accruedInterest, interest);
        FHE.allowThis(dp.accruedInterest);
        FHE.allow(dp.accruedInterest, holder);
    }

    function redeem() external {
        DebtPosition storage dp = positions[msg.sender];
        require(!dp.redeemed, "Redeemed");
        require(block.timestamp >= dp.maturityDate, "Not matured");
        euint64 total = FHE.add(dp.principal, dp.accruedInterest);
        dp.redeemed = true;
        _balances[msg.sender] = FHE.asEuint64(0);
        FHE.allow(total, msg.sender);
        FHE.allowThis(_balances[msg.sender]);
        emit DebtRedeemed(msg.sender);
    }

    function allowPosition(address viewer) external {
        FHE.allow(positions[msg.sender].principal, viewer);
        FHE.allow(positions[msg.sender].accruedInterest, viewer);
    }

    function isMatured(address holder) external view returns (bool) {
        return block.timestamp >= positions[holder].maturityDate;
    }
}
