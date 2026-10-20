# Implementation review

This is the implementation author's review against the supplied Ethereum and
Uniswap v4 checklists. It is not an independent audit or launch authorization.

| Area | Implementation / evidence |
| --- | --- |
| Callback origin | All four reachable callbacks require the immutable PoolManager. Direct unauthorized calls are tested. |
| Pool binding | Constructor-derived immutable PoolId covers both currencies, static fee, tick spacing, and hook address. Every lifecycle callback checks it. |
| Initialization | Factory-only, explicit `initialized` boolean, no setter or second start. Timestamp-zero and expired re-arm attempts are tested. |
| Permissions | Exactly `0x20cc`; constructor validates the mined address. No liquidity or donation callbacks and no LP fee override. |
| NoOp exposure | Before-swap deltas contain only the bounded IMD fee. Simulation is self-only and unconditionally reverts. The real AMM provides all HAMSTER execution. |
| Fee bypass | Sender and hookData never grant exemptions. New routers and arbitrary hookData are tested. Other pools cannot use this hook. |
| All modes | Real PoolManager tests cover buys/sells, exact input/output, both currency orderings, full/partial/zero fills, and integer dust. |
| Conservation | Per-trade bucket, event-delta, and claim assertions plus 4,096 stateful calls at the pinned seed. |
| Slippage | Both simulation and execution use the caller's unchanged sqrt-price limit. Routers must still enforce deadlines and net-output/max-input limits. |
| Vault isolation | No vault calls on the swap path. Reverting, absent, no-pull, short-pull, and reentrant vaults are tested. |
| Credit delivery | Permissionless retry, exact approvals, balance checks, atomic rollback, fixed destinations, five bounded iterations. |
| Reentrancy | Public flush guard, self-only delivery helper, manager-only redemption callback with an exact pending amount. Credits debit before interactions. |
| Token behavior | Fixed known IMD; SafeERC20 checks transfers. Nonstandard transfer/rebasing behavior during delivery leaves the credit outstanding. HAMSTER is an ordinary fixed-supply ERC-20. |
| Authority | No owner, pause, fee change, upgrade, arbitrary call, rescue, privileged exemption, or route setter. TEAM only receives payments. |
| Factory liquidity | No hook fees or gating on zero-liquidity fee collection or normal liquidity withdrawal. |
| Supply | Constructor-only 1B mint to factory; tested transfer/allowance flows and absent mint/burn/admin selectors. |
| Bytecode | Runtime below EIP-170; reachable-code scans exclude DELEGATECALL, CALLCODE and SELFDESTRUCT. No external library linking. |
| Offline build | Sources and licenses vendored; compiler version pinned; no FFI or filesystem permissions. |

The timestamp is intentionally used for the requested minute schedule, not
randomness. Validators can influence inclusion around minute boundaries.
Integer division before the minute decrement deliberately implements *full*
minutes. The initial tax and permanent fee sum to 96.1%, below 100% even after
the launch LP fee.

## Checks run

- `forge build` with Solidity 0.8.26.
- `forge test` with the pinned seed: unit/integration tests, 512 fuzz cases,
  and 64 invariant runs of depth 64.
- `forge fmt --check`.
- A separate mainnet-state integration rehearsal at block 26,235,704 using the
  actual IMD and HamsterVault, a fresh local PoolManager, newly deployed
  HamsterToken, and locally assigned test balances. All modes and delivery paths
  succeeded. See `rehearsal/MainnetIntegration.t.sol`.
- Runtime size and forbidden-opcode checks.

Foundry's source lint reports conservative warnings for deliberate checked casts,
minute/timestamp arithmetic, exact balance checks, and the bounded flush loop.
The boolean tuple returns are success indicators. Flush events follow isolated
subcalls under a reentrancy guard; the swap's `mint` call is to the trusted
PoolManager and has no receiver callback. The unlock callback's bytes result has
no application payload. These patterns were reviewed against their actual
execution paths rather than suppressed globally.

Slither, Mythril, formal verification, and an independent external audit were not
run. The fork rehearsal does not verify the launch factory's complete deployment
or every future state of the external IMD/vault contracts.

## Operational trust and limits

- The supplied PoolManager must be canonical, unmodified v4 with its documented
  self-hook skip, return-delta, claim, and unlock behavior.
- The fixed vault controls what happens after it accepts the corresponding IMD
  pull. The hook cannot fix downstream game configuration or redirect payments.
- Permissionless means someone still has to pay gas for flushes. A permanently
  broken vault strands its credits but cannot disable swaps.
- The hook cannot impose fees on another venue while keeping HAMSTER plain.
- The additional rollback simulation costs gas in buy exact-input and sell
  exact-output modes. It must be included in router estimates.
- Amounts are limited by v4's signed 128-bit deltas; impossible oversized amounts
  revert instead of truncating.
- There is no automatic distribution of the 800M HAMSTER remainder from this
  token contract. Funding and binding the already deployed vault are explicit
  launch/operator responsibilities in the README.
- The independently reviewed final bytecode, CREATE2 address, and factory launch
  simulation remain release responsibilities.
