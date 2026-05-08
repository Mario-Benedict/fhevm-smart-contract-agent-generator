// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract DarkOTCDesk is ZamaEthereumConfig, ReentrancyGuard {
    struct EncryptedOrder {
        address maker;
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 plaintextAmountIn;
        euint64 encryptedMinAmountOut;
        bool isActive;
    }

    mapping(bytes32 => EncryptedOrder) public orders;
    uint256 public orderNonce;

    function createHiddenOrder(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        externalEuint64 memory extMinOut,
        bytes calldata proofMinOut
    ) external nonReentrant returns (bytes32) {
        require(IERC20(_tokenIn).transferFrom(msg.sender, address(this), _amountIn), "Transfer failed");

        euint64 minOut = FHE.fromExternal(extMinOut, proofMinOut);
        FHE.allowThis(minOut);

        bytes32 orderId = keccak256(abi.encodePacked(msg.sender, block.timestamp, orderNonce++));
        
        orders[orderId] = EncryptedOrder({
            maker: msg.sender,
            tokenIn: IERC20(_tokenIn),
            tokenOut: IERC20(_tokenOut),
            plaintextAmountIn: _amountIn,
            encryptedMinAmountOut: minOut,
            isActive: true
        });

        return orderId;
    }

    function fillHiddenOrder(
        bytes32 orderId,
        externalEuint64 memory extAmountOutOffered,
        bytes calldata proofOffered
    ) external nonReentrant {
        EncryptedOrder storage order = orders[orderId];
        require(order.isActive, "Inactive order");

        euint64 offeredAmount = FHE.fromExternal(extAmountOutOffered, proofOffered);
        FHE.allowThis(offeredAmount);

        ebool meetsRequirement = FHE.ge(offeredAmount, order.encryptedMinAmountOut);
        FHE.req(meetsRequirement);

        order.isActive = false;

        uint64 decryptedOffer = FHE.decrypt(offeredAmount);
        
        require(order.tokenOut.transferFrom(msg.sender, order.maker, decryptedOffer), "TokenOut transfer failed");
        require(order.tokenIn.transfer(msg.sender, order.plaintextAmountIn), "TokenIn transfer failed");
    }
}