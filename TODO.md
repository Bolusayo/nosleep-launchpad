# NO SLEEP — TODO

## Before mainnet (non-negotiable)

- [ ] **Security audit.** No amount of green tests substitutes for this. See
      `SPEC.md` §9 for scope, and §7 for the known-gaps list to hand over.
- [ ] **Legal review: referral NFT.** It pays a share of platform revenue to
      holders and trades on a secondary market. That combination looks like a
      security. Get a lawyer to say so or not — do not reason about this
      internally. Do the scoping call *before* the audit: if the NFT needs
      restructuring, you do not want to have paid to audit the old version.
- [ ] **Fresh deployer key.** The testnet key was pasted into a chat and must
      be treated as permanently compromised. Generate the mainnet key locally,
      never paste it anywhere, and confirm `echo $PRIVATE_KEY` is the new one
      immediately before broadcasting.
- [ ] **Rotate the Alchemy API key.** It appeared in a screenshot. Read-only,
      so low severity, but rotate it and update the `RH_MAINNET_RPC_URL`
      GitHub secret.

## Done

- [x] Restore `VIRTUAL_QUOTE = 3 ether` / `QUOTE_TARGET = 4 ether`. Tests read
      the constants off the contract, so none needed editing.
- [x] Swap MockV2Router for the real Uniswap V2 router. `DeployMainnet.s.sol`
      written with a `block.chainid == 4663` guard. Dry-run clean, ~0.000436 ETH.
- [x] Escape user-supplied token metadata before `innerHTML` (XSS). Six
      interpolation points in `app.js` via `escapeHtml()`.
- [x] Correct the `20×` graduation multiple in `index.html` — the curve is
      scale-invariant and always rises 6.33×.
- [x] Remove the hardcoded local solc path from `foundry.toml` that had been
      silently breaking CI, and pin `solc_version = "0.8.28"`.
- [x] Real README and `SPEC.md` for audit prep.
- [x] **Fix `DividendVault` late-entrant insolvency.** Confirmed vulnerability:
      total owed reached 120% of deposits and honest holders' claims reverted.
      Fixed with a settle-on-transfer hook. Full write-up in `SPEC.md` §7.6;
      reproduction in `test/DividendVaultLateEntrant.t.sol`.
- [x] **Extract `SplitterDeployer`** to get back under EIP-170. `CurveDeployer`
      25,510 → 16,427, and curve deployment costs ~1.8M less gas.

## Verified Uniswap V2 addresses (Robinhood Chain mainnet, 4663)

Confirmed three ways: Uniswap's official deployments doc, on-chain bytecode,
and a live `WETH()` call. Re-verify before changing.

| Contract | Address |
|---|---|
| UniswapV2Router02 | `0x89e5DB8B5aA49aA85AC63f691524311AEB649eba` |
| UniswapV2Factory  | `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` |
| WETH              | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

## Deployment

Order is load-bearing: `CurveDeployer` + `SplitterDeployer` →
`LaunchpadFactory` (takes both) → `deployer.setFactory()`.

- Testnet: `script/DeployStack.s.sol` (MockV2Router — correct, there is no real
  DEX on testnet).
- Mainnet: `script/DeployMainnet.s.sol` (real router, chainid-guarded).

## Testing

- Default local run: `forge test --no-match-path 'test/Fork*.t.sol'` — 101 tests.
  The bare `forge test` fails by design, because the fork suite's `setUp()`
  requires `--fork-url`.
- Fork suite: 8 tests against the real Uniswap deployment. Runs in CI on every
  push, pinned to a block, using a non-public RPC secret.
- `forge build --sizes` exits non-zero on EIP-170 overflow and runs in CI, so
  contract size is now enforced rather than remembered.

## Still open — contracts

- [ ] **`markMigrated` is never called in production.** Only tests call it. No
      referral therefore reaches `Status.Genesis`, `genesisNumber` stays 0, and
      `RewardsDistributor.enroll()` always reverts `NotGenesis`. The entire
      Genesis rewards pipeline is unreachable on-chain. Wire it in `_graduate()`
      or accept that Genesis is inert — but decide deliberately.
- [ ] **`RewardsDistributor` is not deployed.** Neither script references it and
      `DEPOSITOR_ROLE` is granted only in tests. 153 lines, 11 passing tests,
      completely unreachable. Wire it or cut it from audit scope; do not pay to
      review dead code.
- [ ] `MockV2Router.lpAmount` is wrong by ~100x. The real router returns the
      exact geometric mean (fork-verified). Fix the mock or drop its LP
      assertions, so the mock suite stops asserting something false.
- [ ] `DividendVault.t.sol` constructs an unwired vault, so its 8 tests do not
      exercise the settle-on-transfer hook — they validate a configuration that
      cannot occur in production. Add `token.setDividendVault(address(vault))`
      to its `setUp`. Same class of problem as the role-grant note below.
- [ ] Burn mode is hardcoded to `Threshold` in `_deploySplitter`.
      Weekly/Monthly work in `FeeSplitter` but are unreachable from a launch.
- [ ] Splitter threshold is hardcoded at `curveSupply / 10_000`.
- [ ] `FeeSplitter.addLiquidity` passes `0, 0` as min amounts to
      `addLiquidityETH`. The preceding swap is protected by `minEthOut`; the
      liquidity add is not.
- [ ] `ReferralNFT.credit(id)` does not verify that `id` belongs to the calling
      curve. Currently only factory-deployed curves hold `CREDITOR_ROLE` and
      each credits only its own id, so this is defence-in-depth — but absent.
- [ ] Taxed tokens now cost more per transfer than before: the `_update`
      override runs even at zero tax, and the dividend hook adds an external
      call once a vault exists.
- [ ] Confirm `PUSH0` / EIP-3855 support on Robinhood Chain (Foundry warns,
      deploys work).

## Testing discipline

- [ ] Tests must grant exactly the roles the deploy scripts grant, never more.
      A `DEFAULT_ADMIN_ROLE` grant in `LaunchpadFactory.t.sol` hid a production
      failure through 95 green tests. Audit every `setUp()` against both
      `DeployStack.s.sol` and `DeployMainnet.s.sol`.
- [ ] Beware invariants that cannot fail. `testFuzz_NeverOverPays` asserted
      `totalClaimed <= totalDeposited`, which `safeTransfer` makes
      unfalsifiable — it reverts before an overpay is possible. It passed
      through a real solvency bug. Ask of every invariant: what state would
      make this red?

## Still open — frontend

- [ ] Re-confirm the anti-snipe toggle responds to clicks on testnet. Old notes
      list it as both broken and fixed; trust nothing until clicked by hand.
- [ ] `renderLive()` uses `innerHTML`, leaving stale listeners after each refresh.
- [ ] Browser caches `app.js` — edits need Ctrl+Shift+R. Consider a
      cache-busting query string on the script tag.
- [ ] `notify()` writes to the mint page's toast, invisible on the launchpad
      page. Every failed trade shows the user nothing — the button just flicks
      back to "Buy". Needs a toast that renders on whichever page is active.

## Not built yet

- [ ] Three of four dividend payout modes (only self-mode ships).
- [ ] Two of three burn schedules (see hardcoded Threshold above).
- [ ] Referral dashboard wired to chain.
- [ ] Off-chain storage for token images and descriptions (Pinata).
- [ ] Automatic `enroll` after graduation.
- [ ] `@handle` → wallet resolver (needs a backend).

## Current testnet deployment (46630)

Predates `SplitterDeployer`, so it is not redeployable from the current scripts
without a fresh deploy.

- MockV2Router:     `0x968181dFf370182E05d295bb33Eb455b5389775A`
- CurveDeployer:    `0x8988D503412149100A69469c32d0549f65d215C1`
- ReferralNFT:      `0x0D88EC6D54F994514ceB97F6e675090AE9643392`
- LaunchpadFactory: `0x29443615ff549bc2AF60e3B5d670fE6F7630Cb02`
