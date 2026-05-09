// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract IdentityKYC_b2_004 is ZamaEthereumConfig {
    mapping(address => ebool) private kycStatus;
    address public kycProvider;

    constructor() {
        kycProvider = msg.sender;
    }

    function setKYC(address user, externalEbool kycFlag, bytes calldata inputProof) public {
        require(msg.sender == kycProvider, "Not authorized");
        ebool status = FHE.fromExternal(kycFlag, inputProof);
        kycStatus[user] = status;
        FHE.allowThis(kycStatus[user]);
    }

    function checkActionAllowed(address user) public view returns (ebool) {
        return kycStatus[user];
    }
}
