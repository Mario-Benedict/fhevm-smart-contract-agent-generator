// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SilverLeafToken - Confidential ERC20 with transfer fee and mint cap
contract SilverLeafToken is ZamaEthereumConfig, Ownable {
    string public constant name = "SilverLeaf";
    string public constant symbol = "SLF";
    uint8 public constant decimals = 18;

    mapping(address => euint64) private _balances;
    euint64 private _totalSupply;
    uint64 public constant MAX_SUPPLY = 21_000_000e6;
    uint16 public feeBps = 50; // 0.5%
    address public feeRecipient;
    bool public paused;

    event Transfer(address indexed from, address indexed to);
    event Mint(address indexed to);

    constructor(address _feeRecipient) Ownable(msg.sender) {
        feeRecipient = _feeRecipient;
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
    }

    modifier notPaused() {
        require(!paused, "Paused");
        _;
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata inputProof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allowThis(_totalSupply);
        FHE.allow(_balances[to], to);
        emit Mint(to);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata inputProof) external notPaused {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        euint64 fee = FHE.div(FHE.mul(amount, FHE.asEuint64(uint64(feeBps))), 10000);
        euint64 netAmount = FHE.sub(amount, fee);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], amount);
        _balances[to] = FHE.add(_balances[to], netAmount);
        _balances[feeRecipient] = FHE.add(_balances[feeRecipient], fee);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allowThis(_balances[feeRecipient]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[to], to);
        FHE.allow(_balances[feeRecipient], feeRecipient);
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    function setFeeBps(uint16 _feeBps) external onlyOwner {
        require(_feeBps <= 1000, "Max 10%");
        feeBps = _feeBps;
    }
}
