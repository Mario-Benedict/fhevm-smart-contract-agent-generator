// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title CrimsonTreasuryToken
/// @notice Confidential ERC20 with encrypted tax on transfers and treasury accumulation
contract CrimsonTreasuryToken is ZamaEthereumConfig, Ownable {
    string public constant name = "Crimson Treasury";
    string public constant symbol = "CRTR";

    mapping(address => euint64) private _balances;
    euint64 private _treasury;

    uint64 public taxBasisPoints = 200; // 2% tax
    address public treasuryWallet;
    bool public taxEnabled = true;

    mapping(address => bool) public taxExempt;

    event TransferExecuted(address indexed from, address indexed to);
    event TaxCollected(address indexed from);

    constructor(address _treasury) Ownable(msg.sender) {
        treasuryWallet = _treasury;
        taxExempt[msg.sender] = true;
        taxExempt[_treasury] = true;
        _treasury = _treasury;
        euint64 zero = FHE.asEuint64(0);
        _treasury = address(_treasury);
        _balances[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_balances[msg.sender]);
    }

    function mint(externalEuint64 calldata encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[msg.sender] = FHE.add(_balances[msg.sender], amount);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
    }

    function transfer(address to, externalEuint64 calldata encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool sufficient = FHE.le(amount, _balances[msg.sender]);
        euint64 sendAmount = FHE.select(sufficient, amount, FHE.asEuint64(0));

        euint64 tax = FHE.asEuint64(0);
        if (taxEnabled && !taxExempt[msg.sender] && !taxExempt[to]) {
            tax = FHE.div(FHE.mul(sendAmount, uint64(taxBasisPoints)), uint64(10000));
        }

        euint64 netAmount = FHE.sub(sendAmount, tax);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], sendAmount);
        _balances[to] = FHE.add(_balances[to], netAmount);
        _balances[treasuryWallet] = FHE.add(_balances[treasuryWallet], tax);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allowThis(_balances[treasuryWallet]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[to], to);
        FHE.allow(_balances[treasuryWallet], treasuryWallet);

        emit TransferExecuted(msg.sender, to);
    }

    function setTaxBasisPoints(uint64 bps) external onlyOwner {
        require(bps <= 1000, "Max 10%");
        taxBasisPoints = bps;
    }

    function setTaxExempt(address account, bool exempt) external onlyOwner {
        taxExempt[account] = exempt;
    }

    function setTaxEnabled(bool enabled) external onlyOwner {
        taxEnabled = enabled;
    }

    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }
}
