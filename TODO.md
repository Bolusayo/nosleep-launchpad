# NO SLEEP — TODO

## Before mainnet (non-negotiable)

- [ ] **Security audit** — no amount of green tests substitutes for this.
- [ ] **Legal review: referral NFT.** It pays a share of platform revenue to
      holders and trades on a secondary market. That combination looks like a
      security. Get a lawyer to say so or not — do not reason about this
      internally.
- [ ] **Fresh deployer key.** The testnet key was pasted into a chat and must be
      treated as permanently compromised. Generate the mainnet key locally,
      never paste it anywhere, and confirm `echo $PRIVATE_KEY` is the new one
      immediately before broadcasting.
- [x] Restore `VIRTUAL_QUOTE = 3 ether` / `QUOTE_TARGET = 4 ether` in
      `src/BondingCurve.sol` — done; all 95 tests pass at the new scale
      (tests read the constants off the contract, so none needed editing).
- [x] Swap MockV2Router for the real Uniswap V2 router on chain 4663 —
      `script/DeployMainnet.s.sol` written, dry-run clean.

## Verified Uniswap V2 addresses (Robinhood Chain mainnet, 4663)

Confirmed three independent ways: Uniswap's official deployments doc, the
on-chain bytecode (canonical UniswapV2Router02 revert strings + embedded
immutables), and a live `WETH()` call. Re-verify before changing.

| Contract | Address |
|---|---|
| UniswapV2Router02 | `0x89e5DB8B5aA49aA85AC63f691524311AEB649eba` |
| UniswapV2Factory  | `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` |
| WETH              | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

## Deployment

- Order matters: `CurveDeployer` → `LaunchpadFactory` → `deployer.setFactory()`.
- Testnet: `script/DeployStack.s.sol` (uses MockV2Router — correct, there is no
  real DEX on testnet to point at).
- Mainnet: `script/DeployMainnet.s.sol` (real router, plus a
  `require(block.chainid == 4663)` guard so it cannot be run against the wrong
  network by accident).
- [ ] Dry-run cost was ~0.000436 ETH. Fund the new deployer key accordingly.

## Resolved by the fork test

`test/ForkGraduation.t.sol` runs graduation against the real Uniswap deployment.
All 8 pass. This closed three long-standing unknowns:

- [x] **`lpAmount` was NOT ~100x off.** That was a MockV2Router artifact. Against
      the real router `lpAmount` equals `sqrt(eth * tokens) - MINIMUM_LIQUIDITY`
      exactly to the wei (28284271247461900975033), and
      `pair.totalSupply() - burned == 1000`. Do not "fix" BondingCurve to match
      the mock — the mock is the thing that is wrong.
- [x] **`_registerPair` works against real CREATE2.** The address stored on the
      token matches `factory.getPair()` exactly.
- [x] **The pool seed is not taxed.** The full 20% tranche reaches the pair, so
      the `setDexPair`-after-migration ordering is correct.
- [x] **Sell tax works against a real pair** (new coverage — never tested before).
      1000 bps sell tax split exactly: 10% to collector, 90% delivered.

- [ ] Wire the fork test into CI so a future change to `_migrate` fails loudly.
      See `ci-fork-job.yml`. Needs a non-public RPC secret and a pinned block.

## Still open — contracts

- [ ] `MockV2Router.lpAmount` is wrong by ~100x. Either fix the mock to return
      the geometric mean or delete the LP assertions from the mock tests, so the
      mock suite stops asserting behaviour that contradicts reality.
- [ ] Burn mode is hardcoded to Threshold in `BondingCurve._deploySplitter`.
      Weekly/Monthly work in the contract but aren't reachable from the form.
- [ ] Taxed tokens cost ~22% more gas per transfer (the `_update` override runs
      even at zero tax). Consider a separate untaxed token contract.
- [ ] Confirm `PUSH0` / EIP-3855 support on Robinhood Chain (Foundry warns,
      deploys work).

## Contract size (EIP-170)

- [ ] `CurveDeployer` is at 23,586 / 24,576 — 990 bytes spare. Run
      `forge build --sizes` after **every** change to BondingCurve, MemeToken,
      FeeSplitter or DividendVault. When it overflows, split again.

## Testing discipline

- [ ] Tests must grant exactly the roles the deploy scripts grant, never more.
      A `DEFAULT_ADMIN_ROLE` grant in `LaunchpadFactory.t.sol` hid a production
      failure through 95 green tests. Audit every `setUp()` against both
      `DeployStack.s.sol` and `DeployMainnet.s.sol`.

## Still open — frontend

- [x] Escape token descriptions before rendering — done. `escapeHtml()` added in
      `app.js`, applied at all 6 innerHTML interpolation points (card name,
      symbol, description, buy button label, referral row name and ticker).
- [x] Card label hardcoding `4 ETH` — no longer a bug now that the contract is
      back to a 4 ETH target. The figure is correct.
- [x] The `20×` graduation multiple in `index.html` was wrong — the curve is
      scale-invariant and always rises 6.33×. Copy corrected.
- [ ] Re-confirm the anti-snipe toggle actually responds to clicks on testnet.
      It is listed as both broken and fixed in the old notes; trust nothing
      until it is clicked by hand.
- [ ] `renderLive()` uses `innerHTML`, leaving stale listeners after each refresh.
- [ ] Browser caches `app.js` — edits need Ctrl+Shift+R. Consider a cache-busting
      query string on the script tag.
- [ ] `notify()` writes to the mint page's toast, invisible on the launchpad page.
      Every failed trade shows the user nothing — the button just flicks back to
      "Buy". Needs a toast that renders on whichever page is active.

## Not built yet

- [ ] Three of the dividend payout modes (only self-mode ships).
- [ ] Two of the burn schedules (see hardcoded Threshold above).
- [ ] Referral dashboard wired to chain.
- [ ] Off-chain storage for token images and descriptions (Pinata).
- [ ] Automatic `enroll` after graduation.
- [ ] `@handle` → wallet resolver (needs a backend).

## Current testnet deployment (46630)

- MockV2Router:     `0x968181dFf370182E05d295bb33Eb455b5389775A`
- CurveDeployer:    `0x8988D503412149100A69469c32d0549f65d215C1`
- ReferralNFT:      `0x0D88EC6D54F994514ceB97F6e675090AE9643392`
- LaunchpadFactory: `0x29443615ff549bc2AF60e3B5d670fE6F7630Cb02`

Earlier testnet addresses have been removed — they were superseded three times
and kept getting mistaken for current. Check the explorer if you need history.
