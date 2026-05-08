// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VeiledOptionsClearing is ZamaEthereumConfig {
    IERC20 public immutable settlementToken;

    struct EuropeanOption {
        euint64 encryptedStrikePrice;
        euint64 encryptedContractSize;
        address writer;
        address buyer;
        uint256 expiration;
        bool isExercised;
    }

    mapping(bytes32 => EuropeanOption) public options;
    uint256 private optionIdCounter;

    constructor(address _settlementToken) {
        settlementToken = IERC20(_settlementToken);
    }

    function writeCoveredCall(
        uint64 plaintextPremium,
        uint64 maxPlaintextCollateral,
        externalEuint64 memory extStrike,
        externalEuint64 memory extSize,
        bytes calldata proofStrike,
        bytes calldata proofSize,
        address buyer,
        uint256 durationDays
    ) external returns (bytes32) {
        require(settlementToken.transferFrom(msg.sender, address(this), maxPlaintextCollateral), "Collateral fail");

        euint64 strike = FHE.fromExternal(extStrike, proofStrike);
        euint64 size = FHE.fromExternal(extSize, proofSize);
        FHE.allowThis(strike);
        FHE.allowThis(size);

        // Ensure written size is fully collateralized by the max commitment
        FHE.req(FHE.le(size, FHE.asEuint64(maxPlaintextCollateral)));

        bytes32 optionId = keccak256(abi.encodePacked(msg.sender, buyer, optionIdCounter++));
        
        options[optionId] = EuropeanOption({
            encryptedStrikePrice: strike,
            encryptedContractSize: size,
            writer: msg.sender,
            buyer: buyer,
            expiration: block.timestamp + (durationDays * 1 days),
            isExercised: false
        });

        // Writer receives plaintext premium instantly from buyer
        require(settlementToken.transferFrom(buyer, msg.sender, plaintextPremium), "Premium fail");

        // Refund excess collateral not locked by the hidden size
        uint64 actualSizeLocked = FHE.decrypt(size);
        uint64 refund = maxPlaintextCollateral - actualSizeLocked;
        if (refund > 0) {
            require(settlementToken.transfer(msg.sender, refund), "Refund fail");
        }

        return optionId;
    }

    function exerciseOption(
        bytes32 optionId,
        uint64 maxPlaintextExerciseCost,
        externalEuint64 memory extSpotPrice,
        bytes calldata proofSpot
    ) external {
        EuropeanOption storage opt = options[optionId];
        require(msg.sender == opt.buyer, "Not buyer");
        require(block.timestamp >= opt.expiration, "Not expired");
        require(!opt.isExercised, "Already exercised");

        euint64 spotPrice = FHE.fromExternal(extSpotPrice, proofSpot);
        FHE.allowThis(spotPrice);

        // Transfer max exercise capital to escrow
        require(settlementToken.transferFrom(msg.sender, address(this), maxPlaintextExerciseCost), "Exercise capital fail");

        // Option only in the money if Spot > Strike
        ebool inTheMoney = FHE.gt(spotPrice, opt.encryptedStrikePrice);
        FHE.req(inTheMoney); // Silently reverts if out of the money

        // Cost to exercise = ContractSize * StrikePrice
        euint64 exerciseCost = FHE.mul(opt.encryptedContractSize, opt.encryptedStrikePrice);
        FHE.allowThis(exerciseCost);

        // Ensure provided capital covers exercise cost
        FHE.req(FHE.le(exerciseCost, FHE.asEuint64(maxPlaintextExerciseCost)));

        opt.isExercised = true;

        uint64 actualCost = FHE.decrypt(exerciseCost);
        uint64 actualSize = FHE.decrypt(opt.encryptedContractSize);
        uint64 refund = maxPlaintextExerciseCost - actualCost;

        // Transfer strike cost to writer
        require(settlementToken.transfer(opt.writer, actualCost), "Writer payment fail");
        // Transfer underlying collateral size to buyer
        require(settlementToken.transfer(opt.buyer, actualSize), "Underlying delivery fail");
        
        if (refund > 0) {
            require(settlementToken.transfer(msg.sender, refund), "Buyer refund fail");
        }
    }
}