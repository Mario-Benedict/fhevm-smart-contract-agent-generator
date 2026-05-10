// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title NightOwlStablecoin
/// @notice Confidential stablecoin with multi-role minting and burn-on-redeem mechanics
contract NightOwlStablecoin is ZamaEthereumConfig, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    string public constant name = "NightOwl Stablecoin";
    string public constant symbol = "NOWL";

    mapping(address => euint32) private _balances;
    euint32 private _totalMinted;
    euint32 private _totalBurned;

    mapping(address => uint256) public lastMintTime;
    uint256 public constant MINT_COOLDOWN = 1 hours;

    event Minted(address indexed to);
    event Burned(address indexed from);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        _totalMinted = FHE.asEuint32(0);
        _totalBurned = FHE.asEuint32(0);
        FHE.allowThis(_totalMinted);
        FHE.allowThis(_totalBurned);
    }

    function mint(address to, externalEuint32 encAmount, bytes calldata proof)
        external
        onlyRole(MINTER_ROLE)
    {
        require(block.timestamp >= lastMintTime[to] + MINT_COOLDOWN, "Cooldown active");
        euint32 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalMinted = FHE.add(_totalMinted, amount);
        lastMintTime[to] = block.timestamp;

        FHE.allowThis(_balances[to]);
        FHE.allowThis(_totalMinted);
        FHE.allow(_balances[to], to);
        emit Minted(to);
    }

    function burn(address from, externalEuint32 encAmount, bytes calldata proof)
        external
        onlyRole(BURNER_ROLE)
    {
        euint32 amount = FHE.fromExternal(encAmount, proof);
        ebool sufficient = FHE.ge(_balances[from], amount);
        euint32 actualBurn = FHE.select(sufficient, amount, FHE.asEuint32(0));
        _balances[from] = FHE.sub(_balances[from], actualBurn);
        _totalBurned = FHE.add(_totalBurned, actualBurn);

        FHE.allowThis(_balances[from]);
        FHE.allowThis(_totalBurned);
        FHE.allow(_balances[from], from);
        emit Burned(from);
    }

    function transfer(address to, externalEuint32 encAmount, bytes calldata proof) external {
        euint32 amount = FHE.fromExternal(encAmount, proof);
        ebool canSend = FHE.le(amount, _balances[msg.sender]);
        euint32 send = FHE.select(canSend, amount, FHE.asEuint32(0));

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], send);
        _balances[to] = FHE.add(_balances[to], send);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[to], to);
    }

    function balanceOf(address account) external view returns (euint32) {
        return _balances[account];
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