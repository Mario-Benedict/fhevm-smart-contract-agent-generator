// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateEscrowToken
/// @notice Token that supports encrypted multi-party escrow with timelock release
contract PrivateEscrowToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "Private Escrow Token";
    string public symbol = "PET";

    struct EscrowAgreement {
        address buyer;
        address seller;
        address arbiter;
        euint64 amount;
        uint256 releaseTime;
        bool released;
        bool disputed;
    }

    mapping(address => euint64) private _balances;
    mapping(uint256 => EscrowAgreement) private _escrows;
    uint256 public escrowCount;

    euint64 private _totalSupply;

    event EscrowCreated(uint256 indexed id, address buyer, address seller);
    event EscrowReleased(uint256 indexed id);
    event EscrowDisputed(uint256 indexed id);
    event EscrowResolved(uint256 indexed id, address winner);

    constructor(uint64 initialSupply) Ownable(msg.sender) {
        _balances[msg.sender] = FHE.asEuint64(uint64(initialSupply));
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        _totalSupply = FHE.asEuint64(uint64(initialSupply));
        FHE.allowThis(_totalSupply);
    }

    function createEscrow(
        address seller,
        address arbiter,
        externalEuint64 encAmount,
        bytes calldata inputProof,
        uint256 lockDuration
    ) external nonReentrant returns (uint256) {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_balances[msg.sender], amount);
        euint64 actual = FHE.select(sufficient, amount, FHE.asEuint64(0));

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);

        uint256 id = ++escrowCount;
        _escrows[id] = EscrowAgreement({
            buyer: msg.sender,
            seller: seller,
            arbiter: arbiter,
            amount: actual,
            releaseTime: block.timestamp + lockDuration,
            released: false,
            disputed: false
        });
        FHE.allowThis(_escrows[id].amount);
        FHE.allow(_escrows[id].amount, seller);
        FHE.allow(_escrows[id].amount, arbiter);

        emit EscrowCreated(id, msg.sender, seller);
        return id;
    }

    function releaseEscrow(uint256 id) external nonReentrant {
        EscrowAgreement storage esc = _escrows[id];
        require(!esc.released, "Already released");
        require(!esc.disputed, "Disputed");
        require(msg.sender == esc.buyer || block.timestamp >= esc.releaseTime, "Not authorized");

        _balances[esc.seller] = FHE.add(_balances[esc.seller], esc.amount);
        FHE.allowThis(_balances[esc.seller]);
        FHE.allow(_balances[esc.seller], esc.seller);

        esc.released = true;
        emit EscrowReleased(id);
    }

    function disputeEscrow(uint256 id) external {
        EscrowAgreement storage esc = _escrows[id];
        require(msg.sender == esc.buyer || msg.sender == esc.seller, "Not party");
        require(!esc.released, "Already released");
        esc.disputed = true;
        emit EscrowDisputed(id);
    }

    function resolveDispute(uint256 id, bool buyerWins) external nonReentrant {
        EscrowAgreement storage esc = _escrows[id];
        require(msg.sender == esc.arbiter, "Not arbiter");
        require(esc.disputed, "Not disputed");
        require(!esc.released, "Already released");

        address winner = buyerWins ? esc.buyer : esc.seller;
        _balances[winner] = FHE.add(_balances[winner], esc.amount);
        FHE.allowThis(_balances[winner]);
        FHE.allow(_balances[winner], winner);

        esc.released = true;
        emit EscrowResolved(id, winner);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata inputProof) external {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_balances[msg.sender], amount);
        euint64 actual = FHE.select(sufficient, amount, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], actual);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata inputProof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
    }

    function balanceOf(address account) external view returns (euint64) { return _balances[account]; }

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