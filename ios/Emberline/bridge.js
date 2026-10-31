// Emberline iPhone app: Web Bluetooth for the page, backed by CoreBluetooth in the app.
// Same shape as Chrome / Path (navigator.bluetooth, device.gatt, characteristics with events),
// so index.html runs unchanged. Every call goes to Swift (BLEBridge.swift) and comes back through
// window.__emberBle.reply / notify / gone.
(function(){
  if (window.__emberBle || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.ble) return;
  const H = window.webkit.messageHandlers.ble;
  let nextId = 1; const waits = new Map();
  const call = (op, args) => new Promise((res, rej) => { const id = nextId++; waits.set(id, { res, rej }); H.postMessage(Object.assign({ id, op }, args || {})); });
  const b64 = u8 => { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return btoa(s); };
  const unb64 = s => { const bin = atob(s || ''), u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u; };
  const toU8 = v => v instanceof Uint8Array ? v : ArrayBuffer.isView(v) ? new Uint8Array(v.buffer, v.byteOffset, v.byteLength) : new Uint8Array(v);
  const lc = u => String(u).toLowerCase();
  const err = (name, msg) => { try { return new DOMException(msg, name); } catch(e){ const x = new Error(msg); x.name = name; return x; } };

  class Ev {
    constructor(){ this._l = {}; }
    addEventListener(t, f){ if (typeof f === 'function') (this._l[t] = this._l[t] || []).push(f); }
    removeEventListener(t, f){ const a = this._l[t]; if (a){ const i = a.indexOf(f); if (i >= 0) a.splice(i, 1); } }
    dispatchEvent(e){
      (this._l[e.type] || []).slice().forEach(f => { try { f.call(this, e); } catch(x){ console.error(x); } });
      const h = this['on' + e.type]; if (typeof h === 'function'){ try { h.call(this, e); } catch(x){ console.error(x); } }
      return true;
    }
  }
  class Char extends Ev {
    constructor(dev, svc, uuid, props){ super(); this.service = svc; this.uuid = uuid; this._dev = dev; this.value = null; this.properties = props || {}; }
    _k(){ return { dev: this._dev.id, svc: this.service.uuid, ch: this.uuid }; }
    async readValue(){ const r = await call('read', this._k()); this.value = new DataView(unb64(r.data).buffer); return this.value; }
    async writeValue(v){ await call('write', Object.assign(this._k(), { data: b64(toU8(v)), resp: true })); }
    async writeValueWithResponse(v){ return this.writeValue(v); }
    async writeValueWithoutResponse(v){ await call('write', Object.assign(this._k(), { data: b64(toU8(v)), resp: false })); }
    async startNotifications(){ await call('notify', Object.assign(this._k(), { on: true })); return this; }
    async stopNotifications(){ await call('notify', Object.assign(this._k(), { on: false })); return this; }
  }
  class Svc {
    constructor(dev, uuid){ this.device = dev; this.uuid = uuid; this.isPrimary = true; this._c = new Map(); }
    async getCharacteristic(u){
      u = lc(u); if (this._c.has(u)) return this._c.get(u);
      const r = await call('char', { dev: this.device.id, svc: this.uuid, ch: u });
      const c = new Char(this.device, this, u, r.props); this._c.set(u, c); return c;
    }
  }
  class Gatt {
    constructor(dev){ this.device = dev; this.connected = false; this._s = new Map(); }
    async connect(){ await call('connect', { dev: this.device.id }); this.connected = true; return this; }
    disconnect(){ H.postMessage({ id: 0, op: 'disconnect', dev: this.device.id }); }
    async getPrimaryService(u){
      u = lc(u);
      if (!this.connected) throw err('NetworkError', 'GATT Server is disconnected.');
      if (this._s.has(u)) return this._s.get(u);
      await call('service', { dev: this.device.id, svc: u });
      const s = new Svc(this.device, u); this._s.set(u, s); return s;
    }
  }
  class Dev extends Ev { constructor(id, name){ super(); this.id = id; this.name = name || ''; this.gatt = new Gatt(this); } }
  const devices = new Map();
  const devOf = (id, name) => { let d = devices.get(id); if (!d){ d = new Dev(id, name); devices.set(id, d); } else if (name) d.name = name; return d; };

  const bt = new Ev();
  bt.requestDevice = async opts => { const r = await call('request', { opts: JSON.parse(JSON.stringify(opts || {})) }); return devOf(r.id, r.name); };
  bt.getDevices = async () => { const r = await call('known'); return (r.list || []).map(x => devOf(x.id, x.name)); };
  bt.getAvailability = async () => !!(await call('avail')).on;

  window.__emberBle = {
    reply(id, ok, p){ const w = waits.get(id); if (!w) return; waits.delete(id); if (ok) w.res(p || {}); else w.rej(err((p && p.name) || 'NetworkError', (p && p.msg) || 'Bluetooth error')); },
    notify(dev, svc, ch, data){
      const d = devices.get(dev), s = d && d.gatt._s.get(svc), c = s && s._c.get(ch); if (!c) return;
      c.value = new DataView(unb64(data).buffer);
      c.dispatchEvent({ type: 'characteristicvaluechanged', target: c, currentTarget: c });
    },
    gone(dev){
      const d = devices.get(dev); if (!d) return;
      const was = d.gatt.connected; d.gatt.connected = false; d.gatt._s.clear();
      if (was) d.dispatchEvent({ type: 'gattserverdisconnected', target: d, currentTarget: d });
    },
    avail(on){ bt.dispatchEvent({ type: 'availabilitychanged', value: !!on }); }
  };
  try { Object.defineProperty(navigator, 'bluetooth', { value: bt, configurable: true }); } catch(e){ navigator.bluetooth = bt; }
  const A = window.webkit.messageHandlers.app;
  window.EMBER_APP = { native: true, post: (op, args) => { try { A.postMessage(Object.assign({ op }, args || {})); } catch(e){} } };
})();
