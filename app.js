/* ===========================================================
   NO SLEEP — Robinhood Chain integration layer
   Binds to the existing markup. Does not modify it.
   =========================================================== */

const CHAIN = {
  chainId: '0x1237',                  // 4663 — Robinhood Chain mainnet
  chainName: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: ['https://rpc.mainnet.chain.robinhood.com'],
  blockExplorerUrls: ['https://explorer.chain.robinhood.com'],
};

const state = {
  provider: null,
  signer: null,
  address: null,
};

/* ---------- helpers ---------- */

const short = (a) => a.slice(0, 6) + '…' + a.slice(-4);

/* ---------- token image upload (Pinata / IPFS) ----------
   Optional by design. A launch must never be blocked by an image failing to
   upload, so every failure path here degrades to "no image" rather than
   stopping the launch.

   The JWT below sits in client-side code and is readable by anyone who views
   source. Scope it to file-write only in the Pinata dashboard -- never admin.
   Worst case with a write-only key is wasted storage quota; an admin key
   would let someone delete every token image on the platform.              */

const PINATA_JWT = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VySW5mb3JtYXRpb24iOnsiaWQiOiJiMTEzOGI5MC1iMDczLTQyYWUtODZiNy03NTQ2ZWVkMDc3YjYiLCJlbWFpbCI6ImJvbHV3YXRpZmVvbHVzYXlvQHlhaG9vLmNvbSIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlLCJwaW5fcG9saWN5Ijp7InJlZ2lvbnMiOlt7ImRlc2lyZWRSZXBsaWNhdGlvbkNvdW50IjoxLCJpZCI6IkZSQTEifSx7ImRlc2lyZWRSZXBsaWNhdGlvbkNvdW50IjoxLCJpZCI6Ik5ZQzEifV0sInZlcnNpb24iOjF9LCJtZmFfZW5hYmxlZCI6ZmFsc2UsInN0YXR1cyI6IkFDVElWRSJ9LCJhdXRoZW50aWNhdGlvblR5cGUiOiJzY29wZWRLZXkiLCJzY29wZWRLZXlLZXkiOiI0NjMxZmVjMjVhZTBlYzQ0NGE1ZCIsInNjb3BlZEtleVNlY3JldCI6IjM1NGUwMzcwYTMwYTEwNjlhYWFkZGMyNGQwYzI0M2ZlZDIwYjEyZmUxN2U0ZGY5ZDc0NzE2OWE5NTJlZTA1NzUiLCJleHAiOjE4MjEwOTc1MjJ9.vwxVw-gHimImph28AKZ_LqpqCNTd9o2Q0r2iHQZqT1U';
const PINATA_GATEWAY = 'https://gateway.pinata.cloud/ipfs/';
const MAX_IMAGE_BYTES = 2 * 1024 * 1024; // 2MB, matching the form's own copy

let uploadedImageUrl = '';

async function uploadToPinata(file) {
  if (!PINATA_JWT || PINATA_JWT.startsWith('PASTE_')) {
    throw new Error('Image uploads are not configured yet.');
  }

  const body = new FormData();
  body.append('file', file);
  body.append('pinataMetadata', JSON.stringify({ name: file.name }));

  const res = await fetch('https://api.pinata.cloud/pinning/pinFileToIPFS', {
    method: 'POST',
    headers: { Authorization: `Bearer ${PINATA_JWT}` },
    body,
  });

  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`Pinata ${res.status}: ${text.slice(0, 120)}`);
  }

  const { IpfsHash } = await res.json();
  if (!IpfsHash) throw new Error('Pinata returned no hash.');
  return PINATA_GATEWAY + IpfsHash;
}

function wireImageUpload() {
  const box     = document.getElementById('imgBox');
  const input   = document.getElementById('imgInput');
  const preview = document.getElementById('imgPreview');
  const icon    = document.getElementById('imgIcon');
  const label   = document.getElementById('imgLabel');
  if (!box || !input) return;

  const setLabel = (html) => { if (label) label.innerHTML = html; };

  async function handle(file) {
    if (!file) return;

    if (!file.type.startsWith('image/')) {
      setLabel('That file is not an image. Pick a PNG, JPG, GIF or WebP.');
      return;
    }
    if (file.size > MAX_IMAGE_BYTES) {
      const mb = (file.size / 1024 / 1024).toFixed(1);
      setLabel(`That image is ${mb}MB. The limit is 2MB — try a smaller one.`);
      return;
    }

    // Show it immediately; the upload can take a moment.
    if (preview) {
      preview.src = URL.createObjectURL(file);
      preview.style.display = 'block';
      if (icon) icon.style.display = 'none';
    }
    setLabel('Uploading…');

    try {
      uploadedImageUrl = await uploadToPinata(file);
      setLabel(`${file.name} &middot; <span style="color:var(--gold, #3ddc84)">ready</span>`);
    } catch (err) {
      console.error('Image upload failed:', err);
      uploadedImageUrl = '';
      // Deliberately not a blocking error: the launch can still go ahead.
      setLabel(
        'Image upload failed, so this token will launch without one.<br>' +
        '<span style="color:var(--text-faint); font-size:11.5px;">Click to try again.</span>'
      );
    }
  }

  box.addEventListener('click', () => input.click());
  input.addEventListener('change', () => handle(input.files[0]));

  ['dragenter', 'dragover'].forEach((ev) =>
    box.addEventListener(ev, (e) => {
      e.preventDefault();
      box.style.borderColor = 'var(--gold, #3ddc84)';
    })
  );
  ['dragleave', 'drop'].forEach((ev) =>
    box.addEventListener(ev, (e) => {
      e.preventDefault();
      box.style.borderColor = '';
    })
  );
  box.addEventListener('drop', (e) => handle(e.dataTransfer?.files?.[0]));
}

/* ---------- error messages ----------
   Ethers reports a reverted call as "missing revert data" or a bare custom
   error selector. Neither means anything to someone trying to buy a token.
   Every message below is written to tell the person what to do next.        */

const ERROR_MESSAGES = {
  // BondingCurve
  SlippageExceeded:  'Price moved while your trade was pending. Try again, or use a smaller amount.',
  AlreadyGraduated:  'This token has finished its curve and now trades on Uniswap.',
  WalletCapExceeded: 'That would put you over this token\'s per-wallet limit.',
  ZeroAmount:        'Enter an amount above zero.',
  MigrationFailed:   'Graduation could not complete. Nothing was taken from your wallet.',
  // MemeToken
  PoolLocked:        'This token cannot trade on Uniswap until its curve completes.',
  TaxTooHigh:        'Tax cannot exceed 10% per side.',
  SupplyOutOfRange:  'Supply must be between 1,000,000 and 1,000,000,000,000.',
  // ReferralNFT
  Soulbound:         'Referral NFTs cannot be transferred. Commission stays with the referrer.',
  NothingToClaim:    'There is nothing to claim yet.',
  NotOwner:          'Only the holder of this NFT can claim.',
  // shared
  ZeroAddress:       'That address is not valid.',
  SendFailed:        'The ETH transfer failed. If you are using a contract wallet, it may reject plain transfers.',
  TransferFailed:    'The token transfer failed.',
};

/// Turns whatever ethers threw into a sentence worth showing someone.
function friendlyError(err, fallback = 'Transaction failed') {
  if (!err) return fallback;

  // The user changed their mind. Not an error worth a red toast.
  if (err.code === 'ACTION_REJECTED' || err.code === 4001) return null;

  // A named custom error from one of our contracts.
  const name = err?.revert?.name
    || err?.info?.error?.data?.name
    || (typeof err?.shortMessage === 'string'
        && Object.keys(ERROR_MESSAGES).find((k) => err.shortMessage.includes(k)));
  if (name && ERROR_MESSAGES[name]) return ERROR_MESSAGES[name];

  const raw = [err.shortMessage, err.reason, err.message]
    .filter((x) => typeof x === 'string').join(' | ');

  if (/insufficient funds/i.test(raw)) {
    return 'Not enough ETH to cover this trade plus gas.';
  }
  // Simulation reverted with no data. Almost always an unfunded wallet
  // rather than a contract problem -- see TODO.md.
  if (/missing revert data|CALL_EXCEPTION|could not coalesce/i.test(raw)) {
    return 'The transaction would fail. Usually this means not enough ETH for the amount plus gas.';
  }
  if (/nonce/i.test(raw))            return 'Your wallet is out of sync. Reset the account in your wallet settings and retry.';
  if (/replacement.*underpriced/i.test(raw)) return 'You already have a pending transaction. Wait for it to confirm.';
  if (/gas required exceeds/i.test(raw))     return 'This transaction needs more gas than your wallet allows.';
  if (/network|timeout|fetch|ECONN/i.test(raw)) {
    return 'Could not reach the network. Check your connection and try again.';
  }
  if (/user rejected|denied/i.test(raw)) return null;

  // Nothing matched. Show the shortest thing we have rather than a stack.
  return err.shortMessage || err.reason || fallback;
}

/// notify() wrapper that swallows user-cancelled actions.
function notifyError(err, fallback) {
  const msg = friendlyError(err, fallback);
  if (msg) notify(msg, 'error');
}

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

/// Menu anchored under whichever connect button was clicked. Built on
/// demand rather than living in the markup, because there is one button in
/// the nav and another in the launchpad header.
function toggleWalletMenu(btn) {
  const open = document.getElementById('walletMenu');
  if (open) { open.remove(); return; }

  const rect = btn.getBoundingClientRect();
  const menu = document.createElement('div');
  menu.id = 'walletMenu';
  menu.style.cssText = [
    'position:fixed',
    `top:${rect.bottom + 6}px`,
    `right:${Math.max(8, window.innerWidth - rect.right)}px`,
    'z-index:99998',
    'min-width:210px',
    'background:#101410',
    'border:1px solid rgba(255,255,255,.12)',
    'border-radius:8px',
    "font-family:'JetBrains Mono',monospace",
    'font-size:12px',
    'box-shadow:0 10px 30px rgba(0,0,0,.5)',
    'overflow:hidden',
  ].join(';');

  const head = document.createElement('div');
  head.style.cssText =
    'padding:10px 12px;border-bottom:1px solid rgba(255,255,255,.08);color:#7d8a7d;word-break:break-all;line-height:1.5;';
  head.textContent = state.address;
  menu.appendChild(head);

  const item = (label, onClick) => {
    const el = document.createElement('div');
    el.textContent = label;
    el.style.cssText = 'padding:10px 12px;cursor:pointer;color:#dfe6df;';
    el.addEventListener('mouseenter', () => { el.style.background = 'rgba(255,255,255,.05)'; });
    el.addEventListener('mouseleave', () => { el.style.background = 'transparent'; });
    el.addEventListener('click', async () => { menu.remove(); await onClick(); });
    menu.appendChild(el);
    return el;
  };

  item('Copy address', async () => {
    try {
      await navigator.clipboard.writeText(state.address);
      notify('Address copied');
    } catch {
      notify('Your browser blocked clipboard access', 'error');
    }
  });

  item('View on explorer', async () => {
    const base = (CHAIN.blockExplorerUrls && CHAIN.blockExplorerUrls[0]) || '';
    if (!base) { notify('No explorer configured', 'error'); return; }
    window.open(base.replace(/\/+$/, '') + '/address/' + state.address, '_blank', 'noopener');
  });

  const dc = item('Disconnect', async () => disconnect());
  dc.style.color = '#e06c5a';
  dc.style.borderTop = '1px solid rgba(255,255,255,.08)';

  document.body.appendChild(menu);

  // Close on a click anywhere else, or on Escape.
  setTimeout(() => {
    const close = (ev) => {
      if (menu.contains(ev.target)) return;
      menu.remove();
      document.removeEventListener('click', close);
    };
    document.addEventListener('click', close);
  }, 0);

  document.addEventListener('keydown', function esc(ev) {
    if (ev.key === 'Escape') { menu.remove(); document.removeEventListener('keydown', esc); }
  });
}

/// Clears this site's connection state.
///
/// A page cannot revoke a wallet's permission -- only the wallet can do that,
/// from its own UI. What this does is forget the address and drop the signer
/// so the site stops acting as though someone is connected. That matters on
/// a shared machine, and it is what every dApp's "Disconnect" does.
function disconnect() {
  document.getElementById('walletMenu')?.remove();
  state.signer = null;
  state.address = null;
  state.provider = null;
  setConnectLabel('Connect wallet');
  renderReferrals();
  notify('Disconnected from this site. Your wallet still has it authorised — revoke there if you want that too.');
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
    notifyError(err, 'Connection failed');
  }
}

/* ---------- contracts ---------- */

// Must match BondingCurve.QUOTE_TARGET. The contract raises 4 ether; this
// value only drives the progress bars and card labels, so a mismatch shows
// everyone the wrong completion percentage.
const TARGET_ETH = '4';

// Robinhood Chain mainnet, deployed at block 53540363.
// Factory owner and fee recipient: 0x2bb8CE046631b50149a74Dc9902402A614A6D8F3
/* ===================================================================
   REDEPLOY: these are the only two lines to change here, and there is
   a matching FACTORY line near the top of token.html and of admin.html.
   This build expects the ETH-dividend factory -- the one whose
   createToken takes sixteen fields. Pointing it at the old factory
   breaks launching.
   =================================================================== */
const ADDR = {
  factory: '0x9509Ca715ECDE9C8801809121619a319F84C701F',
  nft:     '0xBbA85b92355C37D8B67B6FBb75aa33F4F00f2ba0',
};

const FACTORY_ABI = [
  'function deployFee() view returns (uint256)',
  'function launchCount() view returns (uint256)',
  'function getLaunches(uint256,uint256) view returns ((address,address,address,uint256,uint64)[])',
  'event TokenLaunched(address indexed creator, address indexed token, address curve, uint256 referralId, uint256 devBuy)',
  'function createToken((string,string,uint256,uint256,address,uint256,uint16,uint16,uint32,address,uint16,uint16,uint16,uint16,uint8,string)) payable returns (address,address,uint256)',
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

  // 0 = holders are paid in the token itself, 1 = holders are paid in ETH.
  // Must match FeeSplitter.DividendMode, and is fixed for the token's life.
  const divSel = document.querySelector('#divAsset .seg-opt.active')?.dataset.v || 'self';
  const dividendMode = divSel === 'quote' ? 1 : 0;

  // uploadedImageUrl is set by the Pinata upload below. It is optional: if
  // nothing was uploaded, or the upload failed, we simply omit the field and
  // the launch proceeds without an image.
  const meta = {};
  if (desc) meta.description = desc;
  if (uploadedImageUrl) meta.image = uploadedImageUrl;
  const metadata = Object.keys(meta).length ? JSON.stringify(meta) : '';

  return {
    name:   document.getElementById('tokenName').value.trim(),
    symbol: document.getElementById('tokenTicker').value.trim(),
    maxSupply, capBps, referrer, devBuy,
    buyTaxBps, sellTaxBps, taxDays,
    marketing, liquidityBps, burnBps, marketingBps, dividendBps,
    dividendMode,
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
      f.dividendMode,
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
    notifyError(err, 'Launch failed');
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
  'function dividendMode() view returns (uint8)',
  'function burnBps() view returns (uint16)',
  'function dividendBps() view returns (uint16)',
  'function liquidityBps() view returns (uint16)',
  'function marketingBps() view returns (uint16)',
];

const TOKEN_ABI = [
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function totalSupply() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function buyTaxBps() view returns (uint16)',
  'function sellTaxBps() view returns (uint16)',
  'function dexPair() view returns (address)',
];

const PAIR_ABI = [
  'function getReserves() view returns (uint112,uint112,uint32)',
  'function token0() view returns (address)',
];

function readProvider() {
  return state.provider ?? new ethers.JsonRpcProvider(CHAIN.rpcUrls[0]);
}

/* ---------- price, formatting, and the curve sparkline ---------- */

/// ETH/USD, so cards and the token page can show a dollar market cap.
///
/// One request per tab, cached for ten minutes. This is the only third-party
/// call the page makes, and everything that uses it falls back to plain ETH
/// when it fails -- an ad blocker or a rate limit must never blank a card.
const USD_TTL_MS = 10 * 60 * 1000;
let _usdRate = null;

async function ethUsd() {
  if (_usdRate !== null) return _usdRate;

  try {
    const cached = JSON.parse(sessionStorage.getItem('nosleep.ethusd') || 'null');
    if (cached && Date.now() - cached.at < USD_TTL_MS) {
      _usdRate = cached.v;
      return _usdRate;
    }
  } catch { /* private mode, or storage disabled */ }

  try {
    const r = await fetch(
      'https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd',
      { cache: 'no-store' },
    );
    if (!r.ok) throw new Error(r.status);
    const j = await r.json();
    const v = Number(j?.ethereum?.usd);
    if (!Number.isFinite(v) || v <= 0) throw new Error('bad rate');
    _usdRate = v;
    try {
      sessionStorage.setItem('nosleep.ethusd', JSON.stringify({ v, at: Date.now() }));
    } catch {}
    return v;
  } catch {
    _usdRate = 0;   // 0 means "asked and failed" -- do not ask again this tab
    return 0;
  }
}

function compact(n) {
  return Number(n).toLocaleString(undefined, { notation: 'compact', maximumFractionDigits: 2 });
}

/// A value in ETH, shown in dollars when a rate is known and in ETH when not.
function moneyFromEth(eth, rate) {
  if (rate > 0) return '$' + compact(eth * rate);
  return compact(eth) + ' ETH';
}

/* The curve every token follows, drawn once per card.
 *
 * With virtual reserves the price is (VIRTUAL_QUOTE + raised)^2 / (5.25 * s),
 * so the shape is the same quadratic for every token -- only the marker moves.
 * That makes it pure arithmetic: no RPC call, nothing to load, and it cannot
 * disagree with the progress number printed beside it.                        */
function curveSvg(progressPct) {
  const W = 300, H = 64, PAD = 4;
  const at = (e) => Math.pow(3 + e, 2);           // price, unnormalised
  const lo = at(0), hi = at(4);

  const pt = (e) => {
    const x = PAD + (e / 4) * (W - PAD * 2);
    const y = (H - 6) - ((at(e) - lo) / (hi - lo)) * (H - 16);
    return [x, y];
  };

  const done = Math.max(0, Math.min(100, progressPct)) / 100;
  const line = (from, to) => {
    const out = [];
    const STEPS = 28;
    for (let i = 0; i <= STEPS; i++) {
      const e = (from + ((to - from) * i) / STEPS) * 4;
      const [x, y] = pt(e);
      out.push(`${x.toFixed(1)},${y.toFixed(1)}`);
    }
    return out.join(' ');
  };

  const [dx, dy] = pt(done * 4);

  return `
    <svg class="tc-spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" aria-hidden="true">
      <polyline points="${line(done, 1)}" fill="none" stroke="rgba(233,230,219,.22)" stroke-width="2.5"
                stroke-linecap="round"/>
      <polyline points="${line(0, done)}" fill="none" stroke="var(--gold)" stroke-width="2.5"
                stroke-linecap="round"/>
      <circle cx="${dx.toFixed(1)}" cy="${dy.toFixed(1)}" r="4.5" fill="var(--gold)"/>
    </svg>`;
}

/* Card styles live here rather than in index.html so that a change to the
   Explore grid is a one-file upload. index.html is megabytes of inlined
   artwork; re-uploading it to change a border colour is not a fair trade. */
function injectCardStyles() {
  if (document.getElementById('nosleep-card-css')) return;
  const el = document.createElement('style');
  el.id = 'nosleep-card-css';
  el.textContent = `
    .token-card{cursor:pointer;}
    .token-card:hover{border-color:var(--gold-dim);}
    .tc-top{display:flex;gap:11px;align-items:flex-start;}
    .tc-avatar{width:42px;height:42px;flex:none;border-radius:10px;overflow:hidden;
      background:var(--panel-2);border:1px solid var(--line-soft);
      display:flex;align-items:center;justify-content:center;font-size:18px;color:var(--gold);}
    .tc-avatar img{width:100%;height:100%;object-fit:cover;}
    .tc-title{font-family:'JetBrains Mono',monospace;font-weight:600;font-size:15px;
      line-height:1.25;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
    .tc-sub{font-family:'JetBrains Mono',monospace;font-size:11.5px;color:var(--text-faint);margin-top:3px;}
    .tc-sub b{color:var(--gold);font-weight:500;}
    .tc-desc{font-size:12.5px;color:var(--text-dim);line-height:1.5;margin:12px 0 2px;
      display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;}
    .tc-spark{width:100%;height:64px;display:block;margin:10px 0 6px;overflow:visible;}
    .tc-figs{display:flex;justify-content:space-between;gap:10px;align-items:baseline;
      font-family:'JetBrains Mono',monospace;font-size:11.5px;color:var(--text-faint);}
    .tc-figs b{color:var(--text);font-size:13px;font-weight:600;}
    .tc-figs .pct b{color:var(--gold);}
    .tc-pills{display:flex;flex-wrap:wrap;gap:6px;margin-top:12px;}
    .tc-pill{display:inline-flex;align-items:center;gap:5px;
      font-family:'JetBrains Mono',monospace;font-size:10.5px;color:var(--text-dim);
      background:var(--panel-2);border:1px solid var(--line-soft);
      border-radius:20px;padding:4px 9px;white-space:nowrap;}
    .tc-pill .d{width:6px;height:6px;border-radius:50%;background:var(--gold);flex:none;}
    .tc-pill.grad{color:var(--gold);border-color:var(--gold-dim);}
    .ca-line{cursor:pointer;}
  `;
  document.head.appendChild(el);
}

let USD_RATE = 0;

function ageLabel(ts) {
  const s = Math.floor(Date.now() / 1000) - Number(ts);
  if (s < 60)    return `${s}s ago`;
  if (s < 3600)  return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

/* Immutable facts about a token -- name, ticker, supply, tax, artwork.
 *
 * These cannot change after launch, so they are fetched once and kept. The
 * Explore grid refreshes every 15 seconds; re-reading eight constants per
 * token on every pass was most of the RPC bill and bought nothing. Only the
 * two values that actually move are re-read below.                          */
const TOKEN_META = new Map();

async function tokenMeta(provider, factory, tokenAddr, curveAddr) {
  const key = tokenAddr.toLowerCase();
  const hit = TOKEN_META.get(key);
  if (hit) return hit;

  const token = new ethers.Contract(tokenAddr, TOKEN_ABI, provider);
  const curve = new ethers.Contract(curveAddr, CURVE_ABI, provider);

  const [name, symbol, totalSupply, buyTaxBps, sellTaxBps, burnBps, dividendBps, dividendMode, pair, meta] =
    await Promise.all([
      token.name(),
      token.symbol(),
      token.totalSupply(),
      token.buyTaxBps().catch(() => 0n),
      token.sellTaxBps().catch(() => 0n),
      curve.burnBps().catch(() => 0n),
      curve.dividendBps().catch(() => 0n),
      // Curves deployed before ETH dividends existed have no such getter.
      // Absent means the only mode there was: paid in the token itself.
      curve.dividendMode().catch(() => 0n),
      token.dexPair().catch(() => ethers.ZeroAddress),
      factory.metadataURI(tokenAddr).catch(() => ''),
    ]);

  let description = '';
  let image = '';
  try {
    const m = meta ? JSON.parse(meta) : {};
    description = m.description || '';
    // Only http(s) and ipfs URLs. Anything else -- javascript:, data: -- is
    // attacker-supplied and must never reach an <img src>.
    const rawImg = typeof m.image === 'string' ? m.image.trim() : '';
    if (/^https?:\/\//i.test(rawImg)) image = rawImg;
    else if (/^ipfs:\/\//i.test(rawImg)) image = PINATA_GATEWAY + rawImg.slice(7);
  } catch {}

  const rec = {
    name, symbol, description, image, pair,
    supply: Number(ethers.formatEther(totalSupply)),
    buyTaxBps: Number(buyTaxBps),
    sellTaxBps: Number(sellTaxBps),
    burnBps: Number(burnBps),
    dividendBps: Number(dividendBps),
    dividendMode: Number(dividendMode),   // 0 = the token itself, 1 = ETH
  };
  TOKEN_META.set(key, rec);
  return rec;
}

/// Price in ETH per token, once the curve has closed and trading moved to the
/// pool. The curve's own reserves freeze at graduation, so reading them after
/// that would quote a price that stopped moving weeks ago.
async function pairPriceEth(provider, pairAddr, tokenAddr) {
  if (!pairAddr || pairAddr === ethers.ZeroAddress) return 0;
  const pair = new ethers.Contract(pairAddr, PAIR_ABI, provider);
  const [[r0, r1], t0] = await Promise.all([pair.getReserves(), pair.token0()]);
  const tokenIsZero = t0.toLowerCase() === tokenAddr.toLowerCase();
  const tokenRes = tokenIsZero ? r0 : r1;
  const wethRes  = tokenIsZero ? r1 : r0;
  if (tokenRes === 0n) return 0;
  return Number(ethers.formatEther(wethRes)) / Number(ethers.formatEther(tokenRes));
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

    const [m, collected, graduated] = await Promise.all([
      tokenMeta(provider, factory, tokenAddr, curveAddr),
      curve.ethCollected(),
      curve.graduated(),
    ]);

    // Progress must be measured against the same target the label prints,
    // or a card reads 100% while the curve has barely moved. This divided by
    // the testnet target (0.004) long after the label was corrected to 4.
    const progress = Number((collected * 10000n) / ethers.parseEther(TARGET_ETH)) / 100;

    // Constant product with virtual reserves gives a closed form for the
    // price at any point on the curve, so no extra call is needed to show a
    // market cap: price = (VIRTUAL_QUOTE + raised)^2 / (5.25 * curveSupply).
    const raised = Number(ethers.formatEther(collected));
    const curveSupply = m.supply * 0.8;
    let priceEth = curveSupply > 0 ? Math.pow(3 + raised, 2) / (5.25 * curveSupply) : 0;

    if (graduated) {
      try {
        const live = await pairPriceEth(provider, m.pair, tokenAddr);
        if (live > 0) priceEth = live;
      } catch { /* fall back to the graduation price */ }
    }

    return {
      curveAddr, tokenAddr, creator, referralId, createdAt,
      name: m.name, symbol: m.symbol, description: m.description, image: m.image,
      supply: m.supply,
      buyTaxBps: m.buyTaxBps, sellTaxBps: m.sellTaxBps,
      burnBps: m.burnBps, dividendBps: m.dividendBps,
      dividendMode: m.dividendMode,
      collected,
      graduated,
      priceEth,
      mcapEth: priceEth * m.supply,
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
    card.tabIndex = 0;
    card.setAttribute('role', 'link');
    card.setAttribute('aria-label', `${t.name} (${t.symbol}) — open token page`);

    const href = `token.html?a=${encodeURIComponent(t.tokenAddr)}`;

    const pills = ['<span class="tc-pill"><i class="d"></i>Robinhood Chain</span>',
                   '<span class="tc-pill">&#8646; ETH</span>'];
    if (t.graduated)       pills.push('<span class="tc-pill grad">Graduated</span>');
    if (t.burnBps > 0)     pills.push('<span class="tc-pill">&#128293; Buyback &amp; burn</span>');
    if (t.dividendBps > 0) {
      pills.push(`<span class="tc-pill">&#128176; Dividends in ${t.dividendMode === 1 ? 'ETH' : escapeHtml(t.symbol)}</span>`);
    }
    if (t.buyTaxBps || t.sellTaxBps) {
      pills.push(`<span class="tc-pill">Tax ${t.buyTaxBps / 100}/${t.sellTaxBps / 100}%</span>`);
    }

    const blurb = t.description
      ? escapeHtml(t.description.slice(0, 160))
      : `${escapeHtml(t.name)}, paired with ETH.`;

    const right = t.graduated
      ? '<span class="pct"><b>Trading on Uniswap</b></span>'
      : `<span class="pct"><b>${t.progress.toFixed(1)}%</b> to graduation</span>`;

    card.innerHTML = `
      <div class="tc-top">
        <div class="tc-avatar">${
          t.image
            ? `<img src="${escapeHtml(t.image)}" alt="" loading="lazy"
                 onerror="this.replaceWith(document.createTextNode('◆'))">`
            : '&#9670;'
        }</div>
        <div style="min-width:0; flex:1;">
          <div class="tc-title">${escapeHtml(t.name)}</div>
          <div class="tc-sub"><b>$${escapeHtml(t.symbol)}</b> &middot; ${escapeHtml(t.age)}</div>
        </div>
      </div>

      <div class="tc-desc">${blurb}</div>

      ${curveSvg(t.progress)}

      <div class="tc-figs">
        <span>Mkt cap <b>${escapeHtml(moneyFromEth(t.mcapEth, USD_RATE))}</b></span>
        ${right}
      </div>

      <div class="tc-pills">${pills.join('')}</div>

      <div class="mono ca-line" data-addr="${escapeHtml(t.tokenAddr)}"
           title="Click to copy the contract address"
           style="font-size:11px; color:var(--text-faint); margin-top:12px;">${short(t.tokenAddr)}<span class="ca-copy" style="margin-left:6px; opacity:.55;">copy</span></div>

      <div class="div-slot"></div>
    `;

    // The whole card is the link. Anything interactive inside it -- the
    // copy line, a claim button -- opts out, so copying an address does not
    // navigate away from the grid.
    const open = () => { window.location.href = href; };
    card.addEventListener('click', (e) => {
      if (e.target.closest('a, button, input, .ca-line')) return;
      open();
    });
    card.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); }
    });

    // Graduated tokens may have claimable dividends. Checked lazily so an
    // absent vault never blocks the card from rendering.
    if (t.graduated && state.address) {
      pendingDividends(t.curveAddr).then((amt) => {
        if (amt === 0n) return;

        const slot = card.querySelector('.div-slot');
        const btn2 = document.createElement('button');
        // Both vaults hold 18-decimal values, but one pays the token and the
        // other pays ETH. Labelling an ETH payout with the ticker would be a
        // plain lie about what lands in the wallet.
        const eth = t.dividendMode === 1;
        const amountText = eth
          ? Number(ethers.formatEther(amt)).toFixed(6)
          : Number(ethers.formatUnits(amt, 18)).toLocaleString(undefined, { maximumFractionDigits: 2 });
        btn2.textContent = `Claim ${amountText} ${eth ? 'ETH' : t.symbol}`;
        btn2.style.cssText = `
          width:100%; margin-top:10px; padding:10px;
          background:rgba(62,240,140,.12); color:var(--gold);
          border:1px solid var(--gold-dim); cursor:pointer;
          font-family:'JetBrains Mono',monospace; font-size:12px; font-weight:600;
        `;
        btn2.addEventListener('click', async (e) => {
          e.stopPropagation();
          btn2.disabled = true;
          const label = btn2.textContent;
          btn2.textContent = 'Claiming…';
          try {
            await claimDividends(t);
          } catch (err) {
            console.error(err);
            notifyError(err, 'Claim failed');
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

let _refreshing = false;

async function refreshExplore() {
  // Overlapping refreshes would race on LIVE and rebuild the grid twice.
  if (_refreshing) return;
  _refreshing = true;
  try {
    // Resolved before the grid is built so every card prints the same rate.
    // Returns 0 when the lookup fails, and every caller falls back to ETH.
    USD_RATE = await ethUsd();
    LIVE = await fetchLaunches();
    renderLive();
    console.log(`Explore: ${LIVE.length} live token(s)`);
  } catch (err) {
    console.error('Explore refresh failed:', err);
  } finally {
    _refreshing = false;
  }
}

/* ---------- auto-refresh ----------
   The grid used to update only on load and after your own trades, so anyone
   watching a curve fill saw a frozen page. It now polls -- but carefully:

   - paused when the tab is hidden, so a backgrounded tab costs no RPC calls
   - paused while an amount is being typed, since renderLive() rebuilds the
     grid with innerHTML and would wipe an in-progress entry
   - skipped if a refresh is already in flight                              */

const REFRESH_MS = 15000;
let _refreshTimer = null;

function userIsTyping() {
  const el = document.activeElement;
  if (!el) return false;
  if (!el.classList || !el.classList.contains('trade-amt')) return false;
  return el.value.trim().length > 0;
}

function startAutoRefresh() {
  if (_refreshTimer) return;
  _refreshTimer = setInterval(() => {
    if (document.hidden) return;
    if (userIsTyping()) return;
    refreshExplore();
  }, REFRESH_MS);
}

function stopAutoRefresh() {
  clearInterval(_refreshTimer);
  _refreshTimer = null;
}

document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  // Coming back to the tab: refresh once immediately rather than waiting.
  refreshExplore();
});

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
          notifyError(err, 'Claim failed');
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
  // Disconnected: connect. Connected: open a menu under the address, which
  // is where people look for "disconnect" and leaves room for copy and
  // explorer without crowding the header.
  document.querySelectorAll('.connect-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      if (!state.address) { connect(); return; }
      e.stopPropagation();
      toggleWalletMenu(btn);
    });
  });

  // Contract addresses are click-to-copy. Delegated from the document
  // because renderLive() rebuilds every card on each refresh, so per-card
  // listeners would be discarded and re-added constantly.
  document.addEventListener('click', async (e) => {
    const line = e.target.closest('.ca-line');
    if (!line || !line.dataset.addr) return;

    const badge = line.querySelector('.ca-copy');
    const flash = (text) => {
      if (!badge) return;
      badge.textContent = text;
      badge.style.opacity = '1';
      setTimeout(() => { badge.textContent = 'copy'; badge.style.opacity = '.55'; }, 1400);
    };

    try {
      await navigator.clipboard.writeText(line.dataset.addr);
      flash('copied');
    } catch {
      // The clipboard API needs a secure context and can be refused.
      // Select the text instead so it can still be copied by hand.
      const r = document.createRange();
      r.selectNodeContents(line);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(r);
      flash('select it');
    }
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

  // index.html's own wireToggle() already binds taxSwitch, divSwitch and
  // refSwitch to reveal their panels (adds the 'show' class) -- it does not
  // need a second listener here. The block this replaces ran in the capture
  // phase and called stopImmediatePropagation(), which silently prevented
  // wireToggle()'s own listener from ever running: the switch still flipped
  // green, but taxPanel/divPanel/refPanel never got the 'show' class, so the
  // sliders and the referrer address box stayed hidden. That was the bug.
  //
  // Any .switch NOT already wired by index.html (there are currently none,
  // but future toggles may add one without wiring it) still needs a plain
  // fallback so it is visually responsive, added non-capturing so it never
  // runs before -- or blocks -- wireToggle().
  const WIRED_BY_HTML = new Set(['taxSwitch', 'divSwitch', 'refSwitch']);
  document.querySelectorAll('.switch').forEach((sw) => {
    if (WIRED_BY_HTML.has(sw.id)) return; // wireToggle() already owns this one
    sw.addEventListener('click', () => sw.classList.toggle('on'));
  });

  // Self and ETH are both live on-chain. "Any ERC-20" and "Tokenized stock"
  // are removed rather than greyed out: an arbitrary payout token means an
  // arbitrary swap path, and a token that may have no liquidity at all on
  // this chain. A visible option nobody can pick only invites questions.
  document.querySelectorAll('#divAsset .seg-opt').forEach((opt) => {
    const v = opt.dataset.v;

    if (v === 'self' || v === 'quote') {
      opt.addEventListener('click', () => {
        document.querySelectorAll('#divAsset .seg-opt')
          .forEach((o) => o.classList.toggle('active', o === opt));
        const note = document.getElementById('divNote');
        if (!note) return;
        note.innerHTML = v === 'quote'
          ? '<b>ETH mode:</b> the dividend share is swapped to ETH and holders claim ETH. '
            + 'Converts in slices of at most 1% of the pool per call.'
          : '<b>Self mode:</b> holders accumulate more of the token automatically, no swap needed.';
      });
      return;
    }

    opt.remove();
  });

  injectCardStyles();
  refreshExplore();
  renderReferrals();
  startAutoRefresh();
  wireImageUpload();

  console.log('NO SLEEP app.js loaded');
});
