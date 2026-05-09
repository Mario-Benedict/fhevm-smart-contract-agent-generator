// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AzureRemittanceToken
/// @notice Cross-border remittance token with encrypted amounts and per-corridor fee structure
contract AzureRemittanceToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Azure Remittance";
    string public constant symbol = "AZRM";

    mapping(address => euint32) private _balances;

    struct Corridor {
        uint32 feeBasisPoints;
        bool active;
    }

    mapping(bytes32 => Corridor) public corridors; // keccak256(fromCountry, toCountry) => Corridor
    mapping(address => bytes2) public userCountry;

    address public feeCollector;
    euint32 private _feePool;

    event RemittanceSent(address indexed sender, address indexed recipient, bytes2 toCountry);
    event CorridorUpdated(bytes2 from, bytes2 to, uint32 fee);

    constructor(address _feeCollector) Ownable(msg.sender) {
        feeCollector = _feeCollector;
        _feePool = FHE.asEuint32(0);
        FHE.allowThis(_feePool);
    }

    function registerCountry(bytes2 country) external {
        userCountry[msg.sender] = country;
    }

    function setCorridor(bytes2 fromCountry, bytes2 toCountry, uint32 feeBps) external onlyOwner {
        bytes32 key = keccak256(abi.encodePacked(fromCountry, toCountry));
        corridors[key] = Corridor(feeBps, true);
        emit CorridorUpdated(fromCountry, toCountry, feeBps);
    }

    function mint(address to, externalEuint32 encAmount, bytes calldata proof) external onlyOwner {
        euint32 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function sendRemittance(
        address recipient,
        externalEuint32 encAmount,
        bytes calldata proof
    ) external nonReentrant {
        euint32 amount = FHE.fromExternal(encAmount, proof);
        bytes2 fromCountry = userCountry[msg.sender];
        bytes2 toCountry = userCountry[recipient];
        bytes32 corridorKey = keccak256(abi.encodePacked(fromCountry, toCountry));
        Corridor memory corridor = corridors[corridorKey];

        euint32 fee = FHE.asEuint32(0);
        if (corridor.active && corridor.feeBasisPoints > 0) {
            fee = FHE.div(FHE.mul(amount, uint32(corridor.feeBasisPoints)), uint32(10000));
        }

        euint32 net = FHE.sub(amount, fee);
        ebool sufficient = FHE.le(amount, _balances[msg.sender]);
        euint32 actualNet = FHE.select(sufficient, net, FHE.asEuint32(0));
        euint32 actualFee = FHE.select(sufficient, fee, FHE.asEuint32(0));

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], FHE.add(actualNet, actualFee));
        _balances[recipient] = FHE.add(_balances[recipient], actualNet);
        _feePool = FHE.add(_feePool, actualFee);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[recipient]);
        FHE.allowThis(_feePool);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[recipient], recipient);

        emit RemittanceSent(msg.sender, recipient, toCountry);
    }

    function withdrawFees() external {
        require(msg.sender == feeCollector, "Not fee collector");
        _balances[feeCollector] = FHE.add(_balances[feeCollector], _feePool);
        _feePool = FHE.asEuint32(0);
        FHE.allowThis(_feePool);
        FHE.allowThis(_balances[feeCollector]);
        FHE.allow(_balances[feeCollector], feeCollector);
    }

    function balanceOf(address account) external view returns (euint32) {
        return _balances[account];
    }
}
