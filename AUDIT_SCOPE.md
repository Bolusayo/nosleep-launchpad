# No Sleep — Audit Scope and Change Log

**Repository:** github.com/Bolusayo/nosleep-launchpad
**Current commit:** `df65afe`
**Target chain:** Robinhood Chain (Arbitrum Orbit L2), chainId 4663
**Status:** not deployed to any public mainnet

Companion document: `SPEC.md` — system specification, invariants, known gaps,
and prior verification.

---

## 1. What we are asking for

We need a written report that names the commit hash it covers.

We hold a prior review, but it does not name a commit, so we cannot establish
which state of the code it examined. That is our problem to fix, not yours.
This document lists every change we can account for so you can tell us what
you are willing to attest to and quote accordingly.

Two possible shapes:

- **Diff review.** If you can confirm which commit your prior work covered, we
  will scope to the changes since. §3 lists candidates.
- **Full review at `df65afe`.** Cleaner, and what we would prefer if the prior
  scope cannot be established.

Either way the deliverable we need is a report naming a hash.

---

## 2. Why this matters more than usual here

Every contract is immutable. No upgrade path, no pause, no admin override, no
rescue function. The only post-deployment levers are `setDeployFee`,
`setFeeRecipient`, and a two-step ownership transfer. Anything wrong at
deployment is wrong permanently.

We expect meaningful user volume shortly after launch, and the platform will
be handed to an investor who will own the factory outright.

---

## 3. Commit history

Newest first. Everything listed is in `main`.

| Commit | Change | Contracts touched |
|---|---|---|
| `df65afe` | Two-step ownership; static admin page | `LaunchpadFactory` |
| `437c243` | `referralCommissionBps` made `constant` | `LaunchpadFactory` |
| `cf5f00f` | Bounded the sandwich surface on `addLiquidity` | `FeeSplitter` |
| `0a21cc3` | Referral NFT made soulbound | `ReferralNFT` |
| `d62a90e` | Frontend only — error decoding, polling, caching | none |
| `519ece0` | Documentation only | none |
| `d007c80` | Graduation rewritten to mint the pool directly | `BondingCurve`, `MemeToken`, interfaces, mock |
| `7d70a5a` | Documentation only | none |
| `f4044cf` | Dividend settle-on-transfer; `SplitterDeployer` extracted | `BondingCurve`, `MemeToken`, `DividendVault`, `SplitterDeployer` (new), `LaunchpadFactory`, `CurveDeployer` |

Earlier history is in the repository.

---

## 4. Changes we consider security-critical

Ordered by how much attention we think they deserve.

### 4.1 Graduation rewritten to mint the pool directly (`d007c80`)

**Why it changed.** `_graduate` called `router.addLiquidityETH` with 90%
minimums. Uniswap V2 quotes against existing reserves, so an attacker could
buy tokens on the curve, create the TOKEN/WETH pair, seed it with dust at an
absurd price, and every graduation attempt would then revert
`INSUFFICIENT_A_AMOUNT` → `MigrationFailed` → the graduating buy reverts with
it. The token could never graduate. No admin could fix it. Cost to the
attacker was gas plus a dust seed, most of it recoverable. We reproduced this
on a mainnet fork.

Loosening the minimums was worse: the attacker would then set the opening
price and skim the raise.

**What it does now.** `BondingCurve` creates the pair in its own constructor,
so there is nothing left to race for. `MemeToken` rejects every transfer into
that pair (`PoolLocked`) until the curve calls `setPoolSeeded()` at
graduation. Graduation wraps ETH, sends both sides to the pair, and calls
`pair.mint(BURN)` directly, taking the opening price from its own amounts.
`_registerPair` was removed; the router is no longer on the graduation path.

**What we would like checked.** That the empty-pair guarantee actually holds —
it is what makes the direct mint safe. If tokens could reach the pair before
graduation, the minter would already hold LP and `mint` would hand them a
share of the raise. Also whether donated WETH, which we believe only increases
the liquidity we mint and burn, can be turned into something worse.

### 4.2 Dividend settle-on-transfer (`f4044cf`)

**Why it changed.** `DividendVault.pending()` multiplied current balance by
`accPerToken - rewardDebt`, and `rewardDebt` was only written on claim, so it
read as zero for anyone who had never claimed. A wallet acquiring tokens after
deposits had accrued appeared owed the entire historical per-token amount.
`eligibleSupply()` excludes `dexPair`, so buying from the pool also grew
eligible supply after `accPerToken` was fixed against a smaller denominator.

Measured: total owed reached 120% of deposits. It surfaced not as an overpay
but as an honest holder's `claim()` reverting once the pool ran dry.

**What it does now.** `MemeToken._update` calls
`DividendVault.onBalanceChange` before any balance moves. A receiver observed
at zero balance is new and has `rewardDebt` snapshotted to the current
accumulator; a sender banks what it earned into `claimable` first.

**What we would like checked.** This callback runs on every transfer of every
taxed token and is the only place a token transfer reaches back into
launchpad state. It is deliberately not reentrancy-guarded, because it runs
inside a transfer that may itself sit inside a guarded `claim()`; access
control is a `msg.sender == token` check. We would like that judgement
reviewed.

### 4.3 Referral NFT made soulbound (`0a21cc3`)

`_update` now reverts on any transfer where `from` is non-zero. Minting works;
transfers, safe-transfers, and approved-spender transfers do not. Burning is
also blocked deliberately: the curve credits `pending[id]` without checking
ownership, so a burned id would accrue ETH nobody could claim.

This was a legal-posture decision, not a bug fix. The commission machinery is
unchanged.

**What we would like checked.** That the guard admits minting and nothing
else. Also that the now-unreachable settle-on-transfer code retained in
`_update`, along with `claimSettled()`, `claimable`, and the `Settled` event,
is genuinely unreachable. We kept it so restoring transferability is a
one-line change if counsel allows.

### 4.4 `FeeSplitter.addLiquidity` swap cap (`cf5f00f`)

`addLiquidity` is permissionless and `minEthOut` comes from the caller, so
`minEthOut` was never protection — an attacker sandwiching the swap calls it
themselves and passes zero. A V2 pool offers no manipulation-resistant price
to check on-chain either.

We now cap the swap at 1% of the pair's token reserve. Excess stays in
`liquidityPool` for the next call. We also added a 95% floor on the token side
of `addLiquidityETH`; the ETH side stays at zero because our own swap moves
the price against us and the router refunds the surplus.

**What we would like checked.** Whether the cap meaningfully bounds extraction
or whether repeated small calls reconstruct the same loss, and whether leaving
the ETH minimum at zero is right.

### 4.5 `SplitterDeployer` extracted (`f4044cf`)

The dividend fix pushed `CurveDeployer` 934 bytes past EIP-170.
`FeeSplitter`/`DividendVault` deployment moved into a separate contract,
mirroring the existing `CurveDeployer`/`LaunchpadFactory` split.
`CurveDeployer` went from 25,510 to 16,941 bytes.

Note `FeeSplitter` now records `SplitterDeployer` as its deployer, so that
contract — not the curve — is what may call `setDividendVault`. It does so
before returning.

### 4.6 Two-step ownership (`df65afe`)

`LaunchpadFactory` moved from `Ownable` to `Ownable2Step`. The owner controls
`setDeployFee` and `setFeeRecipient`, and the platform is being handed to an
investor, so a single mistyped character under single-step transfer would send
all revenue to an unrecoverable address.
### 4.7 ETH dividends: `EthDividendVault` and `FeeSplitter.DividendMode`

Holders could only ever be paid in the token itself. A launcher can now choose,
once and irreversibly at launch, to pay them in ETH instead.

`EthDividendVault` is a **new sibling** of `DividendVault`, not a modification
of it — the accounting is identical, including the settle-on-transfer fix in
4.2, so the already-reviewed self-mode path is byte-for-byte unchanged. Stray
ETH sent to the vault is deliberately held rather than credited to the
accumulator: crediting it would let anyone move every holder's entitlement by
sending dust.

`FeeSplitter` gained an immutable `DividendMode`. In `Eth` mode
`payDividends` swaps the dividend tranche for ETH through the router and calls
`depositEth`, under the same 1%-of-pool cap as `addLiquidity`. `BondingCurve`,
`CurveDeployer`, `SplitterDeployer` and `LaunchpadFactory` thread the choice
through; `LaunchpadFactory.LaunchParams` gained a `uint8 dividendMode` field,
so the struct is now sixteen fields.

**What we would like checked.** Whether the two vaults can diverge in any way a
holder could exploit; whether an ETH-mode vault can be made insolvent by the
swap returning less than expected; and whether `depositEth`'s `NoEligibleSupply`
revert can be used to grief a payout.

### 4.8 `FeeSplitter.payMarketing` swap cap

Found while preparing this deployment, not yet reviewed by anyone.

`addLiquidity` (4.4) and `payDividends` (4.7) both cap their swap at 1% of the
pair's token reserve, for the reason set out in 4.4. `payMarketing` did not —
it sold the whole `marketingPool` in one call. It is the same permissionless
shape with the same `minEthOut`-is-not-protection problem, so it was the
easiest of the three tranches to sandwich and the only one whose size was
unbounded.

It now takes the same cap, with the remainder left in `marketingPool` for the
next call. `test/FeeSplitterMarketingCap.t.sol` covers the cap, payout in
slices with nothing stranded, and that an allocation below the cap still
settles in one call.

**What we would like checked.** That this is now consistent across all three
swap paths, and that no fourth path sells without a cap.

---

## 5. Scope

### In scope

```
src/BondingCurve.sol
src/MemeToken.sol
src/CurveDeployer.sol
src/SplitterDeployer.sol
src/DividendVault.sol
src/EthDividendVault.sol
src/FeeSplitter.sol
src/LaunchpadFactory.sol
src/ReferralNFT.sol
src/interfaces/IUniswapV2Router.sol
```

### Out of scope

- `src/mocks/MockV2Router.sol` — test fixture, never deployed to mainnet
- `index.html`, `app.js`, `admin.html` — frontend
- Uniswap V2, OpenZeppelin v5

### Excluded deliberately, and we would like your view on this

`src/RewardsDistributor.sol` is written and tested but unreachable: no
production path calls `ReferralNFT.markMigrated`, so no referral ever reaches
Genesis status and `enroll()` always reverts. Neither deploy script deploys
it. Its premise — that rewards follow NFT ownership — was also removed by
§4.3, since ownership can no longer change.

We intend to exclude it rather than pay to review dead code, but if you think
its presence in the repository creates risk we would rather hear that.

---

## 6. Known gaps we are not asking you to find

Documented in full in `SPEC.md` §7. Summarised so you do not spend time
rediscovering them:

- `markMigrated` never called; Genesis pipeline inert
- `RewardsDistributor` not deployed
- Burn mode hardcoded to `Threshold`; `Weekly`/`Monthly` unreachable
- Splitter threshold hardcoded at `curveSupply / 10_000`
- Three of four dividend payout modes unbuilt
- `ReferralNFT.credit(id)` does not verify the id belongs to the calling curve
- `block.timestamp` comparisons in `FeeSplitter.burnDue()` and
  `MemeToken.taxActive()`
- Unbounded `assets` array in `RewardsDistributor`
- `optimizer_runs = 1`, tuned for size not runtime gas
- `PUSH0` / EIP-3855 support on Robinhood Chain unconfirmed

---

## 7. Testing

- 103 unit tests, 9 suites, 6 fuzz invariants, plus the ETH-dividend work:
  `test/EthDividendVault.t.sol` (17) and `test/FeeSplitterMarketingCap.t.sol` (7)
- 14 fork tests against the real Uniswap V2 deployment on a mainnet fork:
  `test/ForkGraduation.t.sol` and `test/ForkFrontrunGraduation.t.sol`, plus
  `test/ForkEthDividends.t.sol` (7), which swaps a real dividend tranche
  through the live router and checks the vault ends solvent
- CI enforces `forge fmt --check`, `forge build --sizes` (fails on EIP-170
  overflow), the unit suite, and the fork suite at a pinned block

One caveat we would rather state than have found: `testFuzz_NeverOverPays` in
`DividendVault.t.sol` asserts `totalClaimed <= totalDeposited`, which
`safeTransfer` makes unfalsifiable — it reverts before an overpay is possible.
It passed through the bug in §4.2. We have left it as a regression tripwire
and added the meaningful property separately, but it is a fair indication that
our other invariants deserve the same scrutiny.

---

## 8. Build

```
Foundry, solc 0.8.28 pinned in foundry.toml
via_ir = true, optimizer = true, optimizer_runs = 1
OpenZeppelin Contracts v5
```

`via_ir` and the optimizer are required — the contracts do not compile without
them, and `CurveDeployer` does not fit under EIP-170.

```bash
git clone --recursive https://github.com/Bolusayo/nosleep-launchpad
cd nosleep-launchpad
git checkout <the ETH-dividend commit — fill in before sending>
forge build
forge test --no-match-path 'test/Fork*.t.sol'
```

Fork tests need an RPC:

```bash
forge test --match-path 'test/Fork*.t.sol' \
  --fork-url https://rpc.mainnet.chain.robinhood.com
```
