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
  factory: '0x3fbaddDf6619792fa7Ef83C0bE63508c9100A4a0',
  nft:     '0x172c2D7B1065EB85a6Da4d2E107205b94fb9d753',
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

  console.log('NO SLEEP app.js loaded');
});
