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

function setConnectLabel(text) {
  document.querySelectorAll('.connect-btn').forEach((b) => {
    b.textContent = text;
  });
}

function notify(msg) {
  // Reuses the existing toast element from the mint section.
  const toast = document.getElementById('toast');
  if (!toast) { console.log(msg); return; }
  toast.textContent = msg;
  toast.classList.add('show');
  setTimeout(() => toast.classList.remove('show'), 3200);
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

    const bal = await state.provider.getBalance(state.address);
    console.log('Balance:', ethers.formatEther(bal), 'ETH');
  } catch (err) {
    console.error(err);
    setConnectLabel('Connect wallet');
    notify(err.shortMessage || err.message || 'Connection failed');
  }
}

/* ---------- contracts ---------- */

const ADDR = {
  factory: '0xdF10fffa395bc65f429A6c2cC9C69279454301eF',
  nft:     '0xb2367529Ff5B56D3d968dD4b3A29C8a1beED6A52',
};

const FACTORY_ABI = [
  'function createToken((string,string,uint256,uint256,address,uint256)) payable returns (address,address,uint256)',
  'function deployFee() view returns (uint256)',
  'function launchCount() view returns (uint256)',
  'function getLaunches(uint256,uint256) view returns ((address,address,address,uint256,uint64)[])',
  'event TokenLaunched(address indexed creator, address indexed token, address curve, uint256 referralId, uint256 devBuy)',
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

  return {
    name:   document.getElementById('tokenName').value.trim(),
    symbol: document.getElementById('tokenTicker').value.trim(),
    maxSupply,
    capBps,
    referrer,
    devBuy,
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

    await factory.createToken.staticCall(
      [f.name, f.symbol, f.maxSupply, f.capBps, f.referrer, 0n],
      { value, from: state.address }
    );

    btn.textContent = 'Confirm in wallet…';

    const tx = await factory.createToken(
      [f.name, f.symbol, f.maxSupply, f.capBps, f.referrer, 0n],
      { value }
    );

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
    notify(err.shortMessage || err.reason || 'Deploy failed');
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

    const [name, symbol, collected, graduated] = await Promise.all([
      token.name(),
      token.symbol(),
      curve.ethCollected(),
      curve.graduated(),
    ]);

    const progress = Number((collected * 10000n) / ethers.parseEther('0.004')) / 100;

    return {
      curveAddr, tokenAddr, creator, referralId,
      name, symbol,
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
          <div class="tc-name">${t.name}</div>
          <div class="tc-ticker mono">${t.symbol}</div>
        </div>
        <div class="tc-badge">${t.graduated ? 'Graduated' : 'Curve'}</div>
      </div>
      <div class="mono" style="font-size:12px; color:var(--text-dim); margin:10px 0;">
        ${Number(ethers.formatEther(t.collected)).toFixed(6)} / 4 ETH · ${t.age}
      </div>
      <div class="snipe-bar"><div class="fill" style="width:${t.progress}%; background:var(--gold);"></div></div>
      <div class="tc-actions" style="display:flex; gap:0; margin-top:14px;">
        <button class="side-btn buy active" style="flex:1; padding:9px; background:rgba(62,240,140,.12); color:var(--gold); border:1px solid var(--line-soft); cursor:pointer; font-family:inherit;">Buy</button>
        <button class="side-btn sell" style="flex:1; padding:9px; background:transparent; color:var(--text-dim); border:1px solid var(--line-soft); cursor:pointer; font-family:inherit;">Sell</button>
      </div>
      <div style="display:flex; gap:8px; margin-top:10px;">
        <input class="trade-amt" placeholder="0.0 ETH"
          style="flex:1; padding:10px; background:var(--panel-2); border:1px solid var(--line-soft); color:var(--text); font-family:'JetBrains Mono',monospace; font-size:12.5px;">
        <button class="trade-go"
          style="padding:10px 14px; background:var(--gold); color:#0a0c0a; border:none; cursor:pointer; font-family:'JetBrains Mono',monospace; font-weight:600; font-size:12.5px;">Buy ${t.symbol}</button>
      </div>
      <div class="mono" style="font-size:11px; color:var(--text-faint); margin-top:8px;">${short(t.tokenAddr)}</div>
    `;

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
        notify(err.shortMessage || err.reason || 'Trade failed');
      } finally {
        goBtn.disabled = false;
        goBtn.textContent = label;
      }
    });

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
    sw.addEventListener('click', () => {
      sw.classList.toggle('on');
      const panel = sw.parentElement?.querySelector('.switch-panel')
                 || sw.closest('.field')?.querySelector('.snipe-panel');
      if (panel) panel.style.opacity = sw.classList.contains('on') ? '1' : '0.4';
    });
  });

  refreshExplore();

  console.log('NO SLEEP app.js loaded');
});
