// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract MaskedFeeRouter is ZamaEthereumConfig {
    address public poolLowFee;  // 0.05%
    address public poolHighFee; // 0.3%

    struct RoutingPref {
        ebool prefersLowFee;
        bool isSet;
    }

    mapping(address => RoutingPref) private prefs;

    constructor(address _low, address _high) {
        poolLowFee = _low;
        poolHighFee = _high;
    }

    function setRoutingPreference(externalEbool memory extPref, bytes calldata proof) external {
        ebool pref = FHE.fromExternal(extPref, proof);
        FHE.allowThis(pref);
        prefs[msg.sender] = RoutingPref(pref, true);
    }

    function getMaskedRoute() external view returns (address) {
        // Since we cannot return an encrypted address, we decrypt the preference at routing time
        // In a fully homomorphic EVM, the entire swap would be routed opaquely.
        require(prefs[msg.sender].isSet, "No pref");
        bool isLow = FHE.decrypt(prefs[msg.sender].prefersLowFee);
        return isLow ? poolLowFee : poolHighFee;
    }
}