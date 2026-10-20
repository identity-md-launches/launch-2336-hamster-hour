# Fee accounting

## Amounts and rounding

All calculations use integer IMD minor units. Let:

- `D = 10000`;
- `t = 9500 - 200 * floor((timestamp - startedAt) / 60)` until minute 48,
  then zero;
- `r = 110 + t` on buys, `r = 110` on sells;
- `g` be actual gross IMD paid by a buyer, or gross IMD output by the pool on a sell.

The total hook charge is `F(g) = floor(g*r/D)`. Its permanent part is
`P(g) = floor(g*110/D)`; the anti-snipe part is `T(g) = F(g)-P(g)`.
Sells have `T = 0`.

| Credit | Integer calculation |
| --- | --- |
| Rewards | `floor(g*50/D)` |
| Jackpot | `floor(g*50/D)` |
| Drip | `floor(T*80/100)` |
| Oracle | `P - rewards - jackpot + floor(T/10)` |
| TEAM | `T - drip - floor(T/10)` |

Permanent-fee rounding dust goes to Oracle; tax-split dust goes to TEAM.
The combined fee rounds down once. Consequently `T` can be one minor unit
larger than separately flooring `g*t/D`; its error from the rational tax is
strictly less than one minor unit. This convention preserves the exact total,
keeps the permanent 1.1% rounded down, and permits a monotone exact inverse.
Very small swaps can have a zero hook fee due to unavoidable ERC-20 precision.
No fractional debts are stored.

Define `N(g) = g - F(g)`. Since `0 <= r < D`, increasing `g` by one changes
`N` by zero or one. Every nonnegative net amount is attainable. The smallest
gross amount that yields a given net amount `n` is:

```text
grossUp(0, r) = 0
grossUp(n, r) = floor((n - 1)*D/(D - r)) + 1, for n > 0
```

This follows from `N(g) = ceil(g*(D-r)/D)`. Thus
`N(grossUp(n,r)) = n`. The smallest inverse favors the trader at rounding
boundaries.

## The four modes

The hook determines buy/sell by whether the **input currency is IMD**. It
does not depend on sender, caller identity, hookData, or token sorting.
Uniswap's `amountSpecified < 0` means exact input, positive means exact output.

| Mode | IMD leg | Fee callback |
| --- | --- | --- |
| Buy, exact input | Specified, negative input | Positive specified delta in `beforeSwap`; accrue in `afterSwap` |
| Buy, exact output | Unspecified, negative input | Positive unspecified delta in `afterSwap` |
| Sell, exact input | Unspecified, positive output | Positive unspecified delta in `afterSwap` |
| Sell, exact output | Specified, positive output | Positive specified delta in `beforeSwap`; accrue in `afterSwap` |

The HAMSTER delta is never changed by a hook fee.

### Buy, exact input

The user specifies a gross maximum `G`. Compute `f = F(G)` and AMM budget
`B = G-f`. Simulate a pool swap with exact input `B` and the user's unchanged
price limit. Read the real IMD input `A` from its BalanceDelta.

If `A == B`, return specified fee `f`. The real swap spends `B`, and the caller
pays exactly `G`. If `A < B`, return
`grossUp(A,r)-A` instead. The actual outer AMM budget is now
`G - (grossUp(A,r)-A)`, which is at least `B`; the same price/liquidity limit
still restricts actual input to `A`. The caller pays only `grossUp(A,r)`.

`afterSwap` reads the actual execution delta, performs the same full/partial
distinction, accrues the fee and mints a claim. It returns no unspecified fee.
A disagreement between the quoted fee and actual minted claim would leave
the hook's PoolManager delta unsettled and revert the entire transaction.

### Buy, exact output

The AMM executes the desired HAMSTER output (or the fill allowed by the price
limit). `afterSwap` observes its actual IMD cost `A`. Gross payment is
`g = grossUp(A,r)`, with fee `g-A = F(g)`. The unspecified positive return
adds that fee to the router's IMD debt. HAMSTER output is unchanged.

### Sell, exact input

The AMM sells the specified HAMSTER and returns gross IMD `A`. `afterSwap`
charges `floor(A*110/D)` as an unspecified positive delta. The trader
receives `A-fee`. The anti-snipe rate is not used.

### Sell, exact output

The user specifies desired **net** IMD `N`. Simulate an exact-output swap for
`grossUp(N,110)` with the same price limit. Let the actual simulated gross
IMD output be `A`. Return specified fee `floor(A*110/D)`.

For a full fill, the real AMM target is exactly the grossed-up target and the
trader receives `N`. For a partial fill, `N + fee` is at least `A`; the same
limit binds and the trader receives the actual `A-fee`, less than `N`.
`afterSwap` recomputes the fee from the real output, accrues it, and returns zero.

## Why a reverting simulation

v4's `afterSwap` can change only the *unspecified* currency. Taking a fee on
the requested specified amount in `beforeSwap` overcharges when a swap only
partially fills. A current-price estimate also fails across ticks.

The hook therefore calls its own `simulateSwap` entry point. This entry point:

1. Requires `msg.sender == address(this)`.
2. Calls the immutable manager's `swap` on exactly the immutable key.
3. Always reverts with `SimulationResult(actualImdDelta)`.

The manager skips hook callbacks when the hook itself initiates the simulated
swap. That avoids recursion. **Every simulation is rolled back**, including
price, fee growth, protocol fees, transient currency deltas, balances, and logs.
The hook catches only the expected fixed-size result; unrelated failures propagate.
There is no external entry point that can commit a hook-skipping trade.

The real swap then runs normally, with the original price limit and the calculated
fee. No user-controlled external contract runs between simulation and execution.
The callback never swallows the whole swap: for a positive input `G`,
`F(G) < G`. No simulation delta is used as a substitute HAMSTER payment.

This deliberately costs an additional pool execution in two modes. Routers and
quoters must budget for this, especially when crossing many ticks. It avoids a
separate custom AMM or duplicated Uniswap swap mathematics.

## Claims and settlement

For a charge `F`, the hook records credits totaling `F` and calls:

```solidity
poolManager.mint(address(this), uint256(uint160(IMD)), F);
```

Minting gives the hook `F` claims and debits its transient IMD balance by `F`.
The positive hook return delta credits it by `F`. Those amounts cancel.
The router owes `F` more on a buy or receives `F` less on a sell and settles
normally. No token transfer occurs inside the fee callbacks. This works even
when the manager has no IMD before a buyer's router settles.

For a successful flush of `F`:

1. Reduce the chosen credit and aggregate liability by `F`.
2. Unlock the manager, burn `F` hook-owned claims, and take `F` IMD to the hook.
3. Approve exactly `F` to the fixed vault and call the bucket's method,
   or transfer `F` to the fixed TEAM recipient.
4. Revoke the vault allowance and check the hook balance decreased by `F`.

Burn and take cancel the redemption callback's transient delta. On failure,
the isolated subcall reverts all four steps; the public retry wrapper returns
failure. Reentrancy into either public flush method is rejected.

The tested invariants, absent unsolicited donations, are:

```text
sum(credits) == totalCredits == hook's IMD claim balance
cumulative accrued == totalCredits + cumulative delivered
cumulative delivered == vault IMD receipts + TEAM IMD receipts
hook ERC-20 IMD balance == 0
hook allowance to vault == 0
all hook and router PoolManager currency deltas == 0 after unlock
```

Unsolicited claims may make backing greater than liabilities; they cannot reduce
backing or increase anyone's credit. Bounds reject values outside the supported
signed 128-bit delta range before casting. All fee products fit uint256 under
those bounds. Exact-output sell gross targets are also checked against int128.
