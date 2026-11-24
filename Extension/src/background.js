// Hush: habla con la app (mensajería nativa) y reparte las respuestas a la página y a la ventanita.
// Las contraseñas no se guardan nunca en la extensión: se piden a Hush justo al rellenar.
const api = globalThis.browser ?? globalThis.chrome;
const HOST = "__HOST__";

let port = null;
let nextId = 1;
const pending = new Map();

function connect() {
  port = api.runtime.connectNative(HOST);
  port.onMessage.addListener((message) => {
    const waiting = pending.get(message.id);
    if (waiting) {
      pending.delete(message.id);
      waiting(message);
    } else if (message.error === "offline") {
      failAll("offline");
    }
  });
  port.onDisconnect.addListener(() => {
    port = null;
    failAll("offline");
  });
}

function failAll(error) {
  for (const resolve of pending.values()) resolve({ error });
  pending.clear();
}

async function clientId() {
  const stored = await api.storage.local.get("client");
  if (stored.client) return stored.client;
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  const client = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  await api.storage.local.set({ client });
  return client;
}

/// Mismo código que enseña Hush al pedir permiso.
async function pairingCode() {
  const hex = (await clientId()).toUpperCase();
  return `${hex.slice(0, 4)}-${hex.slice(4, 8)}`;
}

async function call(type, payload = {}, timeout = 10000) {
  const client = await clientId();
  if (!port) {
    try {
      connect();
    } catch {
      return { error: "offline" };
    }
  }
  const id = nextId++;
  return new Promise((resolve) => {
    pending.set(id, resolve);
    try {
      port.postMessage({ id, client, type, ...payload });
    } catch {
      pending.delete(id);
      port = null;
      resolve({ error: "offline" });
      return;
    }
    setTimeout(() => {
      if (pending.delete(id)) resolve({ error: "timeout" });
    }, timeout);
  });
}

async function activeTab() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  return tab;
}

/// Envía usuario y contraseña al marco principal de la pestaña.
/// La contraseña va atada al origen de la web autorizada: si la pestaña navega mientras Hush responde,
/// la página nueva no la acepta (content.js compara su origen) y aquí tampoco se envía.
async function fillTab(tab, entry, explicit) {
  let origin;
  try {
    origin = new URL(tab.url).origin;
  } catch {
    return { error: "no-page" };
  }
  const reply = await call("fill", { uuid: entry.uuid, vault: entry.vault, url: tab.url, explicit });
  if (reply.error) return reply;
  const now = await api.tabs.get(tab.id).catch(() => null);
  if (!now?.url || new URL(now.url).origin !== origin) return { error: "no-page" };
  try {
    await api.tabs.sendMessage(tab.id, { type: "hush-fill", origin, user: reply.user, password: reply.password }, { frameId: 0 });
  } catch {
    return { error: "no-page" };
  }
  return { ok: true, totpCopied: !!reply.totpCopied };
}

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // Solo esta extensión.
  if (sender.id !== api.runtime.id) return false;
  handle(message, sender).then(sendResponse, () => sendResponse({ error: "failed" }));
  return true;
});

async function handle(message, sender) {
  // Las páginas de la propia extensión (la ventanita) tienen su dirección; el resto son webs.
  const fromPage = !(sender.url || "").startsWith(api.runtime.getURL(""));
  if (fromPage) {
    // La página solo puede pedir lo de su propia web; la dirección la pone el navegador, no la página.
    const url = sender.url || sender.tab.url;
    switch (message.type) {
      case "list":
        return call("list", { url });
      case "fill":
        return call("fill", { uuid: message.uuid, vault: message.vault, url, explicit: false });
      case "unlock":
        return call("unlock");
      // ⇧⌘L pulsado en la página: el navegador no siempre asigna el atajo (si otra extensión lo usa o si
      // Hush se instaló antes de tenerlo), así que content.js también lo escucha. Siempre en la pestaña que lo envía.
      case "autofill":
        // Solo desde la página principal: un iframe de otra web no puede pedir rellenar la de arriba.
        return sender.tab && sender.frameId === 0 ? autofill(sender.tab) : { error: "bad-request" };
      case "passkey-create":
      case "passkey-get": {
        // Solo la página principal. El origen sale de la dirección que da el navegador, no de la página.
        if (sender.frameId !== 0) return { error: "bad-request" };
        let origin;
        try {
          origin = new URL(url).origin;
        } catch {
          return { error: "bad-request" };
        }
        // Hasta dos minutos: Hush espera a que confirmes (o a que desbloquees la base).
        return call(message.type, { origin, options: message.options ?? {} }, 125000);
      }
      case "save-enabled":
      case "save-capture":
      case "save-user":
      case "save-offer":
      case "save-recheck":
      case "save-unlock":
      case "save-commit":
      case "save-done":
        return handleSave(message, sender, url);
      default:
        return { error: "bad-request" };
    }
  }

  // Desde la ventanita de la extensión.
  switch (message.type) {
    case "state": {
      const tab = await activeTab();
      const status = await call("status");
      return { ...status, code: await pairingCode(), url: tab?.url ?? "" };
    }
    case "pair":
      return call("pair", {}, 120000);
    case "unlock":
      return call("unlock");
    case "list": {
      const tab = await activeTab();
      return tab?.url ? call("list", { url: tab.url }) : { entries: [] };
    }
    case "search":
      return call("search", { query: message.query });
    case "fill": {
      const tab = await activeTab();
      if (!tab) return { error: "no-page" };
      return fillTab(tab, message.entry, true);
    }
    case "copy": {
      const tab = await activeTab();
      return call("copy", { uuid: message.entry.uuid, vault: message.entry.vault, field: message.field, url: tab?.url ?? "", explicit: true });
    }
    default:
      return { error: "bad-request" };
  }
}

// ⇧⌘L: rellena con la entrada de esta web que usaste la última vez.
async function autofill(tab) {
  if (!tab?.url) return { error: "no-page" };
  const reply = await call("list", { url: tab.url });
  if (reply.locked) {
    call("unlock");
    return { locked: true };
  }
  const entry = reply.entries?.[0];
  return entry ? fillTab(tab, entry, false) : { error: "no-entry" };
}

api.commands.onCommand.addListener(async (command) => {
  if (command === "autofill") autofill(await activeTab());
});

// ---------- Guardar lo que escribes al entrar o registrarte ----------
// La contraseña solo vive en memoria (nunca en storage) hasta que guardas o cierras el panel, y como mucho unos minutos.
// El panel se enseña en la página principal de la pestaña, también tras la navegación que suele seguir al entrar,
// pero solo si sigue siendo el mismo sitio.

const OFFER_TTL = 3 * 60 * 1000;
const USER_TTL = 10 * 60 * 1000;
const offers = new Map(); // pestaña → { id, site, url, user, password, check, expires }
const tabUsers = new Map(); // pestaña → { site, user, expires } (primer paso de un inicio de sesión en varias páginas)
const sites = new Map(); // host → dominio registrable (lo calcula Hush con la Public Suffix List)

async function siteOf(url) {
  let host;
  try {
    const parsed = new URL(url);
    if (!/^https?:$/.test(parsed.protocol)) return null;
    host = parsed.hostname;
  } catch {
    return null;
  }
  if (sites.has(host)) return sites.get(host);
  const reply = await call("site", { url });
  if (!reply.site) return null;
  sites.set(host, reply.site);
  return reply.site;
}

const hostKey = (url) => {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
};

// ¿Se ofrece guardar en esta web? Lo decide Hush (su ajuste y su lista de «No preguntar»); aquí solo se
// recuerda unos segundos en memoria para no preguntar a cada página. Sin Hush, no se captura nada.
const SETTINGS_TTL = 10 * 1000;
const offerCache = new Map(); // host → { enabled, until }

async function offersToSave(url) {
  const host = hostKey(url);
  if (!host || !/^https?:/.test(url)) return false;
  const cached = offerCache.get(host);
  if (cached && cached.until > Date.now()) return cached.enabled;
  const reply = await call("save-settings", { url });
  const enabled = reply.enabled === true;
  if (!reply.error) offerCache.set(host, { enabled, until: Date.now() + SETTINGS_TTL });
  return enabled;
}

// Versiones anteriores guardaban «No preguntar» en la extensión; ahora vive en Hush.
api.storage.local.remove("neverSave").catch(() => {});

const captureGeneration = new Map();

function forgetOffer(tabId) {
  const offer = offers.get(tabId);
  if (offer) offer.password = "";
  offers.delete(tabId);
}

/// Se borra a los pocos minutos; mientras usas el panel (desbloquear, guardar) se alarga.
function expireLater(tabId, offer) {
  setTimeout(() => {
    if (offers.get(tabId) !== offer) return;
    if (offer.expires > Date.now()) expireLater(tabId, offer);
    else forgetOffer(tabId);
  }, Math.max(1000, offer.expires - Date.now()));
}

/// Oferta de la pestaña, si la página que pregunta es la principal y del mismo sitio.
/// Al usar el panel (desbloquear, guardar) se alarga su vida; solo por cargar páginas, no.
async function liveOffer(tabId, sender, url, extend = true) {
  const offer = offers.get(tabId);
  if (sender.frameId !== 0 || !offer || (await siteOf(url)) !== offer.site) return null;
  if (extend) offer.expires = Date.now() + OFFER_TTL;
  return offer;
}

async function handleSave(message, sender, url) {
  const tabId = sender.tab?.id;
  if (tabId == null) return { error: "bad-request" };
  const text = (value, limit) => (typeof value === "string" ? value.slice(0, limit) : "");

  switch (message.type) {
    case "save-enabled":
      return { enabled: await offersToSave(url) };

    case "save-user": {
      if (!(await offersToSave(url))) return { ok: false };
      const user = text(message.user, 1024).trim();
      const site = user && (await siteOf(url));
      if (site) tabUsers.set(tabId, { site, user, expires: Date.now() + USER_TTL });
      return { ok: true };
    }

    case "save-capture": {
      // Capturas seguidas en la misma pestaña: solo cuenta la última (las respuestas pueden llegar desordenadas).
      const generation = (captureGeneration.get(tabId) ?? 0) + 1;
      captureGeneration.set(tabId, generation);
      const latest = () => captureGeneration.get(tabId) === generation;
      const password = text(message.password, 4096);
      if (!password || !/^https?:/.test(url)) return { ok: false };
      if (!(await offersToSave(url))) return { ok: false };
      let user = text(message.user, 1024).trim();
      const site = await siteOf(url);
      if (!site || !latest()) return { ok: false };
      const remembered = tabUsers.get(tabId);
      if (!user && remembered && remembered.expires > Date.now() && remembered.site === site) user = remembered.user;
      const pending = offers.get(tabId);
      if (pending && pending.site === site && pending.user === user && pending.password === password) return { ok: true };
      const check = await call("save-check", { url, user, password });
      if (!latest()) return { ok: false };
      if (check.known && offers.get(tabId)?.site === site) {
        // Lo que acabas de escribir ya está en Hush: una oferta anterior de esta web (p. ej. una contraseña
        // equivocada justo antes) ya no vale. Se retira y la página quita su panel.
        forgetOffer(tabId);
        api.tabs.sendMessage(tabId, { type: "hush-save-offer" }, { frameId: 0 }).catch(() => {});
      }
      // Sin Hush, sin emparejar o ya guardada: nada que ofrecer.
      if (check.error || check.known || check.disabled) return { ok: false };
      forgetOffer(tabId);
      tabUsers.delete(tabId);
      const offer = { id: crypto.randomUUID(), site: check.site || site, url, user, password, check, expires: Date.now() + OFFER_TTL };
      offers.set(tabId, offer);
      expireLater(tabId, offer);
      // Aviso a la página principal (si la web navega, la página nueva lo pide al cargar).
      api.tabs.sendMessage(tabId, { type: "hush-save-offer" }, { frameId: 0 }).catch(() => {});
      return { ok: true };
    }

    case "save-offer": {
      // Solo en una página del mismo sitio en el que escribiste la contraseña.
      const offer = await liveOffer(tabId, sender, url, false);
      if (!offer) return null;
      const { check } = offer;
      // Entra deslizándose la primera vez. Si la web navega justo después de entrar (lo normal), la página
      // anterior apenas lo llegó a enseñar: en la nueva también se desliza. Si reaparece más tarde, con un fundido.
      offer.shownAt ??= Date.now();
      const animate = Date.now() - offer.shownAt < 1500 ? "slide" : "fade";
      return {
        id: offer.id, animate, user: offer.user, password: offer.password, title: check.title, web: check.web,
        locked: !!check.locked, update: check.update ?? null, groups: check.groups ?? [], vaultName: check.vaultName ?? "",
      };
    }

    case "save-recheck": {
      if (!(await liveOffer(tabId, sender, url))) return { error: "expired" };
      const reply = await call("save-check", { url, user: text(message.user, 1024).trim(), password: text(message.password, 4096) });
      if (reply.locked) return { error: "locked" };
      return reply;
    }

    case "save-unlock":
      if (!(await liveOffer(tabId, sender, url))) return { error: "expired" };
      return call("save-unlock", {}, 130000);

    case "save-commit": {
      if (!(await liveOffer(tabId, sender, url))) return { error: "expired" };
      // La dirección es la de la página (la da el navegador); Hush comprueba que la web es de ese mismo sitio.
      const reply = await call("save-login", {
        url,
        password: text(message.password, 4096),
        title: text(message.title, 1024),
        user: text(message.user, 1024),
        web: text(message.web, 1024),
        notes: text(message.notes, 65536),
        group: message.group ? text(message.group, 64) : undefined,
        uuid: message.uuid ? text(message.uuid, 64) : undefined,
        vault: message.vault ? text(message.vault, 4096) : undefined,
      }, 60000);
      if (reply.ok) forgetOffer(tabId);
      return reply;
    }

    case "save-done": {
      const offer = offers.get(tabId);
      if (offer && offer.id === message.id) forgetOffer(tabId);
      if (message.never) {
        offerCache.delete(hostKey(url));
        return call("save-never", { url });
      }
      return { ok: true };
    }
  }
  return { error: "bad-request" };
}

api.tabs.onRemoved.addListener((tabId) => {
  forgetOffer(tabId);
  tabUsers.delete(tabId);
  captureGeneration.delete(tabId);
});
