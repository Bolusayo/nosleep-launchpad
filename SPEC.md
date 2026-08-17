# No Sleep — System Specification

Audit-facing specification for the No Sleep launchpad. Describes what the
system is **intended** to do, independent of the code that does it, so a
reviewer can compare intent against implementation rather than inferring
intent from implementation.

- **Target chain:** Robinhood Chain (Arbitrum Orbit L2), chainId 4663 mainnet / 46630 testnet
- **Solidity:** 0.8.28, `via_ir = true`, `optimizer_runs = 1`
- **Dependencies:** OpenZeppelin Contracts v5 (ERC20, ERC721, AccessControl, Ownable, ReentrancyGuard, SafeERC20, Math)
- **External integration:** Uniswap V2 (Router02 + Factory), canonical deployment on 4663

---

## 1. System overview

A permissionless memecoin launchpad. One transaction deploys a token, a
bonding curve holding its entire supply, and optionally a tradeable referral
NFT. Tokens sell on the curve until a fixed ETH target is reached, then
migrate to a Uniswap V2 pool with liquidity permanently burned.

### Token lifecycle

```
createToken()
    │
    ├─ CurveDeployer.deploy() ──> BondingCurve
    │                                 └─ constructor ──> MemeToken (100% supply to curve)
    ├─ ReferralNFT.mintReferral()  (if a referrer was named)
    ├─ curve.setReferral()
    └─ curve.buyFor()              (optional atomic dev buy, cap-exempt)
    │
    ▼
BONDING PHASE
    buy()  — 80% of supply sells on a constant-product curve with virtual reserves
    sell() — reverse, same curve
    2% fee on both sides; a slice goes to the referral NFT, the rest to the protocol
    │
    ▼  (quoteReserve reaches VIRTUAL_QUOTE + QUOTE_TARGET)
GRADUATION  (automatic, inside the buy that crosses the target)
    ├─ router.addLiquidityETH(raise + remaining 20% of supply) ──> LP minted to 0x…dEaD
    ├─ _registerPair()    — look up the CREATE2 pair, tell the token about it
    └─ _deploySplitter()  — taxed tokens only: FeeSplitter + DividendVault
    │
    ▼
POST-GRADUATION
    Trading happens on Uniswap. Curve is inert.
    Taxed tokens: tax accrues to FeeSplitter, split four ways, pull-based.
```

### Supply split

| Portion | Share | Destination |
|---|---|---|
| Curve supply | 80% | Sold to buyers during the bonding phase |
| Pool seed | 20% | Paired with the raise at graduation |

`MIN_SUPPLY = 1_000_000`, `MAX_SUPPLY = 1_000_000_000_000` whole tokens (18 decimals).

---

## 2. Curve mathematics

Constant-product AMM with **virtual reserves**, so no seed liquidity is needed
and the curve reaches its target with a known, bounded price path.

At construction, with `s = curveSupply` (80% of total supply):

```
quoteReserve = VIRTUAL_QUOTE
tokenReserve = s + (VIRTUAL_QUOTE · s) / QUOTE_TARGET
```

with `VIRTUAL_QUOTE = 3 ether`, `QUOTE_TARGET = 4 ether`.

Trades preserve `k = quoteReserve · tokenReserve`, using `Math.ceilDiv` on the
output reserve so rounding always favours the pool, never the trader.

Graduation triggers when `quoteReserve >= VIRTUAL_QUOTE + QUOTE_TARGET`.

`ethCollected()` is derived as `quoteReserve − VIRTUAL_QUOTE` and never stored.

### Price multiple

The curve shape is scale-invariant: whatever the supply, the price rises by a
fixed **6.33×** from first buy to graduation
(`1.1875 / 0.1875 = 6.3333…`). Supply choice changes the sticker price per
token, not the economics.

### Partial fill

A buy that would overshoot the target is capped, not reverted. `grossMax` is
the gross ETH (fee-inclusive) that exactly fills the remaining room:

```
room     = VIRTUAL_QUOTE + QUOTE_TARGET − quoteReserve
grossMax = room · BPS / (BPS − FEE_BPS)
```

Anything above `grossMax` is refunded to the buyer in the same transaction.
This is why quoting must happen on-chain — see §8.

---

## 3. Contract inventory

| Contract | Lines | Responsibility |
|---|---|---|
| `BondingCurve` | 345 | Curve maths, trading, graduation, migration. Deploys its own token. |
| `FeeSplitter` | 241 | Post-graduation tax, split four ways, pull-based execution. |
| `LaunchpadFactory` | 174 | Entry point. Atomic launch + dev buy + referral mint. `Ownable`. |
| `RewardsDistributor` | 153 | Multi-asset accumulator for Genesis NFT holders. **Not deployed — see §7.** |
| `ReferralNFT` | 139 | ERC-721 referral rights with pull-based commission and transfer settlement. |
| `MemeToken` | 132 | Fixed-supply ERC-20, optional asymmetric buy/sell tax. |
| `DividendVault` | 92 | Self-mode proportional dividends in the token itself. |
| `CurveDeployer` | 61 | Bytecode isolation so the factory fits under EIP-170. |
| `MockV2Router` | 111 | Testnet stand-in. **Not production. See §9.** |

---

## 4. Trust boundaries and privileged actions

### Permissionless (anyone may call)

- `BondingCurve.buy`, `sell`
- `LaunchpadFactory.createToken` (pays `deployFee`)
- `FeeSplitter.process`, `payMarketing`, `addLiquidity`, `payDividends`, `executeBurn`
- `DividendVault.claim`
- `RewardsDistributor.enroll`
- `ReferralNFT.claim` / `claimSettled` (owner-gated per token, but unprivileged)

Splitter operations are deliberately permissionless and separated so a
failing swap can never block the split, and no logic runs inside a transfer.

### Privileged

| Holder | Power |
|---|---|
| `LaunchpadFactory` owner | `setDeployFee`, `setFeeRecipient` |
| `ReferralNFT` `DEFAULT_ADMIN_ROLE` | Role administration |
| `ReferralNFT` `MINTER_ROLE` (factory) | `mintReferral`; is role-admin for `CREDITOR_ROLE` |
| `ReferralNFT` `CREDITOR_ROLE` (each curve) | `credit`, `markMigrated` |
| `RewardsDistributor` `DEPOSITOR_ROLE` | `depositEth`, `depositToken` |
| `MemeToken` `curve` (immutable) | `setDexPair`, `setTaxCollector`, `setExempt` |
| `FeeSplitter` `deployer` (the curve) | `setDividendVault` (once) |
| `BondingCurve` `factory` (immutable) | `setReferral` (once), `buyFor` |

**No contract is upgradeable. No contract has an owner-withdraw or rescue
function.** Once deployed, curve and token behaviour is fixed.

### Deliberate never-revert paths

Three sites swallow failures on purpose, because a revert would be worse than
the degraded state:

| Site | On failure | Rationale |
|---|---|---|
| `BondingCurve._payFee` | Referral cut redirected to protocol | A bad NFT must not brick trading |
| `BondingCurve._registerPair` | No pair registered → no post-graduation tax | Better than a stuck curve |
| `BondingCurve._deploySplitter` | Tax keeps accruing to the curve | Recoverable; a revert would strand the raise |

By contrast, `addLiquidityETH` failure **does** revert (`MigrationFailed`) so
the raise is never stranded in a half-migrated state.

---

## 5. Invariants

### Fuzz-tested (in suite)

1. **Target exactness** — the curve raises exactly `QUOTE_TARGET`, regardless of how buys are chunked. (`testFuzz_AlwaysGraduatesAtTarget`)
2. **Quote fidelity** — `quoteBuy(x)` equals the tokens actually received when buying with `x`, exactly. (`testFuzz_QuoteMatchesActualBuy`)
3. **No referral leakage** — no value is lost or duplicated across the NFT transfer-settle path. (`testFuzz_NoValueLeaks`)
4. **Dividends never overpay** — total claimed never exceeds total deposited. (`testFuzz_NeverOverPays`) — **see §7, this may not hold for late entrants**
5. **Split conservation** — the four-way split sums to the input. (`testFuzz_SplitConservesTotal`)
6. **Tax ceiling** — tax never exceeds the configured rate. (`testFuzz_TaxNeverExceedsRate`)

### Asserted but not fuzzed

7. **Post-graduation cleanliness** — the curve holds zero ETH and zero tokens.
8. **LP is always burned** — all LP except Uniswap's `MINIMUM_LIQUIDITY` (1000 wei) goes to `0x…dEaD`. Nobody, including creator and protocol, ever holds LP.
9. **LP amount is the geometric mean** — `lpAmount == sqrt(ethForLp · tokensForLp) − 1000`. Verified against real Uniswap on a mainnet fork, exact to the wei.
10. **Pool seed is untaxed** — the full 20% tranche reaches the pair. The router is marked exempt before `addLiquidityETH`, and `setDexPair` runs *after* migration, so the seed is not classified as a sell.
11. **Registered pair is the real pair** — `token.dexPair() == factory.getPair(token, WETH)`. Verified against real CREATE2 on a fork.
12. **Curve trades are untaxed** — the curve is exempt from construction.
13. **Wallet-to-wallet is untaxed** — only transfers to/from `dexPair` are taxed.
14. **Referral commission follows the NFT** — future commissions accrue to the current holder; accrued-but-unclaimed amounts settle to the seller on transfer.
15. **No late-entrant exploitation in `RewardsDistributor`** — enrolment snapshots every known asset's accumulator, so a new Genesis NFT cannot claim pre-enrolment deposits.

### Intended but unstated in code

16. `purchased[]` never decreases — selling does not restore wallet-cap headroom. This is deliberate anti-snipe behaviour; a consequence is that a capped buyer who sells cannot re-buy.
17. Tax applies only while `taxActive()`; `taxDurationDays == 0` means forever.
18. `MAX_TAX_BPS = 1000` (10%) is a hard per-side ceiling enforced at construction.

---

## 6. Fee and tax flows

### Bonding phase — 2% trade fee, both sides

```
fee = 2% of gross
  ├─ referralBps (default 10% of the fee) ──> ReferralNFT.credit(id)  [pending → holder]
  └─ remainder ──────────────────────────────> feeRecipient
```

If `credit` reverts, the whole fee goes to `feeRecipient`.

### Post-graduation — optional token tax

Asymmetric buy/sell tax (≤10% per side), collected in-token to the
`FeeSplitter`, then split on `process()`:

```
accumulated tax
  ├─ liquidityBps  ──> addLiquidity()  — half swapped to ETH, paired, LP burned
  ├─ burnBps       ──> transfer to 0x…dEaD  (immediately, or held for a window)
  ├─ marketingBps  ──> payMarketing()  — swapped to ETH, forwarded
  └─ dividendBps   ──> payDividends()  — forwarded to DividendVault
```

The four must sum to exactly 10,000 bps or `FeeSplitter` construction reverts
(and `_deploySplitter` silently skips).

**Allocation accounting:** `process()` operates on
`balanceOf(this) − allocated()`, where `allocated()` is the sum of all four
tracked pools. This prevents already-earmarked tokens from being re-split.

**Burn modes:** `Threshold` burns on every `process()`. `Weekly`/`Monthly`
hold the tranche in `pendingBurn` until `burnDue()`, released by `executeBurn()`.
**Only `Threshold` is reachable in production — see §7.**

---

## 7. Known gaps and accepted risks

Stated explicitly so audit hours aren't spent rediscovering them.

### Functional gaps

1. **`markMigrated` is never called in production.** No production code path
   invokes it — only tests do. Consequently no referral ever reaches
   `Status.Genesis`, `genesisNumber` stays 0, and
   `RewardsDistributor.enroll()` always reverts `NotGenesis`. **The entire
   Genesis rewards pipeline is unreachable on-chain.**

2. **`RewardsDistributor` is not deployed.** Neither deploy script references
   it, and `DEPOSITOR_ROLE` is granted only in tests. It is fully written and
   has 11 passing tests, but nothing on-chain can deposit to it or claim from
   it. Decide whether to wire it or declare it out of scope.

3. **Burn mode is hardcoded.** `_deploySplitter` always passes
   `BurnMode.Threshold`. `Weekly`/`Monthly` work in `FeeSplitter` but are
   unreachable from a launch.

4. **Splitter threshold is hardcoded** at `curveSupply / 10_000` (0.01%).

5. **Three of four dividend payout modes are unbuilt.** Only self-mode
   (claim in the token itself) exists.

### Areas needing review attention

6. **`DividendVault` late-entrant exposure.** `pending()` uses the holder's
   *current* balance against `accPerToken`, and `rewardDebt` is only written on
   claim (`initialised` defaults false → debt 0). A wallet that acquires tokens
   *after* deposits have accumulated appears to be owed the full accumulated
   per-token amount. Compounding this, `eligibleSupply()` excludes `dexPair`,
   so buying from the pool *increases* eligible supply after `accPerToken` was
   computed against a smaller one. **Whether total claims can exceed total
   deposits, and whether late buyers can dilute or strand honest holders,
   should be treated as a priority review item.** Note that
   `RewardsDistributor` solves exactly this problem with enrolment snapshots;
   `DividendVault` has no equivalent.

7. **`FeeSplitter.addLiquidity` passes `0, 0`** as `amountTokenMin`/`amountETHMin`
   to `addLiquidityETH`, accepting whatever ratio the pool offers. The
   preceding swap is protected by `minEthOut`, the liquidity add is not.

8. **`ReferralNFT.credit(id)` does not verify** that `id` belongs to the
   calling curve. Any `CREDITOR_ROLE` holder can credit any id. Currently only
   factory-deployed curves hold the role and each credits only its own id, so
   this is defence-in-depth rather than a live issue — but the check is absent.

9. **`block.timestamp` comparisons** in `FeeSplitter.burnDue()` and
   `MemeToken.taxActive()`. Both tolerate seconds of drift by design.

10. **Unbounded `assets` array** in `RewardsDistributor`. `enroll()` and
    `claimAll()` loop over it. Growth is gated by `DEPOSITOR_ROLE`, so it is
    trusted-party bounded, not attacker bounded.

### Operational constraints

11. **EIP-170 headroom.** `CurveDeployer` sits at ~23,586 / 24,576 bytes.
    Any change to `BondingCurve`, `MemeToken`, `FeeSplitter` or
    `DividendVault` changes this. `forge build --sizes` after every edit.
    `via_ir` and the optimizer are required to compile at all.

12. **`optimizer_runs = 1`.** Tuned for deployment size, not runtime gas, to
    stay under EIP-170. Every user transaction pays for this.

13. **Taxed tokens cost ~22% more gas per transfer**, because the `_update`
    override runs even at zero tax.

14. **`PUSH0` / EIP-3855 support on Robinhood Chain is unconfirmed.** Foundry
    warns; deploys succeed.

---

## 8. Design decisions worth knowing

**Quoting is on-chain.** `quoteBuy`/`quoteSell` are view functions on the
curve. An earlier JavaScript reimplementation drifted from the contract —
specifically it ignored the `grossMax` partial-fill cap — producing
slippage mismatches. Frontends must not reimplement curve maths.

**LP burns to `0x…dEaD`, not `address(0)`.** OpenZeppelin v5 rejects
minting to the zero address, which reverts graduation.

**Bytecode isolation via `CurveDeployer`.** `LaunchpadFactory` exceeded
EIP-170 once it embedded `BondingCurve`'s creation code. Deploy order is
therefore load-bearing: `CurveDeployer` → `LaunchpadFactory` →
`deployer.setFactory()`.

**Enrolment snapshots in `RewardsDistributor`.** New entrants inherit the
current accumulator as debt for every known asset, so they cannot claim
against deposits that predate them.

---

## 9. Audit scope

### In scope

`src/BondingCurve.sol`, `src/CurveDeployer.sol`, `src/DividendVault.sol`,
`src/FeeSplitter.sol`, `src/LaunchpadFactory.sol`, `src/MemeToken.sol`,
`src/ReferralNFT.sol`, `src/interfaces/IUniswapV2Router.sol`

### Out of scope

- `src/mocks/MockV2Router.sol` — test fixture, never deployed to mainnet.
  Note it returns an `lpAmount` roughly 100× smaller than the geometric mean;
  the mock is wrong, the production path is correct (invariant 9).
- The frontend (`index.html`, `app.js`).
- Uniswap V2 itself.
- OpenZeppelin v5.

### Scope decision required

`src/RewardsDistributor.sol` — built and tested but unreachable (§7 items 1–2).
Either wire it before audit or exclude it. Auditing dead code is wasted spend.

### Prior verification already performed

- 95 tests passing, 8 suites, 6 fuzz invariants.
- `test/ForkGraduation.t.sol` — 8 tests against the **real** Uniswap V2
  deployment on a mainnet fork, covering LP accounting, CREATE2 pair
  registration, pool-seed tax exemption, and a post-graduation taxed sell.
- Full end-to-end dividend pipeline verified on testnet.
- Uniswap addresses verified three ways: official deployments doc, on-chain
  bytecode, live `WETH()` call.

### Deployment addresses (mainnet, chainId 4663)

| Contract | Address |
|---|---|
| UniswapV2Router02 | `0x89e5DB8B5aA49aA85AC63f691524311AEB649eba` |
| UniswapV2Factory | `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
