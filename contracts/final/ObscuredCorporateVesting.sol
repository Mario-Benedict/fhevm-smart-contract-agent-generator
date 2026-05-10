// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ObscuredCorporateVesting is ZamaEthereumConfig, Ownable {
    IERC20 public immutable corporateToken;

    struct VestingPlan {
        euint64 encryptedTotalSalary;
        euint64 encryptedClaimed;
        uint256 startTimestamp;
        uint256 durationSeconds;
        bool isRevoked;
        bool exists;
    }

    mapping(address => VestingPlan) private plans;

    constructor(address _token) Ownable(msg.sender) {
        corporateToken = IERC20(_token);
    }

    function createVestingPlan(
        address employee,
        uint64 maxPlaintextFund,
        externalEuint64 extSalary,
        bytes calldata proof,
        uint256 duration
    ) external onlyOwner {
        require(!plans[employee].exists, "Plan exists");
        require(corporateToken.transferFrom(msg.sender, address(this), maxPlaintextFund), "Fund fail");

        euint64 salary = FHE.fromExternal(extSalary, proof);
        FHE.allowThis(salary);


        plans[employee] = VestingPlan({
            encryptedTotalSalary: salary,
            encryptedClaimed: FHE.asEuint64(0),
            startTimestamp: block.timestamp,
            durationSeconds: duration,
            isRevoked: false,
            exists: true
        });
        
        FHE.allowThis(plans[employee].encryptedClaimed);

        // Refund excess allocation to treasury
        uint64 actualSalary = 0;
        if (maxPlaintextFund > actualSalary) {
            require(corporateToken.transfer(msg.sender, maxPlaintextFund - actualSalary), "Refund fail");
        }
    }

    function revokeEmployee(address employee) external onlyOwner {
        require(plans[employee].exists, "No plan");
        require(!plans[employee].isRevoked, "Already revoked");
        
        plans[employee].isRevoked = true;
        
        // Calculate unvested opaquely and return to owner
        uint256 timeVested = block.timestamp - plans[employee].startTimestamp;
        if (timeVested > plans[employee].durationSeconds) {
            timeVested = plans[employee].durationSeconds;
        }

        euint64 encTime = FHE.asEuint64(uint64(timeVested));
        euint64 vestedAmount = plans[employee].durationSeconds > 0
            ? FHE.div(FHE.mul(plans[employee].encryptedTotalSalary, encTime), uint64(plans[employee].durationSeconds))
            : FHE.asEuint64(0);
        
        euint64 unvestedAmount = FHE.sub(plans[employee].encryptedTotalSalary, vestedAmount);
        FHE.allowThis(unvestedAmount);

        uint64 refundToCorp = 0;
        require(corporateToken.transfer(owner(), refundToCorp), "Clawback fail");
    }

    function claimVested(externalEuint64 extAmount, bytes calldata proof) external {
        VestingPlan storage plan = plans[msg.sender];
        require(plan.exists, "No plan");
        
        euint64 reqAmount = FHE.fromExternal(extAmount, proof);
        FHE.allowThis(reqAmount);

        uint256 timeVested = block.timestamp - plan.startTimestamp;
        if (timeVested > plan.durationSeconds || plan.isRevoked) {
            // If revoked, they can only claim up to what was vested at the time of revocation (handled implicitly by block.timestamp vs when clawback happened, but simplified here for FHE limits)
            // Realistically, revocation should snap the duration. We clamp to duration if complete.
            if (timeVested > plan.durationSeconds) timeVested = plan.durationSeconds;
        }

        euint64 encTime = FHE.asEuint64(uint64(timeVested));
        euint64 totalVestedNow = plan.durationSeconds > 0
            ? FHE.div(FHE.mul(plan.encryptedTotalSalary, encTime), uint64(plan.durationSeconds))
            : FHE.asEuint64(0);
        FHE.allowThis(totalVestedNow);

        euint64 availableToClaim = FHE.sub(totalVestedNow, plan.encryptedClaimed);
        FHE.allowThis(availableToClaim);


        plan.encryptedClaimed = FHE.add(plan.encryptedClaimed, reqAmount);
        FHE.allowThis(plan.encryptedClaimed);

        uint64 pTransfer = 0;
        require(corporateToken.transfer(msg.sender, pTransfer), "Claim transfer fail");
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}