// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract OpaqueDividendDistributor is ZamaEthereumConfig, Ownable {
    IERC20 public immutable yieldToken;
    
    mapping(address => euint64) private encryptedShares;
    mapping(address => uint256) private lastClaimedEpoch;
    
    uint64 public totalPlaintextShares;
    uint256 public currentEpoch;
    mapping(uint256 => uint64) public epochTotalYield;

    constructor(address _yieldToken) Ownable(msg.sender) {
        yieldToken = IERC20(_yieldToken);
        totalPlaintextShares = 0;
        currentEpoch = 1;
    }

    function issueEncryptedShares(
        address shareholder,
        uint64 plaintextShareCount,
        externalEuint64 memory extShares,
        bytes calldata proof
    ) external onlyOwner {
        euint64 shares = FHE.fromExternal(extShares, proof);
        FHE.allowThis(shares);

        // Verify the hidden share matches the plaintext share increment for public divisor math
        FHE.req(FHE.eq(shares, FHE.asEuint64(plaintextShareCount)));

        if (!FHE.isInitialized(encryptedShares[shareholder])) {
            encryptedShares[shareholder] = FHE.asEuint64(0);
            FHE.allowThis(encryptedShares[shareholder]);
            lastClaimedEpoch[shareholder] = currentEpoch;
        }

        encryptedShares[shareholder] = FHE.add(encryptedShares[shareholder], shares);
        FHE.allowThis(encryptedShares[shareholder]);
        
        totalPlaintextShares += plaintextShareCount;
    }

    function depositYield(uint64 yieldAmount) external {
        require(totalPlaintextShares > 0, "No shares issued");
        require(yieldToken.transferFrom(msg.sender, address(this), yieldAmount), "Yield transfer failed");
        
        epochTotalYield[currentEpoch] = yieldAmount;
        currentEpoch++;
    }

    function claimOpaqueDividends() external {
        require(FHE.isInitialized(encryptedShares[msg.sender]), "No shares");
        
        uint256 startEpoch = lastClaimedEpoch[msg.sender];
        require(startEpoch < currentEpoch, "No new dividends");

        euint64 userShares = encryptedShares[msg.sender];
        euint64 totalOwed = FHE.asEuint64(0);
        FHE.allowThis(totalOwed);

        // Calculate owed dividend opaquely across unclaimed epochs
        for (uint256 i = startEpoch; i < currentEpoch; i++) {
            uint64 epochYield = epochTotalYield[i];
            euint64 encEpochYield = FHE.asEuint64(epochYield);
            
            // Formula: (UserShares * EpochYield) / TotalShares (plaintext divisor)
            euint64 epochOwed = FHE.div(FHE.mul(userShares, encEpochYield), totalPlaintextShares);
            FHE.allowThis(epochOwed);
            
            totalOwed = FHE.add(totalOwed, epochOwed);
            FHE.allowThis(totalOwed);
        }

        lastClaimedEpoch[msg.sender] = currentEpoch;

        uint64 decryptedPayout = FHE.decrypt(totalOwed);
        if (decryptedPayout > 0) {
            require(yieldToken.transfer(msg.sender, decryptedPayout), "Payout failed");
        }
    }
}