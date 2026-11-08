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
api.commands.onCommand.addListener(async (command) => {
  if (command !== "autofill") return;
  const tab = await activeTab();
  if (!tab?.url) return;
  const reply = await call("list", { url: tab.url });
  if (reply.locked) {
    call("unlock");
    return;
  }
  const entry = reply.entries?.[0];
  if (entry) fillTab(tab, entry, false);
});
