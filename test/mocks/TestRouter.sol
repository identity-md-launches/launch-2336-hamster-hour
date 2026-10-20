// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Pre-funded local test router. It settles only its own assets and exposes resulting deltas.
contract TestRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData) public returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(true, key, abi.encode(params, hookData))), (BalanceDelta));
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params) public returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(false, key, abi.encode(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (bool isSwap, PoolKey memory key, bytes memory action) = abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta delta;
        if (isSwap) {
            (SwapParams memory params, bytes memory hookData) = abi.decode(action, (SwapParams, bytes));
            delta = manager.swap(key, params, hookData);
        } else {
            ModifyLiquidityParams memory params = abi.decode(action, (ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(amount))));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(int256(amount)));
        }
    }
}
