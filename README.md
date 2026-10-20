# Hamster Hour — HAMSTER / IMD

This repository delivers the plain `HamsterToken` and immutable `HamsterHook` for
[Hamster Hour](https://hamsterhour.fun) on Ethereum. All Solidity dependencies are
vendored as ordinary source files. The default build and test suite require no
network, environment variables, FFI, filesystem cheatcodes, or package installation.

```sh
forge build
forge test
forge fmt --check
```

The configuration pins Solidity **0.8.26**, Cancun, optimizer runs 200, and
`bytecode_hash = "none"`. The fuzz seed is the assignment's
`0x230891779670963d90d89c5d6f354a03a3127072d0fb547b1bad1480f9a6926f`.

## Contracts and economics

`HamsterToken` takes **no constructor arguments**. It mints exactly
1,000,000,000 HAMSTER, with 18 decimals, to its deploying factory. Its name is
`Hamster Hour`, symbol `HAMSTER`. There is no subsequent mint, burn, tax, owner,
pause, blacklist, or upgrade function.

`HamsterHook` binds one pool at construction:

| Parameter | Fixed value / source |
| --- | --- |
| Network | Ethereum, chain ID 1 |
| HAMSTER | Constructor `$token` |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| LP fee | `12500` pips = 1.25%, static |
| Tick spacing | `60` |
| Hook | Its own address |
| Vault | `0x1DCeb78b36b5F18Ac4a130F1FFc76ebA0E73D183` |
| TEAM payment recipient | Constructor `$owner`, resolving to `0x6CBA4751742F6989fA224B2dC5d5d52fCef98a34` |

Currency ordering is derived from the token addresses. The initializer may choose
the price required by the launch policy; the hook does not hardcode a token address
or opening price. Dynamic fee keys and every other pool key are rejected.

The permanent hook fee is **1.1% of the actual gross IMD leg**, distributed as:

| Share of gross IMD | Destination |
| --- | --- |
| 0.5% | Vault `depositRewards(uint256)` |
| 0.5% | Vault `forwardJackpot(uint256)` |
| 0.1% | Vault `forwardOracle(uint256)` |

The buy-only anti-snipe tax starts at pool initialization:
`95% - 2% × floor(elapsedSeconds / 60)`, through minute 47 (1%).
It is zero from minute 48. Sells always pay zero anti-snipe tax.
Tax proceeds are split 80% to `depositDrip`, 10% to `forwardOracle`, and 10% to TEAM.
Initialization is factory-only and one-shot, including at timestamp zero.
There is no re-arm, exemption, router allowlist, fee setter, owner, pause, or upgrade.

**Fee-base assumption:** on a buy, the gross IMD leg is what the trader actually
pays, including the hook fee and anti-snipe tax. On a sell it is the pool's IMD
output before the hook fee. Thus a fully filled 100 IMD buy in minute 0 credits
1.1 IMD permanent fees plus 95 IMD tax, leaving 3.9 IMD for the AMM, whose input
already includes its LP fee. Exact-output buys gross up the actual AMM input to
pay the same percentages. Exact-output sells specify the **net** IMD received.
These definitions keep all modes economically consistent and make a 95% tax
actually remove 95% of the buyer's payment.

The maximum nominal rates sum to `95% + 1.1% + 1.25% = 97.35%`.
The actual buy LP fee applies to the smaller amount reaching the AMM, so this is
a conservative ceiling. In integer dust trades, fees cannot exceed the actual
input. The hook takes **IMD only**, with no ETH conversion or HAMSTER tax.

Fees use real PoolManager deltas, including price-limited and liquidity-limited
partial fills. Unused input is not taxed. The implementation and rounding proof
are described in [docs/ACCOUNTING.md](docs/ACCOUNTING.md).

## Liquidity during the tax window

A liquidity position on the IMD side of the current price is a resting bid: every
untaxed sell of HAMSTER fills it at pool price, so its owner would acquire HAMSTER
for IMD with no hook fee and no anti-snipe tax, and earn the LP fee on top. To
keep "buy-only tax from pool start" and "no fee bypass" true for range orders,
the hook enables `beforeAddLiquidity` and applies one rule while `taxBps() > 0`:

| Sender | Position | Allowed |
| --- | --- | --- |
| Launch factory (`$factory`) | Any | Yes |
| Anyone else | Funded with HAMSTER only (entirely on the buy side of the current tick) | Yes |
| Anyone else | Holds any IMD (IMD-only or two-sided, including a range whose lower edge sits on the current tick) | No, `ImdLiquidityDuringTax` |

"HAMSTER only" uses exactly the classification `Pool.modifyLiquidity` uses:
with IMD as `currency0` the range must satisfy `tick >= tickUpper`, otherwise
`tick < tickLower`. Such a position never turns IMD into HAMSTER: taxed buys move
the price into it and sell its HAMSTER for IMD, which is the untaxed direction.
From minute 48 the rule is gone permanently; it cannot re-arm, and there is no
owner switch. Removals, zero-liquidity fee collection, and donations never reach
this callback, so the factory's fee collection and every withdrawal are untouched.
Liquidity operations never accrue hook fees.

## Credits and delivery

Swaps never call the vault, approve tokens, transfer fees, or invoke TEAM.
They mint IMD ERC-6909 claims in the PoolManager and accrue five credit buckets.
Consequently a vault failure, missing vault code, or insufficient **pre-swap**
IMD reserves cannot stop a swap. Normal swap failures, such as invalid slippage,
an unpaid router debt, or unavailable liquidity for a requested full fill, still
follow Uniswap's rules.

Anyone can call:

```solidity
hook.flush(bucket, maxAmount);       // returns (success, amountDelivered)
hook.flushAll(maxAmountPerBucket);   // returns total delivered
```

| Bucket number | Recipient / method |
| --- | --- |
| 0 | Vault `depositRewards` |
| 1 | Vault `depositDrip` |
| 2 | Vault `forwardJackpot` |
| 3 | Vault `forwardOracle` |
| 4 | Direct IMD transfer to TEAM |

Each attempt burns the corresponding claim, redeems IMD, and pays the fixed
recipient in one revertible subcall. A vault allowance covers exactly that attempt
and is cleared afterwards. The hook checks the actual balance movement.
Reverts, no pulls, short pulls, and failed transfers roll back the entire attempt,
including the claim burn, debit, and approval. Other buckets can proceed.
`FlushFailed` records the failure, and anyone can retry later.

Call flush **outside** an existing PoolManager unlock. A locked-out redemption
fails safely and leaves the credit intact. Each call is capped at
`type(int128).max`, respecting the manager's signed delta limit and the vault's
larger unsigned limit; a smaller caller-selected limit is useful for maintenance.
Zero limits and empty buckets are no-ops. A non-zero limit below
`MIN_FLUSH_AMOUNT` (1 IMD, `1e18`) is raised to it, so a bucket is delivered
whole or in pieces of at least 1 IMD. The vault's `depositRewards` appends one
7-day stream boundary per deposit once its reward clock moves, and stakers step
through those boundaries in later checkpoints, so an unbounded caller-chosen
limit would let anyone turn one credit into millions of dust deposits. The floor
bounds that to one boundary per IMD of fees while keeping flushing permissionless.
There is no keeper bounty. There is also no rescue path for unsolicited token or
claim donations, and no alternate recipient if the immutable vault permanently
stops working. A gas-exhausting vault may exhaust a standalone flush transaction;
it has no call path into an ordinary swap.

## Deployment parameters

Deploy only these two application contracts, in this order:

1. `HamsterToken()` through the launch factory.
2. `HamsterHook(IPoolManager manager_, address token_, address factory_, address team_)`.

The hook's four constructor arguments, in order, are:

| Argument | Manifest step's value |
| --- | --- |
| `manager_` | `$poolManager` |
| `token_` | `$token` |
| `factory_` | `$factory` |
| `team_` | `$owner` (the TEAM address above) |

None is an administrative role. Factory has only the right to perform the first
initialization. PoolManager is not hardcoded, and construction makes no external
calls or code-existence checks.

Mine the hook's CREATE2 address with its **complete creation code and constructor
arguments**, so its low 14 bits are **`0x28cc` (10444)**. The constructor validates
the address against `getHookPermissions()` and rejects a mismatch.
`HookFlags` supplies internal-only mining predicates. No external library linking
is required.

Enabled permissions are `beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`,
`afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`. Initialization
guards the predicted pool before hook deployment and starts the tax. The swap
callbacks support both specified and unspecified IMD legs. `beforeAddLiquidity`
enforces the tax-window liquidity rule above and returns no delta. Every enabled
callback and the redemption callback checks PoolManager. `beforeRemoveLiquidity`
and `afterRemoveLiquidity` stay disabled, so factory fee collection with zero
liquidity change and normal withdrawals cannot be blocked by the hook.

The design is a minimal general-purpose, BaseHook-style implementation using
v4-core interfaces directly. It has no share token, administrative access, dynamic
fee utility, transient hook state, or upgradable base. Claim accounting uses
PoolManager `mint/burn/take`; token transfers use vendored OpenZeppelin SafeERC20.

This repository does not deploy, broadcast, use a signer, or generate `launch.json`.
The separate launch step supplies that manifest, mines the address, initializes
the pool, and distributes the factory's token balance. Use the launch's policy
opening-price calculation, rather than the test suite's convenient prices.

## The requested 800M remainder

The token must mint the entire 1B supply to the factory so the launch can allocate
10% to the distributor and 10% to liquidity. It cannot redirect 800M in its
constructor.

The supplied launch policy pays the 80% remainder to the payer, or treasury when
there is no payer. If the actual launch allocation step supports an explicit
remainder destination, use the existing HamsterVault address above for exactly
800,000,000 HAMSTER. Otherwise the remainder recipient must transfer that amount
to HamsterVault after launch. This implementation cannot authorize or perform a
transfer from that recipient.

## After launch

- The remainder recipient / launch allocation step funds HamsterVault with the
  full 800M HAMSTER as described above.
- The existing vault's TEAM calls its one-time `bindToken(address)` with the
  deployed HamsterToken address **after** the vault holds at least 800M. At the
  pinned vault commit, `bindToken` reverts with `InvalidAmount` while the vault's
  HAMSTER balance is below 800,000,000 tokens, and `stake` requires a bound token,
  so nothing in the vault works for stakers until the remainder has been
  forwarded. No contract in this repository can perform that transfer: the token
  mints the whole supply to the factory and the launch policy pays the 80%
  remainder to the payer. This is a responsibility of the already deployed vault
  and the remainder recipient, not an admin operation on the token or hook. Hook
  flushes before binding are safe: `depositRewards` and `depositDrip` do not
  require a bound token, and with no staked weight the vault's clock is paused.
- A keeper, project operator, or any user periodically calls `flush`/`flushAll`,
  observes `credits`, `totalCredits`, and `FlushFailed`, and retries failures.
- The vault's operators and users handle its reward maintenance and downstream
  jackpot/oracle flushing. Hook delivery ends when the vault pulls the IMD.
- The launch operator verifies the actual factory, manager, token, mined flags,
  fee, spacing, opening price, and code against the final build before broadcast.
  Arrange the separate independent adversarial review required for release.

The hook has no post-deployment settings to configure.
Fees apply to this immutable launch pool. A plain ERC-20 cannot prevent holders
from trading elsewhere or creating a separate pool; it has no transfer restrictions
to impose this pool's fee on unrelated venues.

## Validation and sources

The default suite exercises a real locally deployed Uniswap v4 PoolManager,
both currency orderings, all four swap modes, every tax minute and boundary,
partial and zero-liquidity fills, dust, startup with no IMD reserves,
permission checks, immutable pool identity, credit conservation, the tax-window
liquidity rule (IMD range orders refused in minutes 0 and 47 and filled from
minute 48, HAMSTER-only positions collecting and withdrawing during the window,
factory positions, boundary ticks, and a fuzz over ranges and minutes), the
flush floor, and adversarial vault delivery. Stateful tests mix trades, time,
vault failures, and retries. The test contract plays the launch factory: it
initializes the pool and seeds its liquidity through its own unlock callback.
There are no skipped tests in the default suite.

An additional integration rehearsal passed against Ethereum state at block
**26,235,704**, using the actual deployed IMD and HamsterVault, a local fresh
PoolManager, a newly deployed HamsterToken, and test-funded balances. It covered
all swap modes, partial fills, and successful delivery through all four vault
methods and TEAM. This is not a transaction on Ethereum and not a rehearsal of the
launch factory itself. At that block, the vault's TEAM matched the address above
and its token was not yet bound.

The optional rehearsal is kept outside the default offline tests:

```sh
FOUNDRY_PROFILE=rehearsal forge test \
  --fork-url YOUR_ETHEREUM_RPC_URL \
  --fork-block-number 26235704 \
  --match-contract MainnetIntegrationTest
```

The test does not read environment variables or embed an RPC endpoint.
An archival Ethereum provider is required only for this optional command.

- [Accounting and rounding](docs/ACCOUNTING.md)
- [Security review and limits](docs/SECURITY.md)
- [Pinned dependency provenance](dependencies.json)
- [Vault source, pinned commit](https://github.com/identity-md-launches/launch-2304-project-site-https-hamsterhour-fun-launc/tree/69ca386ed1d5ea7529caf7b75c348159bf488885)
- [Uniswap v4 core, pinned commit](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75)

The code is MIT licensed. Vendored libraries retain their upstream licenses.
