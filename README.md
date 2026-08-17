# No Sleep

A permissionless memecoin launchpad on [Robinhood Chain](https://docs.robinhood.com/chain)
(Arbitrum Orbit L2, chainId 4663).

One transaction deploys a token, a bonding curve holding its entire supply, and
optionally a tradeable referral NFT. Tokens sell on a constant-product curve
with virtual reserves until a fixed 4 ETH target is reached, then migrate
automatically to a Uniswap V2 pool with liquidity permanently burned.

See [`SPEC.md`](./SPEC.md) for the full system specification, invariants, and
known gaps. See [`TODO.md`](./TODO.md) for current status.

> ⚠️ **Not audited. Not deployed to mainnet.** Do not use with real funds.

## Contracts

| Contract | Responsibility |
|---|---|
| `BondingCurve` | Curve maths, trading, graduation to Uniswap. Deploys its own token. |
| `MemeToken` | Fixed-supply ERC-20 with optional asymmetric buy/sell tax. |
| `LaunchpadFactory` | Entry point — atomic launch, dev buy, referral mint. |
| `CurveDeployer` | Bytecode isolation so the factory fits under EIP-170. |
| `ReferralNFT` | ERC-721 referral rights; commission follows the holder. |
| `FeeSplitter` | Post-graduation tax split four ways, pull-based. |
| `DividendVault` | Proportional dividend claims for token holders. |
| `RewardsDistributor` | Multi-asset rewards for Genesis NFT holders (not yet wired). |
| `MockV2Router` | Testnet Uniswap stand-in. Never deployed to mainnet. |

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Solidity 0.8.28
- `via_ir` and the optimizer are **required** — the contracts do not compile
  without them (stack depth), and `CurveDeployer` does not fit under EIP-170.

## Setup

```bash
git clone --recursive https://github.com/Bolusayo/nosleep-launchpad
cd nosleep-launchpad
forge build
```

If you cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

## Test

```bash
forge test                        # 95 tests, 8 suites
forge build --sizes               # check EIP-170 headroom after any change
```

Fork tests run graduation against the **real** Uniswap V2 deployment and are
excluded from the default run because they need a mainnet RPC:

```bash
forge test --match-path test/ForkGraduation.t.sol -vv \
  --fork-url https://rpc.mainnet.chain.robinhood.com
```

## Deploy

Set `PRIVATE_KEY` in `.env` (gitignored).

Deployment order is load-bearing: `CurveDeployer` → `LaunchpadFactory` →
`deployer.setFactory()`. Both scripts handle this.

### Testnet (chainId 46630)

Uses `MockV2Router`, since there is no Uniswap deployment on testnet.

```bash
forge script script/DeployStack.s.sol \
  --rpc-url https://rpc.testnet.chain.robinhood.com \
  --broadcast
```

### Mainnet (chainId 4663)

Uses the canonical Uniswap V2 router. Guarded by a `block.chainid` check.

```bash
# dry run first — omit --broadcast
forge script script/DeployMainnet.s.sol \
  --rpc-url https://rpc.mainnet.chain.robinhood.com

# then, with a key that has never been exposed anywhere
forge script script/DeployMainnet.s.sol \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --broadcast --verify
```

## Frontend

`index.html` + `app.js`, vanilla JS with ethers.js. Connects a wallet, adds
Robinhood Chain automatically, renders a live Explore grid from `getLaunches()`,
and trades against the curve using on-chain quotes.

**Frontends must not reimplement curve maths** — call `quoteBuy()` /
`quoteSell()`. An earlier JS reimplementation ignored the partial-fill cap and
produced slippage mismatches.

## Reference addresses (mainnet, 4663)

| Contract | Address |
|---|---|
| UniswapV2Router02 | `0x89e5DB8B5aA49aA85AC63f691524311AEB649eba` |
| UniswapV2Factory | `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |

## License

MIT
