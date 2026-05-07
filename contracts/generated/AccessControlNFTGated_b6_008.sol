// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title AccessControlNFTGated_b6_008 - NFT-gated access with encrypted proof of ownership
contract AccessControlNFTGated_b6_008 is ZamaEthereumConfig {
    address public admin;
    address public nftContract;

    mapping(address => ebool) private verifiedHolders;
    mapping(address => euint8) private accessGrade;
    mapping(string => bool) public restrictedContent;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(address _nftContract) {
        admin = msg.sender;
        nftContract = _nftContract;
    }

    function verifyHolder(address holder, uint8 grade) public onlyAdmin {
        verifiedHolders[holder] = FHE.asEbool(true);
        accessGrade[holder] = FHE.asEuint8(grade);
        FHE.allowThis(verifiedHolders[holder]);
        FHE.allowThis(accessGrade[holder]);
        FHE.allow(verifiedHolders[holder], holder);
        FHE.allow(accessGrade[holder], holder);
    }

    function revokeHolder(address holder) public onlyAdmin {
        verifiedHolders[holder] = FHE.asEbool(false);
        accessGrade[holder] = FHE.asEuint8(0);
        FHE.allowThis(verifiedHolders[holder]);
        FHE.allowThis(accessGrade[holder]);
    }

    function addRestrictedContent(string calldata contentId) public onlyAdmin {
        restrictedContent[contentId] = true;
    }

    function checkContentAccess(address user, uint8 requiredGrade) public returns (ebool) {
        ebool isVerified = verifiedHolders[user];
        ebool gradeOk = FHE.ge(accessGrade[user], FHE.asEuint8(requiredGrade));
        ebool canAccess = FHE.and(isVerified, gradeOk);
        FHE.allow(canAccess, user);
        FHE.allowThis(canAccess);
        return canAccess;
    }

    function allowHolderInfo(address holder, address viewer) public onlyAdmin {
        FHE.allow(verifiedHolders[holder], viewer);
        FHE.allow(accessGrade[holder], viewer);
    }
}
