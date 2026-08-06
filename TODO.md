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
