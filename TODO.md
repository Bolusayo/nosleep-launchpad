# NO SLEEP — TODO

## Before mainnet (non-negotiable)
- [ ] Restore `VIRTUAL_QUOTE = 3 ether` and `QUOTE_TARGET = 4 ether` in `src/BondingCurve.sol`
- [ ] Restore matching `0.003` / `0.004` literals in `quoteBuy()` in `app.js`
- [ ] Swap MockV2Router for real Uniswap V2 router on chain 4663:
      `0x89e5db8b5aa49aa85ac63f691524311aeb649eba`
      (factory `0x8bceaa40b9acdfaedf85adf4ff01f5ad6517937f`)
- [ ] Fresh deployer key — the testnet key was exposed in chat
- [ ] Security audit before any real money
- [ ] Legal review: referral NFT paying platform revenue looks like a security

## Frontend bugs found on testnet
- [ ] Anti-snipe toggle does not respond to clicks; `readForm()` always returns `capBps: 200n`.
      No token launched from the form can graduate (2% cap needs 50 wallets).
- [ ] `renderLive()` uses `innerHTML`, leaving stale listeners after each refresh
- [ ] Card labels and progress bar still hardcode `4 ETH`
- [ ] Browser caches `app.js` — edits need Ctrl+Shift+R

## Verify
- [ ] `lpAmount` from MockV2Router is ~100x smaller than expected geometric mean.
      Check against real Uniswap router before mainnet.
- [ ] Confirm `PUSH0` / EIP-3855 support on Robinhood Chain (Foundry warns, deploys work)

## Not built yet
- [ ] `RewardsDistributor` (PDF spec: modular payouts from all products)
- [ ] Trading tax, dividends, burn scheduler
- [ ] Referral dashboard wired to chain
- [ ] Off-chain storage for token images and descriptions
- [ ] `@handle` → wallet resolver (needs a backend)

## Deployed (testnet 46630)
- MockV2Router: `0x9a2c5699f98e3fCB7B65cf1a5AE09A8DEC700BFc`
- ReferralNFT: `0xb2367529Ff5B56D3d968dD4b3A29C8a1beED6A52`
- LaunchpadFactory: `0xdF10fffa395bc65f429A6c2cC9C69279454301eF`
- First graduated token: GHA `0x587d...BaD1`

## Error handling (high priority)
- [ ] `notify()` writes to the mint page's toast, invisible on the launchpad page.
      Every failed trade shows the user nothing — button just flicks back to "Buy".
      Needs a toast that renders on whichever page is active.
- [ ] Add `quoteBuy(uint256) view returns (uint256)` to BondingCurve so the frontend
      can get an exact quote instead of reimplementing curve maths in JS.
- [ ] Check wallet balance before simulating; "missing revert data" with `data=null`
      usually means insufficient funds, not a contract problem.

## Done (this session)
- [x] Anti-snipe toggle wired in app.js
- [x] quoteBuy/quoteSell moved on-chain; JS reimplementation deleted
- [x] Balance check before simulating
- [x] Input validation rejects non-numeric amounts
- [x] LIBYA graduated via UI in two clicks — no console

## Current testnet deployment (supersedes earlier addresses)
- MockV2Router: 0xA13218B5F8099cE7C197C7f451DB77D56f59f093
- ReferralNFT: 0x4dc3FD897b93A9624EA9B7d696aE24c8f5e5767a
- LaunchpadFactory: 0x73fB4AA7933CDA3bEa496ee0C5f1a637CB4B68C4

## Tax system — verify before mainnet
- [ ] `_registerPair` tested only against MockV2Factory. Real Uniswap creates the
      pair inside addLiquidityETH via CREATE2. Confirm setDexPair-after-migration
      ordering still avoids taxing the initial pool seed.
- [ ] Taxed tokens cost ~22% more gas per transfer (the _update override runs
      even at zero tax). Consider a separate untaxed token contract.

## Contract size (EIP-170)
- [ ] CurveDeployer is at 22,905 / 24,576 bytes — only 1,671 spare.
      Run `forge build --sizes` after any change to BondingCurve, MemeToken,
      FeeSplitter or DividendVault. When it overflows, split again.
- [ ] Deployment order now matters: CurveDeployer → LaunchpadFactory →
      deployer.setFactory(). See script/DeployStack.s.sol.
