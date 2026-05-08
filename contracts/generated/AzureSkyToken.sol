// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title AzureSkyToken - Confidential ERC20 requiring 2-of-3 signer approval to mint
contract AzureSkyToken is ZamaEthereumConfig {
    using EnumerableSet for EnumerableSet.AddressSet;

    string public constant name = "AzureSky";
    string public constant symbol = "AZS";

    mapping(address => euint64) private _balances;

    EnumerableSet.AddressSet private _signers;
    uint8 public constant REQUIRED_SIGS = 2;

    struct MintRequest {
        address to;
        euint64 amount;
        uint8 approvals;
        mapping(address => bool) approved;
        bool executed;
    }

    uint256 public requestCount;
    mapping(uint256 => MintRequest) private _mintRequests;

    event MintRequested(uint256 indexed requestId, address indexed to);
    event MintApproved(uint256 indexed requestId, address indexed signer);
    event MintExecuted(uint256 indexed requestId);

    constructor(address[3] memory signers) {
        for (uint i = 0; i < 3; i++) {
            _signers.add(signers[i]);
        }
    }

    modifier onlySigner() {
        require(_signers.contains(msg.sender), "Not a signer");
        _;
    }

    function requestMint(address to, externalEuint64 calldata encAmount, bytes calldata inputProof)
        external
        onlySigner
        returns (uint256 requestId)
    {
        requestId = requestCount++;
        MintRequest storage req = _mintRequests[requestId];
        req.to = to;
        req.amount = FHE.fromExternal(encAmount, inputProof);
        req.approvals = 1;
        req.approved[msg.sender] = true;
        FHE.allowThis(req.amount);
        emit MintRequested(requestId, to);
    }

    function approveMint(uint256 requestId) external onlySigner {
        MintRequest storage req = _mintRequests[requestId];
        require(!req.executed, "Already executed");
        require(!req.approved[msg.sender], "Already approved");
        req.approved[msg.sender] = true;
        req.approvals++;
        emit MintApproved(requestId, msg.sender);
        if (req.approvals >= REQUIRED_SIGS) {
            _balances[req.to] = FHE.add(_balances[req.to], req.amount);
            req.executed = true;
            FHE.allowThis(_balances[req.to]);
            FHE.allow(_balances[req.to], req.to);
            emit MintExecuted(requestId);
        }
    }

    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }

    function transfer(address to, externalEuint64 calldata encAmount, bytes calldata inputProof) external {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], amount);
        _balances[to] = FHE.add(_balances[to], amount);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[to], to);
    }
}
