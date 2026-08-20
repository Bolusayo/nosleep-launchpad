# No Sleep — System Specification

Audit-facing specification for the No Sleep launchpad. Describes what the
system is **intended** to do, independent of the code that does it, so a
reviewer can compare intent against implementation rather than inferring
intent from implementation.

- **Target chain:** Robinhood Chain (Arbitrum Orbit L2), chainId 4663 mainnet / 46630 testnet
- **Solidity:** 0.8.28 (pinned), `via_ir = true`, `optimizer_runs = 1`
- **Dependencies:** OpenZeppelin Contracts v5 (ERC20, ERC721, AccessControl, Ownable, ReentrancyGuard, SafeERC20, Math)
- **External integration:** Uniswap V2 (Factory + Pair; the Router is used only by `FeeSplitter`)
- **Status:** not audited, not deployed to mainnet

---

## 1. System overview

A permissionless memecoin launchpad. One transaction deploys a token, a
bonding curve holding its entire supply, the Uniswap pair that token will
eventually trade in, and optionally a tradeable referral NFT. Tokens sell on
the curve until a fixed ETH target is reached, then the curve seeds the pool
itself and burns the LP.

### Token lifecycle

```
createToken()
    │
    ├─ CurveDeployer.deploy() ──> BondingCurve
    │       ├─ constructor ──> MemeToken   (100% supply to the curve)
    │       └─ constructor ──> factory.createPair(TOKEN, WETH)
    │                          token.setDexPair(pair)   [pair now LOCKED]
    ├─ ReferralNFT.mintReferral()      (only if a referrer was named; soulbound)
    ├─ curve.setReferral()
    └─ curve.buyFor()                  (optional atomic dev buy, cap-exempt)
    │
    ▼
BONDING PHASE
    buy()  — 80% of supply sells on a constant-product curve with virtual reserves
    sell() — reverse, same curve
    2% fee both sides; a slice to the referral NFT, the rest to the protocol
    The pair exists but MemeToken rejects every transfer into it (PoolLocked)
    │
    ▼  (quoteReserve reaches VIRTUAL_QUOTE + QUOTE_TARGET)
GRADUATION  (automatic, inside the buy that crosses the target)
    ├─ token.setPoolSeeded()            — unlocks the pair, one-way
    ├─ WETH.deposit{value: raise}()     — wrap
    ├─ WETH.transfer(pair, raise)
    ├─ token.transfer(pair, 20% tranche)
    ├─ pair.mint(0x…dEaD)               — LP burned on creation
    └─ _deploySplitter()                — taxed tokens only
    │
    ▼
POST-GRADUATION
    Trading happens on Uniswap. The curve is inert.
    Taxed tokens: tax accrues to FeeSplitter, split four ways, pull-based.
```

### Supply split

| Portion | Share | Destination |
|---|---|---|
| Curve supply | 80% (`CURVE_SHARE_BPS`) | Sold to buyers during the bonding phase |
| Pool seed | 20% | Paired with the raise at graduation |

`MIN_SUPPLY = 1_000_000`, `MAX_SUPPLY = 1_000_000_000_000` whole tokens, 18 decimals.

---

## 2. Curve mathematics

Constant-product AMM with **virtual reserves**, so no seed liquidity is needed
and the curve reaches its target along a known, bounded price path.

At construction, with `s = curveSupply` (80% of total supply):

```
quoteReserve = VIRTUAL_QUOTE
tokenReserve = s + (VIRTUAL_QUOTE · s) / QUOTE_TARGET
```

with `VIRTUAL_QUOTE = 3 ether`, `QUOTE_TARGET = 4 ether`.

Trades preserve `k = quoteReserve · tokenReserve`, using `Math.ceilDiv` on the
output reserve so rounding always favours the pool, never the trader.

Graduation triggers when `quoteReserve >= VIRTUAL_QUOTE + QUOTE_TARGET`.

`ethCollected()` is derived as `quoteReserve − VIRTUAL_QUOTE`, never stored.

### Price multiple

The curve shape is scale-invariant: whatever the supply, price rises by a fixed
**6.33×** from first buy to graduation (`1.1875 / 0.1875`). Supply choice
changes the sticker price per token, not the economics.

### Partial fill

A buy that would overshoot the target is capped, not reverted. `grossMax` is
the gross ETH (fee-inclusive) that exactly fills the remaining room:

```
room     = VIRTUAL_QUOTE + QUOTE_TARGET − quoteReserve
grossMax = room · BPS / (BPS − FEE_BPS)
```

Anything above `grossMax` is refunded in the same transaction. This is why
quoting must happen on-chain — see §8.

---

## 3. Contract inventory

| Contract | Responsibility |
|---|---|
| `BondingCurve` | Curve maths, trading, graduation. Deploys its own token and creates its own pair. |
| `MemeToken` | Fixed-supply ERC-20. Optional asymmetric buy/sell tax. Locks the pair until graduation. |
| `FeeSplitter` | Post-graduation tax, split four ways, pull-based execution. |
| `LaunchpadFactory` | Entry point. Atomic launch + dev buy + referral mint. `Ownable`. |
| `ReferralNFT` | Soulbound ERC-721 referral rights, pull-based commission. |
| `DividendVault` | Proportional dividends in the token itself, settled on transfer. |
| `RewardsDistributor` | Multi-asset accumulator for Genesis NFT holders. **Not deployed — §7.** |
| `CurveDeployer` | Bytecode isolation: holds `BondingCurve` creation code. |
| `SplitterDeployer` | Bytecode isolation: holds `FeeSplitter`/`DividendVault` creation code. |
| `MockV2Router` | Testnet and unit-test Uniswap stand-in. **Not production — §9.** |

---

## 4. Trust boundaries and privileged actions

### Permissionless (anyone may call)

- `BondingCurve.buy`, `sell`
- `LaunchpadFactory.createToken` (pays `deployFee`)
- `FeeSplitter.process`, `payMarketing`, `addLiquidity`, `payDividends`, `executeBurn`
- `DividendVault.claim`
- `RewardsDistributor.enroll`
- `ReferralNFT.claim` / `claimSettled` (owner-gated per token, but unprivileged)

Splitter operations are deliberately permissionless and separated so a failing
swap can never block the split, and no logic runs inside a transfer.

### Privileged

| Holder | Power |
|---|---|
| `LaunchpadFactory` owner | `setDeployFee`, `setFeeRecipient` |
| `ReferralNFT` `DEFAULT_ADMIN_ROLE` | Role administration |
| `ReferralNFT` `MINTER_ROLE` (factory) | `mintReferral`; role-admin for `CREDITOR_ROLE` |
| `ReferralNFT` `CREDITOR_ROLE` (each curve) | `credit`, `markMigrated` |
| `RewardsDistributor` `DEPOSITOR_ROLE` | `depositEth`, `depositToken` |
| `MemeToken` `curve` (immutable) | `setDexPair`, `setPoolSeeded`, `setTaxCollector`, `setDividendVault`, `setExempt` |
| `FeeSplitter` `deployer` (the SplitterDeployer) | `setDividendVault` (once, during deployment) |
| `BondingCurve` `factory` (immutable) | `setReferral` (once), `buyFor` |

**`ReferralNFT` is soulbound.** Minting works; every transfer reverts
`Soulbound()`. There is no admin override and no burn.

**No contract is upgradeable. No contract has an owner-withdraw or rescue
function.** Once deployed, curve and token behaviour is fixed. Anything
stranded is stranded permanently — which is why the graduation path is written
to strand nothing.

### One-way state flags

| Flag | Set by | Effect |
|---|---|---|
| `BondingCurve.graduated` | itself, at target | Curve stops trading |
| `MemeToken.poolSeeded` | the curve, at graduation | Unlocks transfers into `dexPair` |
| `MemeToken.dexPair` | the curve, at construction | Set once; identifies the pair |

### Deliberate never-revert paths

Two sites swallow failures on purpose, because a revert would be worse than
the degraded state:

| Site | On failure | Rationale |
|---|---|---|
| `BondingCurve._payFee` | Referral cut redirected to protocol | A bad NFT must not brick trading |
| `BondingCurve._deploySplitter` | Tax keeps accruing to the curve | Recoverable; a revert would strand the raise |

By contrast the pool seed **does** revert (`MigrationFailed`) if `pair.mint`
fails or returns zero, so the raise is never half-migrated.

---

## 5. Invariants

### Fuzz-tested

1. **Target exactness** — the curve raises exactly `QUOTE_TARGET`, however buys are chunked. (`testFuzz_AlwaysGraduatesAtTarget`)
2. **Quote fidelity** — `quoteBuy(x)` equals the tokens actually received. (`testFuzz_QuoteMatchesActualBuy`)
3. **No referral leakage** — no value lost or duplicated across the NFT transfer-settle path. (`testFuzz_NoValueLeaks`)
4. **Split conservation** — the four-way split sums to the input. (`testFuzz_SplitConservesTotal`)
5. **Tax ceiling** — tax never exceeds the configured rate. (`testFuzz_TaxNeverExceedsRate`)
6. `testFuzz_NeverOverPays` asserts `totalClaimed <= totalDeposited`. **This invariant is unfalsifiable** — `safeTransfer` reverts before an overpay is possible. It passed through a real solvency bug. Kept only as a regression tripwire; the meaningful property is 14 below.

### Asserted, including against real Uniswap on a mainnet fork

7. **Post-graduation cleanliness** — the curve holds zero ETH and zero tokens.
8. **LP is always burned** — all LP except Uniswap's `MINIMUM_LIQUIDITY` (1000 wei) goes to `0x…dEaD`. Nobody, including creator and protocol, ever holds LP.
9. **LP amount is the geometric mean** — `lpAmount == sqrt(ethForLp · tokensForLp) − 1000`, exact to the wei on a mainnet fork.
10. **The pool receives the full raise and the full tranche** — as WETH and tokens respectively.
11. **The pool seed is untaxed** — the curve is exempt from construction, so its seed transfer is not classified as a sell.
12. **The pair cannot be front-run** — it is created with the curve, so `createPair` reverts `PAIR_EXISTS` for anyone else, and `PoolLocked` rejects every transfer into it until graduation.
13. **Registered pair is the real pair** — `token.dexPair() == factory.getPair(token, WETH)`.
14. **Dividend solvency** — a wallet acquiring tokens after a deposit earns nothing from it, and `sum(pending) <= balanceOf(vault)`.
15. **Curve trades are untaxed**; **wallet-to-wallet is untaxed**; only transfers to/from `dexPair` are taxed.
16. **Referral commission stays with the referrer** — the NFT cannot be transferred, so the commission stream cannot be sold, gifted, or seized. Everything credited to an id is claimable by its original recipient and nothing else.
17. **No late-entrant exploitation in `RewardsDistributor`** — enrolment snapshots every known asset's accumulator.

### Intended but unstated in code

18. `purchased[]` never decreases — selling does not restore wallet-cap headroom. Deliberate anti-snipe behaviour; a consequence is that a capped buyer who sells cannot re-buy.
19. Tax applies only while `taxActive()`; `taxDurationDays == 0` means forever.
20. `MAX_TAX_BPS = 1000` (10%) is a hard per-side ceiling enforced at construction.

---

## 6. Fee and tax flows

### Bonding phase — 2% trade fee, both sides

```
fee = 2% of gross
  ├─ referralBps (10% of the fee) ──> ReferralNFT.credit(id)   [pending → referrer]
  └─ remainder ────────────────────> feeRecipient
```

If `credit` reverts, the whole fee goes to `feeRecipient`.

### Post-graduation — optional token tax

Asymmetric buy/sell tax (≤10% per side), collected in-token to the
`FeeSplitter`, split on `process()`:

```
accumulated tax
  ├─ liquidityBps  ──> addLiquidity()  — half swapped to ETH, paired, LP burned
  ├─ burnBps       ──> transfer to 0x…dEaD
  ├─ marketingBps  ──> payMarketing()  — swapped to ETH, forwarded
  └─ dividendBps   ──> payDividends()  — forwarded to DividendVault
```

The four must sum to exactly 10,000 bps or `FeeSplitter` construction reverts
(and `_deploySplitter` silently skips).

**Allocation accounting:** `process()` operates on
`balanceOf(this) − allocated()`, preventing already-earmarked tokens from being
re-split.

**Burn modes:** `Threshold` burns on every `process()`. `Weekly`/`Monthly` hold
the tranche until `burnDue()`. **Only `Threshold` is reachable — §7.**

---

## 7. Known gaps, accepted risks, and resolved findings

Stated explicitly so audit hours aren't spent rediscovering them.

### Resolved findings, recorded because the fixes are structural

**7.1 — Graduation was permanently blockable by anyone (critical, fixed).**

`_graduate` called `addLiquidityETH`, which quotes against whatever reserves
already exist and enforces a ratio against the caller's minimums (90%). An
attacker could buy tokens on the curve, create the TOKEN/WETH pair, seed it
with dust at an absurd price, and every subsequent graduation attempt would
revert `INSUFFICIENT_A_AMOUNT` → `MigrationFailed` → the graduating buy itself
reverts. The curve then sits permanently below target and the token can never
graduate. No admin can fix it. Holders can still `sell()`, so funds are not
stolen, but the launch is dead. Cost to the attacker: gas and a dust seed,
most of it recoverable.

Loosening the slippage floor was worse, not better: the attacker would then
dictate the opening price and skim the raise.

*Fix, in two halves.* The curve creates the pair in its own constructor, so
there is nothing left to race for. `MemeToken` then rejects every transfer
into that pair (`PoolLocked`) until the curve calls `setPoolSeeded()` at
graduation. Graduation wraps ETH, sends both sides to the pair, and calls
`pair.mint(BURN)` directly — taking the opening price from its own amounts
rather than negotiating with whatever is there.

The empty-pair guarantee is what makes the direct mint safe. If a griefer
could put tokens in early they would already hold LP, and `mint` would hand
them a proportional share of the raise. Donated *WETH* is still possible but
only increases the liquidity minted and burned.

*Reviewer attention:* this is the newest and most safety-critical change in
the system. `_registerPair` is gone; the router is no longer on the graduation
path and no longer needs a tax exemption.

*Coverage:* `test/ForkFrontrunGraduation.t.sol` (6 tests against real Uniswap).

**7.2 — `DividendVault` late-entrant insolvency (critical, fixed).**

`pending()` multiplied the holder's current balance by
`accPerToken - rewardDebt`, and `rewardDebt` was only written on claim
(`initialised` defaulted false → debt 0). A wallet acquiring tokens after
deposits had accrued appeared owed the entire historical per-token amount.
Independently, `eligibleSupply()` excludes `dexPair`, so buying from the pool
moved tokens from an excluded holder to an eligible one, growing eligible
supply after `accPerToken` was fixed against a smaller denominator —
amplifying the first cause roughly 4×.

*Impact.* Against a 1,000,000-token deposit with 490M eligible supply, a wallet
buying 400M from the pool afterwards showed 791,836 owed. Total owed across
three holders reached 1,199,999 — 120% of deposits. It did not surface as an
overpay but as an honest holder's `claim()` reverting with
`ERC20InsufficientBalance` once the pool ran dry. Extractable by watching for
`payDividends()`, buying, claiming, selling.

*Fix.* `MemeToken._update` calls `DividendVault.onBalanceChange` before any
balance moves. A receiver observed at zero balance is new and has `rewardDebt`
snapshotted to the current accumulator; a sender banks what it earned into
`claimable` before its balance drops. Same settle-on-transfer pattern as
`ReferralNFT._update`. Post-fix, total owed for that scenario is 408,163.

*Coverage:* `test/DividendVaultLateEntrant.t.sol` (6 tests).

### Functional gaps

**7.3 — `markMigrated` is never called in production.** No production path
invokes it; only tests do. No referral therefore reaches `Status.Genesis`,
`genesisNumber` stays 0, and `RewardsDistributor.enroll()` always reverts
`NotGenesis`. **The entire Genesis rewards pipeline is unreachable on-chain.**

**7.4 — `RewardsDistributor` is not deployed.** Neither deploy script
references it, and `DEPOSITOR_ROLE` is granted only in tests. Fully written,
11 passing tests, nothing on-chain can reach it. See §9 scope decision.

**7.5 — Burn mode is hardcoded** to `BurnMode.Threshold` in `_deploySplitter`.
`Weekly`/`Monthly` work in `FeeSplitter` but are unreachable from a launch.

**7.6 — Splitter threshold is hardcoded** at `curveSupply / 10_000` (0.01%).

**7.7 — Three of four dividend payout modes are unbuilt.** Only self-mode
(claim in the token itself) exists.

**7.8 — `referralCommissionBps` has no setter.** It is a public state variable
initialised to 1000 with no way to change it. Either make it `constant` or add
a setter; as written it costs a storage read while behaving like a constant.

**7.19 — `ReferralNFT` is soulbound, which orphans two things.**
`claimSettled()`, the `claimable` mapping, the `Settled` event, and the
settle-on-transfer block inside `_update` are all now unreachable: with `from`
always zero, nothing ever settles. They are retained deliberately so that
restoring transferability is a one-line change, but a reviewer should treat
them as dead code and confirm they cannot be reached by any path.

Separately, `RewardsDistributor`'s premise was that Genesis rewards follow NFT
ownership. Ownership can no longer change, so that subsystem is not merely
undeployed (7.3–7.4) but conceptually orphaned. See §9.

### Areas needing review attention

**7.9 — `FeeSplitter.addLiquidity` passes `0, 0`** as
`amountTokenMin`/`amountETHMin` to `addLiquidityETH`, accepting whatever ratio
the pool offers. The preceding swap is protected by `minEthOut`; the liquidity
add is not. This is the *router* path used post-graduation, distinct from the
graduation seed (§7.1) which no longer uses the router at all.

**7.10 — `ReferralNFT.credit(id)` does not verify** that `id` belongs to the
calling curve. Any `CREDITOR_ROLE` holder can credit any id. Only
factory-deployed curves hold the role and each credits only its own id, so
this is defence-in-depth rather than a live issue — but the check is absent.

**7.11 — `block.timestamp` comparisons** in `FeeSplitter.burnDue()` and
`MemeToken.taxActive()`. Both tolerate seconds of drift by design.

**7.12 — Unbounded `assets` array** in `RewardsDistributor`. `enroll()` and
`claimAll()` loop over it. Growth is gated by `DEPOSITOR_ROLE`, so it is
trusted-party bounded, not attacker bounded.

**7.13 — The token→vault callback** in `MemeToken._update` is the only place a
token transfer reaches back into launchpad state. It is not reentrancy-guarded,
deliberately: it runs inside a transfer that may itself sit inside a guarded
`claim()`. Access control is the `msg.sender == token` check.

### Operational constraints

**7.14 — EIP-170 headroom.** `CurveDeployer` sits at 16,941 / 24,576 bytes.
`SplitterDeployer` is separate. `forge build --sizes` exits non-zero on
overflow and runs in CI, so this is enforced rather than remembered. `via_ir`
and the optimizer are required to compile at all.

**7.15 — `optimizer_runs = 1`.** Tuned for deployment size, not runtime gas.
Every user transaction pays for this.

**7.16 — Taxed tokens cost more per transfer.** The `_update` override runs
even at zero tax, and once a vault exists each transfer makes an external call
to it.

**7.17 — `PUSH0` / EIP-3855 support on Robinhood Chain is unconfirmed.**
Foundry warns; deploys succeed.

### Product decisions with security-adjacent consequences

**7.18 — LP is burned, not locked.** Competing launchpads on this chain use
Uniswap v3 and lock the position in a no-withdraw locker, so it keeps earning
swap fees for the creator indefinitely. Burning to `0x…dEaD` is equally
unruggable but earns nothing. This is a deliberate V2 choice, not an oversight,
and changing it would mean rewriting the graduation path around the v3 position
manager.

---

## 8. Design decisions worth knowing

**Graduation mints directly; the router is not involved.** See §7.1. The
router remains a dependency only of `FeeSplitter`.

**The pair is created eagerly, at curve construction.** This costs gas on
every launch whether or not the token ever graduates. It buys the front-run
immunity in §7.1, and on an L2 the cost is a fraction of a cent.

**`MemeToken` stays inside `BondingCurve`'s constructor.** Moving its
deployment out (as was done for `FeeSplitter`/`DividendVault`) would mean
either passing in a pre-deployed token or a two-step init, both of which weaken
the guarantee that `MemeToken.curve` is immutable and the curve holds 100% of
supply from block one.

**Quoting is on-chain.** `quoteBuy`/`quoteSell` are view functions on the
curve. An earlier JavaScript reimplementation drifted from the contract —
specifically it ignored the `grossMax` partial-fill cap — producing slippage
mismatches. Frontends must not reimplement curve maths.

**LP burns to `0x…dEaD`, not `address(0)`.** OpenZeppelin v5 rejects minting
to the zero address, which would revert graduation.

**Bytecode isolation, twice.** `LaunchpadFactory` exceeded EIP-170 once it
embedded `BondingCurve`'s creation code, hence `CurveDeployer`. Later
`BondingCurve` exceeded it in turn, hence `SplitterDeployer`. Deploy order is
load-bearing: `CurveDeployer` and `SplitterDeployer` → `LaunchpadFactory`
(takes both) → `deployer.setFactory()`.

**The referral NFT is soulbound.** An affiliate commission — you introduce
someone, you earn a share of what they generate — is an ordinary commercial
arrangement. Tokenising the *right* to that commission and making it freely
tradeable turns it into something a buyer might acquire purely for income
produced by someone else's ongoing work, which is a materially different
instrument. The right therefore stays with the person who earned it.

Burning is blocked as well as transferring. The curve calls `credit(id)`
without checking ownership, so a burned id would keep accruing ETH that no
one could ever claim.

**Enrolment snapshots in `RewardsDistributor`, settle-on-transfer in
`DividendVault`.** Two different solutions to the same late-entrant problem,
because the NFT has a natural enrolment moment and the ERC-20 does not.

---

## 9. Audit scope

### In scope

`src/BondingCurve.sol`, `src/MemeToken.sol`, `src/CurveDeployer.sol`,
`src/SplitterDeployer.sol`, `src/DividendVault.sol`, `src/FeeSplitter.sol`,
`src/LaunchpadFactory.sol`, `src/ReferralNFT.sol`,
`src/interfaces/IUniswapV2Router.sol`

**Priority areas**, both recent and both safety-critical:

1. The graduation path (§7.1) — eager pair creation, the `PoolLocked` guard,
   and the direct `pair.mint`. This replaced a confirmed critical bug and is
   the least-aged code in the system.
2. The token→vault settle-on-transfer callback (§7.2, §7.13) — it runs on
   every transfer of every taxed token.
3. `ReferralNFT._update` (§7.19) — confirm the soulbound guard admits minting
   and nothing else, and that the retained settle block is genuinely
   unreachable.

### Out of scope

- `src/mocks/MockV2Router.sol` — test fixture, never deployed to mainnet.
- The frontend (`index.html`, `app.js`).
- Uniswap V2 itself; OpenZeppelin v5.

### Scope decision required

`src/RewardsDistributor.sol` — built and tested, but unreachable (§7.3–7.4)
*and* built on a premise the soulbound change removed (§7.19). Our current
intention is to exclude it. Auditing dead code is wasted spend.

If it is excluded, the unreachable settle-on-transfer machinery in
`ReferralNFT` (§7.19) should still be reviewed, since it lives in a contract
that is in scope.

### Prior verification already performed

- **103 unit tests**, 9 suites, 6 fuzz invariants.
- **14 fork tests** against the real Uniswap V2 deployment on a mainnet fork:
  `test/ForkGraduation.t.sol` (LP accounting, CREATE2 pair registration,
  pool-seed tax exemption, post-graduation taxed sell) and
  `test/ForkFrontrunGraduation.t.sol` (front-run immunity).
- Two critical bugs found in-house, reproduced, and fixed — §7.1 and §7.2.
- Uniswap addresses verified three ways: official deployments doc, on-chain
  bytecode, live `WETH()` call.
- CI enforces `forge fmt --check`, `forge build --sizes`, the unit suite, and
  the fork suite against a pinned block.

### Deployment addresses (mainnet, chainId 4663)

| Contract | Address |
|---|---|
| UniswapV2Router02 | `0x89e5DB8B5aA49aA85AC63f691524311AEB649eba` |
| UniswapV2Factory | `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

`DeployMainnet.s.sol` guards on `block.chainid == 4663` and locks the factory
at a 1000 ETH `deployFee` immediately after deployment, so the launchpad is
inert until deliberately opened.
