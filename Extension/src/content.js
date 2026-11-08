// Hush en la página: detecta los campos de inicio de sesión y pone el icono de Hush dentro del campo,
// a la derecha. Al pulsarlo (o con ↓) enseña tus cuentas de esta web y rellena al elegir una.
// No se abre solo. El icono y la lista van en un Shadow DOM cerrado.
(() => {
  if (window.__hushLoaded) return;
  window.__hushLoaded = true;
  const api = globalThis.browser ?? globalThis.chrome;

  const USER_HINT = /user|email|e-mail|mail|login|account|usuario|correo|identifier|nif|dni|cuenta/i;
  const NOT_LOGIN = /search|buscar|query|coupon|cupon|captcha|otp|totp|one-time|code|codigo|código/i;

  // Icono de la app, incrustado al armar la extensión (así la web no puede detectar la extensión por sus archivos).
  const APP_ICON = "__ICON__";

  // ---------- Campos ----------

  function visible(el) {
    if (!el.isConnected || el.disabled || el.readOnly) return false;
    const rect = el.getBoundingClientRect();
    if (rect.width < 30 || rect.height < 12) return false;
    const style = getComputedStyle(el);
    return style.visibility !== "hidden" && style.display !== "none" && style.opacity !== "0";
  }

  const isPassword = (el) => el instanceof HTMLInputElement && el.type === "password";
  const textType = (el) => ["text", "email", "tel", ""].includes((el.getAttribute("type") || "text").toLowerCase());

  function hints(el) {
    return [el.name, el.id, el.placeholder, el.getAttribute("aria-label"), el.getAttribute("autocomplete")].join(" ");
  }

  function inputs(scope) {
    return [...(scope || document).querySelectorAll("input")].filter(visible);
  }

  function isUsername(el) {
    if (!(el instanceof HTMLInputElement) || !textType(el)) return false;
    const auto = (el.getAttribute("autocomplete") || "").toLowerCase();
    if (auto.includes("one-time-code")) return false;
    if (auto.includes("username") || auto.includes("email")) return true;
    const text = hints(el);
    if (NOT_LOGIN.test(text)) return false;
    if (el.type === "email" || USER_HINT.test(text)) return true;
    // Un campo de texto justo antes de una contraseña también vale.
    return !!passwordAfter(el);
  }

  function passwordAfter(el) {
    const list = inputs(el.form || document);
    const index = list.indexOf(el);
    return list.slice(index + 1, index + 4).find(isPassword) || null;
  }

  function isLoginField(el) {
    if (!(el instanceof HTMLInputElement) || !visible(el)) return false;
    if (isPassword(el)) return true;
    return isUsername(el);
  }

  /// Usuario y contraseña del mismo formulario que el campo.
  function pair(field) {
    const scope = field.form || document;
    const list = inputs(scope);
    let password = isPassword(field) ? field : list.find(isPassword) || null;
    let user = null;
    const anchor = password || field;
    const index = list.indexOf(anchor);
    for (let i = index - 1; i >= 0; i--) {
      if (!isPassword(list[i]) && textType(list[i]) && !NOT_LOGIN.test(hints(list[i]))) {
        user = list[i];
        break;
      }
    }
    if (!isPassword(field)) user = field;
    return { user, password };
  }

  function firstLoginField() {
    return inputs(document).find(isPassword) || inputs(document).find(isUsername) || null;
  }

  function setValue(el, value) {
    if (!el || value == null) return;
    el.focus({ preventScroll: true });
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function fill(field, user, password) {
    field = field?.isConnected ? field : firstLoginField();
    if (!field) return;
    const { user: userField, password: passwordField } = pair(field);
    if (userField && user) setValue(userField, user);
    if (passwordField && password) setValue(passwordField, password);
    (passwordField || userField)?.focus({ preventScroll: true });
  }

  // ---------- Lista bajo el campo ----------

  let host = null;
  let shadow = null;
  let badgeHost = null; // icono dentro del campo
  let badgeField = null;
  let current = null; // campo al que se refiere la lista
  let entries = null; // cuentas de esta web (se piden una vez)
  let locked = false;
  let highlighted = -1;

  async function loadEntries() {
    if (entries) return;
    const reply = await api.runtime.sendMessage({ type: "list" }).catch(() => ({ error: "offline" }));
    locked = !!reply.locked;
    entries = reply.entries || [];
    if (reply.error) entries = null; // sin emparejar o sin Hush: se vuelve a intentar en otro foco
  }

  function ensureHost() {
    if (host?.isConnected) return;
    host = document.createElement("hush-autofill");
    host.style.cssText = "all: initial; position: fixed; z-index: 2147483647; top: 0; left: 0;";
    shadow = host.attachShadow({ mode: "closed" });
    shadow.innerHTML = `<style>
      :host { all: initial; }
      .menu { box-sizing: border-box; min-width: 260px; max-width: 360px; background: #111111; color: #fafafa;
        border: 1px solid #2a2a2a; border-radius: 12px; padding: 6px; box-shadow: 0 12px 32px rgba(0,0,0,.35);
        font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
      .head { display: flex; align-items: center; gap: 6px; padding: 4px 8px 6px; color: #999; font-size: 11px; font-weight: 600; }
      .head img { width: 16px; height: 16px; border-radius: 4px; }
      .row { display: flex; align-items: center; gap: 10px; width: 100%; padding: 8px; border: 0; border-radius: 8px;
        background: transparent; color: inherit; text-align: left; cursor: pointer; font: inherit; }
      .row:hover, .row.on { background: #232526; }
      .badge { flex: none; width: 28px; height: 28px; border-radius: 8px; background: #fafafa; color: #050505;
        display: grid; place-items: center; font-weight: 700; font-size: 13px; }
      .text { min-width: 0; }
      .title { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .user { color: #999; font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .note { padding: 8px; color: #b4b4b4; }
    </style><div class="menu" role="listbox" aria-label="Hush"></div>`;
    document.documentElement.appendChild(host);
    host.addEventListener("mousedown", (event) => event.preventDefault()); // no quitar el foco al campo
  }

  function place() {
    if (!host || !current) return;
    const rect = current.getBoundingClientRect();
    const menu = shadow.querySelector(".menu");
    const below = rect.bottom + 6;
    const fitsBelow = below + menu.offsetHeight < window.innerHeight;
    host.style.top = `${fitsBelow ? below : Math.max(6, rect.top - menu.offsetHeight - 6)}px`;
    host.style.left = `${Math.max(6, Math.min(rect.left, window.innerWidth - menu.offsetWidth - 6))}px`;
    menu.style.width = `${Math.max(260, Math.min(360, rect.width))}px`;
  }

  function render() {
    const menu = shadow.querySelector(".menu");
    menu.textContent = "";
    const head = document.createElement("div");
    head.className = "head";
    const logo = document.createElement("img");
    logo.src = APP_ICON;
    logo.alt = "";
    head.append(logo, "Hush");
    menu.append(head);

    if (locked) {
      menu.append(row("·", "Hush está bloqueada", "Pulsa para desbloquear", () => {
        api.runtime.sendMessage({ type: "unlock" });
        entries = null;
        hide();
      }, 0));
    } else {
      entries.slice(0, 6).forEach((entry, index) => {
        const initial = (entry.title || "?").trim().charAt(0).toUpperCase();
        menu.append(row(initial, entry.title, entry.user || "Sin usuario", () => choose(entry), index));
      });
    }
    place();
  }

  function row(badge, title, subtitle, action, index) {
    const button = document.createElement("button");
    button.className = "row" + (index === highlighted ? " on" : "");
    button.setAttribute("role", "option");
    const b = document.createElement("span");
    b.className = "badge";
    b.textContent = badge;
    const text = document.createElement("span");
    text.className = "text";
    const t = document.createElement("div");
    t.className = "title";
    t.textContent = title;
    const u = document.createElement("div");
    u.className = "user";
    u.textContent = subtitle;
    text.append(t, u);
    button.append(b, text);
    button.addEventListener("click", (event) => {
      if (!event.isTrusted) return; // la propia página no puede elegir por ti
      action();
    });
    return button;
  }

  async function choose(entry) {
    const field = current;
    hide();
    const reply = await api.runtime.sendMessage({ type: "fill", uuid: entry.uuid, vault: entry.vault }).catch(() => null);
    if (reply && !reply.error) fill(field, reply.user, reply.password);
  }

  function itemCount() {
    return locked ? 1 : Math.min(entries?.length || 0, 6);
  }

  /// Abre la lista de cuentas del campo (al pulsar el icono o con ↓).
  async function show(field) {
    current = field;
    await loadEntries();
    if (current !== field) return;
    if (!entries || (!locked && entries.length === 0)) return;
    ensureHost();
    highlighted = -1;
    host.style.display = "block";
    render();
  }

  function hide() {
    if (host) host.style.display = "none";
    current = null;
    highlighted = -1;
  }

  const isOpen = () => host && host.style.display !== "none" && current;

  // ---------- Icono dentro del campo ----------

  /// Campo donde va el icono: el de usuario del formulario (o la contraseña si no hay usuario),
  /// para no chocar con el ojo de «mostrar contraseña» que muchas webs ponen a la derecha.
  function badgeTarget(field) {
    const { user, password } = pair(field);
    return user && visible(user) ? user : password;
  }

  function ensureBadge() {
    if (badgeHost?.isConnected) return;
    badgeHost = document.createElement("hush-badge");
    badgeHost.style.cssText = "all: initial; position: fixed; z-index: 2147483646; top: 0; left: 0; display: none;";
    const root = badgeHost.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      button { all: initial; display: block; width: 22px; height: 22px; cursor: pointer; border-radius: 6px;
        background: url("${APP_ICON}") center / 22px 22px no-repeat; opacity: .9; transition: opacity .12s, transform .12s; }
      button:hover { opacity: 1; transform: scale(1.06); }
      button:focus-visible { outline: 2px solid #4c8dff; outline-offset: 2px; }
    </style><button type="button" title="Rellenar con Hush" aria-label="Rellenar con Hush"></button>`;
    document.documentElement.appendChild(badgeHost);
    badgeHost.addEventListener("mousedown", (event) => event.preventDefault()); // el campo no pierde el foco
    root.querySelector("button").addEventListener("click", (event) => {
      if (!event.isTrusted || !badgeField) return;
      if (isOpen()) hide();
      else show(badgeField);
    });
  }

  function placeBadge() {
    if (!badgeHost || !badgeField) return;
    if (!badgeField.isConnected || !visible(badgeField)) return hideBadge();
    const rect = badgeField.getBoundingClientRect();
    const size = 22;
    badgeHost.style.left = `${rect.right - size - 10}px`;
    badgeHost.style.top = `${rect.top + (rect.height - size) / 2}px`;
  }

  async function showBadge(field) {
    const target = badgeTarget(field);
    if (!target) return;
    await loadEntries();
    // Solo si hay algo que ofrecer: cuentas de esta web o Hush bloqueada.
    if (!entries || (!locked && entries.length === 0)) return;
    ensureBadge();
    badgeField = target;
    badgeHost.style.display = "block";
    placeBadge();
  }

  function hideBadge() {
    if (badgeHost) badgeHost.style.display = "none";
    badgeField = null;
  }

  document.addEventListener("focusin", (event) => {
    const field = event.composedPath()[0];
    if (field instanceof HTMLInputElement && isLoginField(field)) {
      if (current && current !== field) hide();
      showBadge(field);
    } else if (event.target !== host && event.target !== badgeHost) {
      hide();
      hideBadge();
    }
  }, true);

  document.addEventListener("keydown", (event) => {
    // Solo teclas de verdad: la página no puede abrir la lista ni elegir una cuenta con eventos inventados.
    if (!event.isTrusted) return;
    const target = event.composedPath()[0];
    if (!isOpen() && event.key === "ArrowDown" && !event.altKey && badgeField && target instanceof HTMLInputElement
        && isLoginField(target) && badgeHost?.style.display !== "none") {
      event.preventDefault();
      show(target);
      return;
    }
    if (!isOpen() || event.target !== current) return;
    const count = itemCount();
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      highlighted = event.key === "ArrowDown" ? Math.min(highlighted + 1, count - 1) : Math.max(highlighted - 1, 0);
      render();
    } else if (event.key === "Enter" && highlighted >= 0) {
      event.preventDefault();
      event.stopPropagation();
      if (locked) {
        api.runtime.sendMessage({ type: "unlock" });
        entries = null;
        hide();
      } else choose(entries[highlighted]);
    } else if (event.key === "Escape" || event.key.length === 1) {
      hide(); // Esc o escribir a mano: la lista se aparta (el icono sigue ahí).
    }
  }, true);

  document.addEventListener("mousedown", (event) => {
    if (isOpen() && event.target !== host && event.target !== badgeHost && event.target !== current) hide();
  }, true);

  const reposition = () => { place(); placeBadge(); };
  window.addEventListener("scroll", reposition, true);
  window.addEventListener("resize", reposition);

  // Relleno pedido desde la ventanita o con ⇧⌘L.
  api.runtime.onMessage.addListener((message) => {
    if (message?.type !== "hush-fill") return;
    // Solo la página para la que se pidió: si la pestaña ha cambiado de web entretanto, no se rellena.
    if (message.origin !== location.origin) return;
    const field = document.activeElement instanceof HTMLInputElement && isLoginField(document.activeElement)
      ? document.activeElement
      : firstLoginField();
    fill(field, message.user, message.password);
  });
})();
