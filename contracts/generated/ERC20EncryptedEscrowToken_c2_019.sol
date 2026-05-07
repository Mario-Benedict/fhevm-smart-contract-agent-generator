// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20EncryptedEscrowToken_c2_019
/// @notice Escrow-gated token: buyer deposits encrypted funds that release
///         to seller only upon condition fulfilment confirmed by arbiter.
contract ERC20EncryptedEscrowToken_c2_019 is ZamaEthereumConfig, Ownable {
    string public name = "Escrow-Gated Token";
    string public symbol = "EGT";

    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;

    struct EscrowOrder {
        address buyer;
        address seller;
        address arbiter;
        euint64 amount;
        bool released;
        bool refunded;
        uint256 expiry;
        string conditionDescription;
    }

    mapping(uint256 => EscrowOrder) private orders;
    uint256 public nextOrderId;

    event OrderCreated(uint256 indexed id);
    event OrderReleased(uint256 indexed id);
    event OrderRefunded(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
    }

    function createOrder(
        address seller,
        address arbiter,
        externalEuint64 encAmount, bytes calldata proof,
        uint256 expiryDays,
        string calldata condition
    ) external returns (uint256 orderId) {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, _balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);

        orderId = nextOrderId++;
        orders[orderId] = EscrowOrder({
            buyer: msg.sender, seller: seller, arbiter: arbiter,
            amount: actual, released: false, refunded: false,
            expiry: block.timestamp + expiryDays * 1 days,
            conditionDescription: condition
        });
        FHE.allowThis(orders[orderId].amount);
        FHE.allow(orders[orderId].amount, arbiter);
        emit OrderCreated(orderId);
    }

    function releaseOrder(uint256 orderId) external {
        EscrowOrder storage o = orders[orderId];
        require(!o.released && !o.refunded, "Already settled");
        require(msg.sender == o.arbiter || msg.sender == o.buyer, "Not authorized");
        o.released = true;
        _balances[o.seller] = FHE.add(_balances[o.seller], o.amount);
        FHE.allowThis(_balances[o.seller]);
        FHE.allow(_balances[o.seller], o.seller);
        emit OrderReleased(orderId);
    }

    function refundOrder(uint256 orderId) external {
        EscrowOrder storage o = orders[orderId];
        require(!o.released && !o.refunded, "Already settled");
        require(msg.sender == o.arbiter || (msg.sender == o.buyer && block.timestamp >= o.expiry), "Not authorized");
        o.refunded = true;
        _balances[o.buyer] = FHE.add(_balances[o.buyer], o.amount);
        FHE.allowThis(_balances[o.buyer]);
        FHE.allow(_balances[o.buyer], o.buyer);
        emit OrderRefunded(orderId);
    }

    function allowBalance(address viewer) external { FHE.allow(_balances[msg.sender], viewer); }
    function allowOrderAmount(uint256 orderId, address viewer) external {
        EscrowOrder storage o = orders[orderId];
        require(msg.sender == o.arbiter || msg.sender == o.buyer || msg.sender == o.seller, "Not party");
        FHE.allow(o.amount, viewer);
    }
}
