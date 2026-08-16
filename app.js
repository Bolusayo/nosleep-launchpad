/* ===========================================================
   NO SLEEP — Robinhood Chain integration layer
   Binds to the existing markup. Does not modify it.
   =========================================================== */

const CHAIN = {
  chainId: '0xB626',                  // 46630
  chainName: 'Robinhood Chain Testnet',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: ['https://rpc.testnet.chain.robinhood.com'],
  blockExplorerUrls: ['https://explorer.testnet.chain.robinhood.com'],
};

const state = {
  provider: null,
  signer: null,
  address: null,
};

/* ---------- helpers ---------- */

const short = (a) => a.slice(0, 6) + '…' + a.slice(-4);

// Escapes user-controlled strings (token name/symbol/description, etc.)
// before they're interpolated into innerHTML. Anyone can deploy a token
// via LaunchpadFactory with arbitrary name/symbol/description, so these
// values must never be trusted as raw HTML.
function escapeHtml(str) {
  if (str === null || str === undefined) return '';
  return String(str).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  }[c]));
}

function setConnectLabel(text) {
  document.querySelectorAll('.connect-btn').forEach((b) => {
    b.textContent = text;
  });
}

function notify(msg, kind = 'info') {
  console.log('[notify]', msg);

  let el = document.getElementById('nsToast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'nsToast';
    el.style.cssText = `
      position: fixed; left: 50%; bottom: 32px; transform: translateX(-50%) translateY(20px);
      max-width: min(560px, 90vw); padding: 13px 20px;
      background: #10130f; border: 1px solid #2a2f27; border-left-width: 3px;
      color: #e8ece4; font-family: 'JetBrains Mono', ui-monospace, monospace;
      font-size: 13px; line-height: 1.45; letter-spacing: -0.01em;
      z-index: 99999; opacity: 0; pointer-events: none;
      transition: opacity .22s ease, transform .22s ease;
      box-shadow: 0 12px 40px rgba(0,0,0,.55);
      word-break: break-word;
    `;
    document.body.appendChild(el);
  }

  const accent = kind === 'error' ? '#d1574a'
               : kind === 'success' ? '#3ef08c'
               : '#c9a227';
  el.style.borderLeftColor = accent;
  el.textContent = msg;

  requestAnimationFrame(() => {
    el.style.opacity = '1';
    el.style.transform = 'translateX(-50%) translateY(0)';
  });

  clearTimeout(el._t);
  el._t = setTimeout(() => {
    el.style.opacity = '0';
    el.style.transform = 'translateX(-50%) translateY(20px)';
  }, kind === 'error' ? 6000 : 3400);
}

/* ---------- wallet ---------- */

async function ensureNetwork() {
  try {
    await window.ethereum.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: CHAIN.chainId }],
    });
  } catch (err) {
    // 4902 = chain unknown to the wallet, so add it.
    if (err.code === 4902 || err?.data?.originalError?.code === 4902) {
      await window.ethereum.request({
        method: 'wallet_addEthereumChain',
        params: [CHAIN],
      });
    } else {
      throw err;
    }
  }
}

async function connect() {
  if (!window.ethereum) {
    notify('No wallet found — install MetaMask');
    return;
  }

  try {
    setConnectLabel('Connecting…');
    await window.ethereum.request({ method: 'eth_requestAccounts' });
    await ensureNetwork();

    state.provider = new ethers.BrowserProvider(window.ethereum);
    state.signer   = await state.provider.getSigner();
    state.address  = await state.signer.getAddress();

    setConnectLabel(short(state.address));
    console.log('Connected:', state.address);

    renderReferrals();

    const bal = await state.provider.getBalance(state.address);
    console.log('Balance:', ethers.formatEther(bal), 'ETH');
  } catch (err) {
    console.error(err);
    setConnectLabel('Connect wallet');
    notify(err.shortMessage || err.message || 'Connection failed', 'error');
  }
}

/* ---------- contracts ---------- */

const TARGET_ETH = '0.004';   // TESTNET — restore to '4' before mainnet
const ADDR = {
  factory: '0x3296ee0ebB5c079f251Ec3eeB62f790Ef9529EAb',
  nft:     '0x035Cb2fdeB18f4d7EF3D406e7d4e33299ca56bb2',
};

const FACTORY_ABI = [
  'function deployFee() view returns (uint256)',
  'function launchCount() view returns (uint256)',
  'function getLaunches(uint256,uint256) view returns ((address,address,address,uint256,uint64)[])',
  'event TokenLaunched(address indexed creator, address indexed token, address curve, uint256 referralId, uint256 devBuy)',
  'function createToken((string,string,uint256,uint256,address,uint256,uint16,uint16,uint32,address,uint16,uint16,uint16,uint16,string)) payable returns (address,address,uint256)',
  'function metadataURI(address) view returns (string)',
];

function factoryContract(runner) {
  return new ethers.Contract(ADDR.factory, FACTORY_ABI, runner);
}

/* ---------- deploy ---------- */


function readForm() {
  const exp = parseFloat(document.getElementById('supplySlider').value);
  const maxSupply = BigInt(Math.round(Math.pow(10, exp)));

  const snipeOn  = document.getElementById('snipeSwitch').classList.contains('on');
  const capPct   = parseFloat(document.getElementById('snipeCap').value);
  const capBps   = snipeOn ? BigInt(Math.round(capPct * 100)) : 0n;

  const refOn    = document.getElementById('refSwitch').classList.contains('on');
  const refRaw   = document.getElementById('refWallet').value.trim();
  const referrer = (refOn && ethers.isAddress(refRaw)) ? refRaw : ethers.ZeroAddress;

  const devBuyRaw = document.getElementById('devBuyAmt').value.trim();
  const devBuy    = devBuyRaw ? ethers.parseEther(devBuyRaw) : 0n;

  // Tax is only meaningful when the switch is on.
  const taxOn = document.getElementById('taxSwitch')?.classList.contains('on');
  const pct   = (id) => BigInt(Math.round(parseFloat(document.getElementById(id).value) * 100));

  const buyTaxBps  = taxOn ? pct('buyTax')  : 0n;
  const sellTaxBps = taxOn ? pct('sellTax') : 0n;
  const taxDays    = taxOn ? BigInt(parseInt(document.getElementById('taxDur').value, 10)) : 0n;

  const mktRaw    = document.getElementById('mktWallet').value.trim();
  const marketing = ethers.isAddress(mktRaw) ? mktRaw : ethers.ZeroAddress;

  const liquidityBps = taxOn ? pct('lpBps')   : 0n;
  const burnBps      = taxOn ? pct('burnBps') : 0n;
  const marketingBps = taxOn ? pct('mktBps')  : 0n;
  const dividendBps  = taxOn ? pct('divBps2') : 0n;

  const desc = document.getElementById('tokenDesc')?.value.trim() || '';
  const metadata = desc ? JSON.stringify({ description: desc }) : '';

  return {
    name:   document.getElementById('tokenName').value.trim(),
    symbol: document.getElementById('tokenTicker').value.trim(),
    maxSupply, capBps, referrer, devBuy,
    buyTaxBps, sellTaxBps, taxDays,
    marketing, liquidityBps, burnBps, marketingBps, dividendBps,
    taxOn,
    metadata,
  };
}

async function deployToken() {
  const btn = document.querySelector('.launch-btn');
  if (!state.signer) { await connect(); if (!state.signer) return; }

  const f = readForm();

  if (!f.name || !f.symbol) { notify('Name and ticker are required'); return; }
  if (f.maxSupply < 1_000_000n || f.maxSupply > 1_000_000_000_000n) {
    notify('Supply must be between 1M and 1T'); return;
  }

  const original = btn.textContent;
  btn.disabled = true;

  try {
    const factory = factoryContract(state.signer);
    const fee     = await factory.deployFee();
    const value   = fee + f.devBuy;

    const params = [
      f.name, f.symbol, f.maxSupply, f.capBps, f.referrer, 0n,
      f.buyTaxBps, f.sellTaxBps, f.taxDays,
      f.marketing, f.liquidityBps, f.burnBps, f.marketingBps, f.dividendBps,
      f.metadata
    ];

    await factory.createToken.staticCall(params, { value, from: state.address });

    btn.textContent = 'Confirm in wallet…';
    const tx = await factory.createToken(params, { value });

    btn.textContent = 'Deploying…';
    notify('Transaction sent — waiting for confirmation');

    const receipt = await tx.wait();

    // Pull the addresses out of the TokenLaunched event.
    const iface = new ethers.Interface(FACTORY_ABI);
    let token, curve;
    for (const log of receipt.logs) {
      try {
        const parsed = iface.parseLog(log);
        if (parsed?.name === 'TokenLaunched') {
          token = parsed.args.token;
          curve = parsed.args.curve;
        }
      } catch { /* not our event */ }
    }

    console.log('Token:', token, '\nCurve:', curve);
    notify(`${f.symbol} launched — ${short(token)}`);
    btn.textContent = 'Deployed ✓';
    setTimeout(() => { btn.textContent = original; btn.disabled = false; }, 4000);
  } catch (err) {
    console.error(err);
    notify(err.shortMessage || err.reason || 'Deploy failed', 'error');
    btn.textContent = original;
    btn.disabled = false;
  }
}


/* ---------- explore ---------- */

const CURVE_ABI = [
  'function quoteReserve() view returns (uint256)',
  'function tokenReserve() view returns (uint256)',
  'function ethCollected() view returns (uint256)',
  'function graduated() view returns (bool)',
  'function curveSupply() view returns (uint256)',
  'function maxBuyPerWallet() view returns (uint256)',
  'function quoteBuy(uint256) view returns (uint256 tokensOut, uint256 ethAccepted)',
  'function quoteSell(uint256) view returns (uint256)',
  'function buy(uint256) payable',
  'function sell(uint256,uint256)',
  'function dividendVault() view returns (address)',
  'function splitter() view returns (address)',
];

const TOKEN_ABI = [
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function balanceOf(address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
];

function readProvider() {
  return state.provider ?? new ethers.JsonRpcProvider(CHAIN.rpcUrls[0]);
}

function ageLabel(ts) {
  const s = Math.floor(Date.now() / 1000) - Number(ts);
  if (s < 60)    return `${s}s ago`;
  if (s < 3600)  return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

async function fetchLaunches() {
  const provider = readProvider();
  const factory  = factoryContract(provider);

  const count = await factory.launchCount();
  if (count === 0n) return [];

  const raw = await factory.getLaunches(0, 100);

  return Promise.all(raw.map(async (l) => {
    const [curveAddr, tokenAddr, creator, referralId, createdAt] = l;
    const curve = new ethers.Contract(curveAddr, CURVE_ABI, provider);
    const token = new ethers.Contract(tokenAddr, TOKEN_ABI, provider);

    const [name, symbol, collected, graduated, meta] = await Promise.all([
      token.name(),
      token.symbol(),
      curve.ethCollected(),
      curve.graduated(),
      factory.metadataURI(tokenAddr).catch(() => ''),
    ]);

    let description = '';
    try { description = meta ? (JSON.parse(meta).description || '') : ''; } catch {}

    const progress = Number((collected * 10000n) / ethers.parseEther('0.004')) / 100;

    return {
      curveAddr, tokenAddr, creator, referralId,
      name, symbol, description,
      collected,
      graduated,
      progress: Math.min(progress, 100),
      status: graduated ? 'graduated' : (progress < 10 ? 'new' : 'curve'),
      age: ageLabel(createdAt),
    };
  }));
}

let LIVE = [];
let liveTab = 'new';

function renderLive() {
  const grid = document.getElementById('tokenGrid');
  if (!grid) return;

  const rows = LIVE.filter((t) => t.status === liveTab);

  document.getElementById('cntNew').textContent   = LIVE.filter(t => t.status === 'new').length;
  document.getElementById('cntCurve').textContent = LIVE.filter(t => t.status === 'curve').length;
  document.getElementById('cntGrad').textContent  = LIVE.filter(t => t.status === 'graduated').length;

  grid.innerHTML = '';

  if (rows.length === 0) {
    const empty = document.createElement('div');
    empty.style.cssText = 'color:var(--text-faint); font-family:JetBrains Mono,monospace; font-size:13px; padding:24px 0;';
    empty.textContent = 'No tokens in this category yet.';
    grid.appendChild(empty);
    return;
  }

  for (const t of rows) {
    const card = document.createElement('div');
    card.className = 'token-card';
    card.innerHTML = `
      <div class="tc-head">
        <div class="tc-icon">◆</div>
        <div class="tc-id">
          <div class="tc-name">${escapeHtml(t.name)}</div>
          <div class="tc-ticker mono">${escapeHtml(t.symbol)}</div>
        </div>
        <div class="tc-badge">${t.graduated ? 'Graduated' : 'Curve'}</div>
      </div>
      <div class="mono" style="font-size:12px; color:var(--text-dim); margin:10px 0;">
        ${Number(ethers.formatEther(t.collected)).toFixed(6)} / ${TARGET_ETH} ETH · ${t.age}
      </div>
       ${t.description ? `<div style="font-size:12px; color:var(--text-dim); margin:8px 0; line-height:1.5;">${escapeHtml(t.description.slice(0, 140))}</div>` : ''}
      <div class="snipe-bar"><div class="fill" style="width:${t.progress}%; background:var(--gold);"></div></div>
      ${t.graduated ? `
      <div class="mono" style="margin-top:14px; padding:10px; text-align:center; background:rgba(62,240,140,.08); border:1px solid var(--line-soft); color:var(--gold); font-size:12px;">Trading on Uniswap · curve closed</div>
      ` : `
      <div class="tc-actions" style="display:flex; gap:0; margin-top:14px;">
        <button class="side-btn buy active" style="flex:1; padding:9px; background:rgba(62,240,140,.12); color:var(--gold); border:1px solid var(--line-soft); cursor:pointer; font-family:inherit;">Buy</button>
        <button class="side-btn sell" style="flex:1; padding:9px; background:transparent; color:var(--text-dim); border:1px solid var(--line-soft); cursor:pointer; font-family:inherit;">Sell</button>
      </div>
      <div style="display:flex; gap:8px; margin-top:10px;">
        <input class="trade-amt" placeholder="0.0 ETH" style="flex:1; padding:10px; background:var(--panel-2); border:1px solid var(--line-soft); color:var(--text); font-family:'JetBrains Mono',monospace; font-size:12.5px;">
        <button class="trade-go" style="padding:10px 14px; background:var(--gold); color:#0a0c0a; border:none; cursor:pointer; font-family:'JetBrains Mono',monospace; font-weight:600; font-size:12.5px;">Buy ${escapeHtml(t.symbol)}</button>
      </div>
      `}
      <div class="mono" style="font-size:11px; color:var(--text-faint); margin-top:8px;">${short(t.tokenAddr)}
      </div>
      <div class="div-slot"></div>
    `;
    if (!t.graduated) {
    let side = 'buy';
    const buyBtn  = card.querySelector('.side-btn.buy');
    const sellBtn = card.querySelector('.side-btn.sell');
    const amtEl   = card.querySelector('.trade-amt');
    const goBtn   = card.querySelector('.trade-go');

    function setSide(s) {
      side = s;
      const on = s === 'buy';
      buyBtn.style.background  = on ? 'rgba(62,240,140,.12)' : 'transparent';
      buyBtn.style.color       = on ? 'var(--gold)' : 'var(--text-dim)';
      sellBtn.style.background = on ? 'transparent' : 'rgba(209,87,74,.12)';
      sellBtn.style.color      = on ? 'var(--text-dim)' : 'var(--red)';
      amtEl.placeholder        = on ? '0.0 ETH' : `0.0 ${t.symbol}`;
      goBtn.textContent        = on ? `Buy ${t.symbol}` : `Sell ${t.symbol}`;
      goBtn.style.background   = on ? 'var(--gold)' : 'var(--red)';
    }

    buyBtn.addEventListener('click', () => setSide('buy'));
    sellBtn.addEventListener('click', () => setSide('sell'));

    goBtn.addEventListener('click', async () => {
      const v = amtEl.value.trim();
      if (!v || Number(v) <= 0) { notify('Enter an amount'); return; }
      goBtn.disabled = true;
      const label = goBtn.textContent;
      goBtn.textContent = 'Working…';
      try {
        if (side === 'buy') await doBuy(t, v);
        else                await doSell(t, v);
        amtEl.value = '';
      } catch (err) {
        console.error(err);
        notify(err.shortMessage || err.reason || 'Trade failed', 'error');
      } finally {
        goBtn.disabled = false;
        goBtn.textContent = label;
      }
    });
    }


    // Graduated tokens may have claimable dividends. Checked lazily so an
    // absent vault never blocks the card from rendering.
    if (t.graduated && state.address) {
      pendingDividends(t.curveAddr).then((amt) => {
        if (amt === 0n) return;

        const slot = card.querySelector('.div-slot');
        const btn2 = document.createElement('button');
        btn2.textContent = `Claim ${Number(ethers.formatUnits(amt, 18)).toLocaleString(undefined, {maximumFractionDigits: 2})} ${t.symbol}`;
        btn2.style.cssText = `
          width:100%; margin-top:10px; padding:10px;
          background:rgba(201,162,39,.15); color:var(--gold);
          border:1px solid var(--gold); cursor:pointer;
          font-family:'JetBrains Mono',monospace; font-size:12px; font-weight:600;
        `;
        btn2.addEventListener('click', async () => {
          btn2.disabled = true;
          const label = btn2.textContent;
          btn2.textContent = 'Claiming…';
          try {
            await claimDividends(t);
          } catch (err) {
            console.error(err);
            notify(err.shortMessage || 'Claim failed', 'error');
            btn2.textContent = label;
            btn2.disabled = false;
          }
        });
        slot.appendChild(btn2);
      }).catch(() => { /* no vault on this token */ });
    }
   
    grid.appendChild(card);
  }
}

async function refreshExplore() {
  try {
    LIVE = await fetchLaunches();
    renderLive();
    console.log(`Explore: ${LIVE.length} live token(s)`);
  } catch (err) {
    console.error('Explore refresh failed:', err);
  }
}

/* ---------- trading ---------- */

const SLIPPAGE_BPS = 300n; // 3% tolerance

/// Mirrors the contract's curve maths exactly, including ceilDiv rounding.

async function curveState(curveAddr) {
  const c = new ethers.Contract(curveAddr, CURVE_ABI, readProvider());
  const [q, t] = await Promise.all([c.quoteReserve(), c.tokenReserve()]);
  return { q, t };
}

async function doBuy(t, ethAmount) {
  if (!state.signer) { await connect(); if (!state.signer) return; }

  if (!/^\d*\.?\d+$/.test(ethAmount)) {
    notify('Enter a valid number, e.g. 0.005');
    return;
  }
  const value = ethers.parseEther(ethAmount);

  // Check funds first — insufficient balance surfaces as an undecodable
  // revert otherwise, which is impossible to diagnose.
  const bal = await state.provider.getBalance(state.address);
  if (bal < value) {
    notify(`Insufficient balance — you have ${ethers.formatEther(bal)} ETH`);
    return;
  }

  const curve = new ethers.Contract(t.curveAddr, CURVE_ABI, state.signer);

  // Ask the contract for the exact quote instead of recomputing it here.
  const [expected] = await curve.quoteBuy(value);
  const minOut = (expected * (10000n - SLIPPAGE_BPS)) / 10000n;

  await curve.buy.staticCall(minOut, { value, from: state.address });

  notify(`Buying ~${Number(ethers.formatUnits(expected, 18)).toLocaleString()} ${t.symbol}`);
  const tx = await curve.buy(minOut, { value });
  await tx.wait();

  notify(`Bought ${t.symbol}`);
  await refreshExplore();
}

async function doSell(t, tokenAmount) {
  if (!state.signer) { await connect(); if (!state.signer) return; }

  const amount = ethers.parseUnits(tokenAmount, 18);
  const token  = new ethers.Contract(t.tokenAddr, TOKEN_ABI, state.signer);

  const bal = await token.balanceOf(state.address);
  if (bal < amount) { notify(`You only hold ${ethers.formatUnits(bal, 18)} ${t.symbol}`); return; }

  const curveRead = new ethers.Contract(t.curveAddr, CURVE_ABI, readProvider());
  const expected  = await curveRead.quoteSell(amount);
  const minOut   = (expected * (10000n - SLIPPAGE_BPS)) / 10000n;

  notify('Approving…');
  const approveTx = await token.approve(t.curveAddr, amount);
  await approveTx.wait();

  const curve = new ethers.Contract(t.curveAddr, CURVE_ABI, state.signer);
  await curve.sell.staticCall(amount, minOut, { from: state.address });

  notify(`Selling for ~${ethers.formatEther(expected)} ETH`);
  const tx = await curve.sell(amount, minOut);
  await tx.wait();

  notify(`Sold ${t.symbol}`);
  await refreshExplore();
}


/* ---------- dividends ---------- */

const VAULT_ABI = [
  'function pending(address) view returns (uint256)',
  'function claim()',
  'function accPerToken() view returns (uint256)',
  'function totalDeposited() view returns (uint256)',
];

async function vaultFor(curveAddr) {
  const c = new ethers.Contract(curveAddr, CURVE_ABI, readProvider());
  const v = await c.dividendVault();
  return v === ethers.ZeroAddress ? null : v;
}

async function pendingDividends(curveAddr) {
  if (!state.address) return 0n;
  const v = await vaultFor(curveAddr);
  if (!v) return 0n;
  const vault = new ethers.Contract(v, VAULT_ABI, readProvider());
  return await vault.pending(state.address);
}

async function claimDividends(t) {
  if (!state.signer) { await connect(); if (!state.signer) return; }

  const v = await vaultFor(t.curveAddr);
  if (!v) { notify('This token has no dividend vault', 'error'); return; }

  const vault = new ethers.Contract(v, VAULT_ABI, state.signer);
  const amount = await vault.pending(state.address);
  if (amount === 0n) { notify('Nothing to claim yet'); return; }

  await vault.claim.staticCall({ from: state.address });

  notify(`Claiming ${Number(ethers.formatUnits(amount, 18)).toLocaleString()} ${t.symbol}`);
  const tx = await vault.claim();
  await tx.wait();

  notify(`Claimed ${t.symbol} dividends`, 'success');
  await refreshExplore();
}

/* ---------- referral dashboard ---------- */

const NFT_ABI = [
  'function nextId() view returns (uint256)',
  'function ownerOf(uint256) view returns (address)',
  'function pending(uint256) view returns (uint256)',
  'function claimable(address) view returns (uint256)',
  'function referrals(uint256) view returns (address token, address curve, string name, string ticker, uint64 launchDate, uint64 migrationDate, uint32 genesisNumber, uint16 commissionBps, uint8 status, uint256 lifetimeCommissions)',
  'function claim(uint256)',
  'function claimSettled()',
];

function nftContract(runner) {
  return new ethers.Contract(ADDR.nft, NFT_ABI, runner);
}

/// Walks every minted NFT and keeps the ones this wallet owns.
/// Fine at testnet scale; swap for event indexing once volume grows.
async function myReferrals() {
  if (!state.address) return [];

  const nft   = nftContract(readProvider());
  const total = Number(await nft.nextId());
  const mine  = [];

  for (let id = 1; id < total; id++) {
    let owner;
    try { owner = await nft.ownerOf(id); } catch { continue; }
    if (owner.toLowerCase() !== state.address.toLowerCase()) continue;

    const r = await nft.referrals(id);
    mine.push({
      id,
      token: r.token,
      curve: r.curve,
      name: r.name,
      ticker: r.ticker,
      launchDate: Number(r.launchDate),
      status: Number(r.status),      // 0 curve, 1 migrated, 2 genesis
      genesisNumber: Number(r.genesisNumber),
      lifetime: r.lifetimeCommissions,
      pending: await nft.pending(id),
    });
  }
  return mine;
}

function statusLabel(s, g) {
  if (s === 2) return `Genesis #${String(g).padStart(3, '0')}`;
  if (s === 1) return 'Migrated';
  return 'On curve';
}

async function renderReferrals() {
  const body = document.getElementById('refTableBody');
  if (!body) return;

  if (!state.address) {
    document.getElementById('refCountStat').textContent  = '0';
    document.getElementById('refActiveStat').textContent = '0';
    document.getElementById('refEarnedStat').textContent = '0 ETH';
    document.getElementById('refClaimStat').textContent  = '0 ETH';
    body.innerHTML = `<tr><td colspan="6" style="padding:20px; color:var(--text-faint); font-family:'JetBrains Mono',monospace; font-size:12px;">Connect a wallet to see your referrals.</td></tr>`;
    return;
  }

  const rows = await myReferrals();
  const nft  = nftContract(readProvider());
  const settled = await nft.claimable(state.address);

  let lifetime = 0n, claimable = settled, active = 0;
  for (const r of rows) {
    lifetime  += r.lifetime;
    claimable += r.pending;
    if (r.status === 0) active += 1;
  }

  document.getElementById('refCountStat').textContent  = rows.length;
  document.getElementById('refActiveStat').textContent = active;
  document.getElementById('refEarnedStat').textContent = `${Number(ethers.formatEther(lifetime)).toFixed(6)} ETH`;
  document.getElementById('refClaimStat').textContent  = `${Number(ethers.formatEther(claimable)).toFixed(6)} ETH`;

  const link = document.getElementById('refLinkInput');
  if (link) link.value = state.address;

  if (rows.length === 0) {
    body.innerHTML = `<tr><td colspan="6" style="padding:20px; color:var(--text-faint); font-family:'JetBrains Mono',monospace; font-size:12px;">No referrals yet. Share your address as the referrer when someone launches.</td></tr>`;
    return;
  }

  body.innerHTML = '';
  for (const r of rows) {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td style="padding:12px 8px;">${escapeHtml(r.name)} <span class="mono" style="color:var(--text-dim);">$${escapeHtml(r.ticker)}</span></td>
      <td class="mono" style="padding:12px 8px; font-size:11px; color:var(--text-dim);">${short(r.token)}</td>
      <td class="mono" style="padding:12px 8px; font-size:12px;">${ageLabel(r.launchDate)}</td>
      <td class="mono" style="padding:12px 8px; font-size:12px; color:var(--gold);">${statusLabel(r.status, r.genesisNumber)}</td>
      <td class="mono" style="padding:12px 8px; font-size:12px;">${Number(ethers.formatEther(r.lifetime)).toFixed(6)} ETH</td>
      <td style="padding:12px 8px;"></td>
    `;

    if (r.pending > 0n) {
      const btn = document.createElement('button');
      btn.textContent = `Claim ${Number(ethers.formatEther(r.pending)).toFixed(6)}`;
      btn.style.cssText = `padding:6px 10px; background:var(--gold); color:#0a0c0a; border:none; cursor:pointer; font-family:'JetBrains Mono',monospace; font-size:11px; font-weight:600;`;
      btn.addEventListener('click', async () => {
        btn.disabled = true;
        btn.textContent = 'Claiming…';
        try {
          const w = nftContract(state.signer);
          await (await w.claim(r.id)).wait();
          notify(`Claimed referral #${r.id}`, 'success');
          await renderReferrals();
        } catch (err) {
          console.error(err);
          notify(err.shortMessage || 'Claim failed', 'error');
          btn.disabled = false;
        }
      });
      tr.lastElementChild.appendChild(btn);
    }

    body.appendChild(tr);
  }
}

/* ---------- wiring ---------- */

document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('.connect-btn').forEach((btn) => {
    btn.addEventListener('click', connect);
  });

  document.querySelector('.launch-btn')?.addEventListener('click', deployToken);

  if (window.ethereum) {
    window.ethereum.on('accountsChanged', (accts) => {
      if (accts.length === 0) {
        state.signer = null;
        state.address = null;
        setConnectLabel('Connect wallet');
      } else {
        connect();
      }
    });
    window.ethereum.on('chainChanged', () => window.location.reload());
  }

  document.querySelectorAll('#exploreTabs .tab-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopImmediatePropagation();
      liveTab = btn.dataset.tab === 'graduated' ? 'graduated' : btn.dataset.tab;
      document.querySelectorAll('#exploreTabs .tab-btn')
        .forEach(b => b.classList.toggle('active', b === btn));
      renderLive();
    }, { capture: true });
  });

  // Original script declares these switches but never binds them.
  document.querySelectorAll('.switch').forEach((sw) => {
    sw.addEventListener('click', (e) => {
      e.stopImmediatePropagation();
      sw.classList.toggle('on');
    }, { capture: true });
  });

  // Only self-mode dividends are implemented. Mark the rest clearly rather
  // than letting someone pick ETH and silently receive tokens.
  document.querySelectorAll('#divAsset .seg-opt').forEach((opt) => {
    if (opt.dataset.v === 'self') return;

    opt.style.opacity       = '0.35';
    opt.style.cursor        = 'not-allowed';
    opt.title               = 'Not yet implemented — dividends pay in the token itself';
    opt.textContent        += ' · soon';

    opt.addEventListener('click', (e) => {
      e.stopImmediatePropagation();
      e.preventDefault();
      notify('Only self-mode dividends are live. ETH, ERC-20 and stock payouts are coming.', 'error');
    }, { capture: true });
  });

  refreshExplore();
  renderReferrals();

  console.log('NO SLEEP app.js loaded');
});
