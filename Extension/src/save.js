// Hush en la página: cuando entras o te registras en una web con una cuenta que Hush no tiene, ofrece guardarla
// (o actualizar la contraseña si ya la tenías con otra). El panel va arriba a la derecha, en un Shadow DOM cerrado.
//
// - Solo cuenta lo que has escrito tú (eventos de teclado reales): ni lo que rellena Hush ni lo que pone la página.
// - Nada de campos de tarjeta ni códigos de un solo uso.
// - La contraseña vive en memoria (aquí y en la extensión) solo hasta que guardas o cierras el panel.
(() => {
  if (window.__hushSaveLoaded) return;
  window.__hushSaveLoaded = true;
  const api = globalThis.browser ?? globalThis.chrome;
  const APP_ICON = "__ICON__";

  const send = (message) => api.runtime.sendMessage(message).catch(() => ({ error: "offline" }));

  // ---------- Detectar que entras o te registras ----------

  const USER_HINT = /user|email|e-mail|mail|login|account|usuario|correo|identifier|nif|dni|cuenta|phone|tel[eé]fono/i;
  const NOT_LOGIN = /search|buscar|query|coupon|cupon|captcha|otp|totp|one-time|code|codigo|código/i;
  // Campos que no son contraseñas de una cuenta: tarjetas, PIN y códigos de verificación.
  const NOT_SECRET = /cvv|cvc|csc|card|tarjeta|\bpin\b|otp|totp|one-?time|2fa|mfa|verif|security.?code|c[oó]digo|code/i;
  const SUBMIT_WORDS = /log.?in|sign.?in|sign.?up|register|registr|iniciar|inicia|entrar|acceder|accede|crear|create|continu|next|siguiente|submit|enviar|confirm|join|[uú]nete|unirse|start|empezar/i;

  /// Campos en los que has escrito tú. Lo que rellena Hush (o la propia página) no dispara eventos reales.
  const typed = new WeakSet();
  document.addEventListener("input", (event) => {
    if (!event.isTrusted) return;
    const field = event.composedPath()[0];
    if (field instanceof HTMLInputElement) typed.add(field);
  }, true);

  const hints = (el) => [el.name, el.id, el.placeholder, el.getAttribute("aria-label"), el.getAttribute("autocomplete")].join(" ");
  const autocomplete = (el) => (el.getAttribute("autocomplete") || "").toLowerCase();
  const textType = (el) => ["text", "email", "tel", ""].includes((el.getAttribute("type") || "text").toLowerCase());

  function visible(el) {
    if (!el.isConnected) return false;
    const rect = el.getBoundingClientRect();
    if (rect.width < 2 || rect.height < 2) return false;
    const style = getComputedStyle(el);
    return style.visibility !== "hidden" && style.display !== "none";
  }

  function isSecret(el) {
    if (!(el instanceof HTMLInputElement) || el.type !== "password" || !el.value || el.value.length > 4096) return false;
    const auto = autocomplete(el);
    if (auto.startsWith("cc-") || auto.includes("one-time-code")) return false;
    return !NOT_SECRET.test(hints(el));
  }

  function isUserField(el, strict) {
    if (!(el instanceof HTMLInputElement) || !textType(el) || !el.value.trim()) return false;
    const auto = autocomplete(el);
    if (auto.startsWith("cc-") || auto.includes("one-time-code")) return false;
    if (auto.includes("username") || auto.includes("email")) return true;
    if (NOT_LOGIN.test(hints(el))) return false;
    return !strict || el.type === "email" || USER_HINT.test(hints(el));
  }

  /// Contraseña escrita en el formulario. Registro (nueva + repetir) o cambio (actual + nueva + repetir): la nueva.
  function pickPassword(scope) {
    const fields = [...scope.querySelectorAll('input[type="password"]')].filter((el) => typed.has(el) && isSecret(el));
    if (!fields.length) return null;
    const fresh = fields.filter((el) => autocomplete(el).includes("new-password"));
    if (fresh.length >= 2 && fresh[0].value !== fresh[1].value) return null; // no coinciden: la web dará error
    if (fresh.length) return fresh[0];
    if (fields.length === 1) return fields[0];
    if (fields.length === 2) return fields[0].value === fields[1].value ? fields[0] : fields[1];
    return fields[1].value === fields[2].value ? fields[1] : null;
  }

  /// Usuario del formulario: el campo marcado como usuario/correo, si no el texto justo antes de la contraseña.
  function userFor(password, scope) {
    const list = [...scope.querySelectorAll("input")];
    const marked = list.find((el) => el !== password && /username|email/.test(autocomplete(el)) && el.value.trim());
    if (marked) return marked.value.trim();
    const index = list.indexOf(password);
    for (let i = index - 1; i >= 0; i--) {
      if (list[i].type !== "password" && visible(list[i]) && isUserField(list[i], false)) return list[i].value.trim();
    }
    // Formularios en varios pasos: muchas webs dejan el usuario oculto en el paso de la contraseña.
    const hidden = document.querySelector('input[autocomplete~="username" i], input[name="username"][type="hidden"]');
    return hidden?.value?.trim() || "";
  }

  let lastSent = "";
  let lastTimer;

  function trigger(origin) {
    const scope = origin?.form || origin?.closest?.("form") || document;
    let field = pickPassword(scope);
    if (!field && scope !== document) field = pickPassword(document);
    if (!field) {
      // Primer paso de un inicio de sesión en varias páginas: se recuerda el usuario en esta pestaña.
      const user = [...scope.querySelectorAll("input")].find((el) => typed.has(el) && visible(el) && isUserField(el, true));
      if (user) send({ type: "save-user", user: user.value.trim() });
      return;
    }
    const user = userFor(field, field.form || scope);
    const key = `${user}\n${field.value}`;
    if (key === lastSent) return; // el clic en el botón y el envío del formulario llegan juntos
    lastSent = key;
    clearTimeout(lastTimer);
    lastTimer = setTimeout(() => { lastSent = ""; }, 4000);
    send({ type: "save-capture", user, password: field.value });
  }

  document.addEventListener("submit", (event) => {
    if (event.isTrusted) trigger(event.target);
  }, true);

  document.addEventListener("click", (event) => {
    if (!event.isTrusted) return;
    const target = event.composedPath()[0];
    if (!(target instanceof Element)) return;
    const button = target.closest('button, input[type="submit"], input[type="button"], input[type="image"], [role="button"], a');
    if (!button) return;
    const label = [button.textContent, button.value, button.getAttribute("aria-label"), button.id, button.name, button.title]
      .join(" ").slice(0, 300);
    if (button.type !== "submit" && !SUBMIT_WORDS.test(label)) return;
    trigger(button);
  }, true);

  document.addEventListener("keydown", (event) => {
    if (!event.isTrusted || event.key !== "Enter") return;
    const field = event.composedPath()[0];
    if (field instanceof HTMLInputElement && (field.type === "password" || textType(field))) trigger(field);
  }, true);

  // ---------- Panel «¿Guardar en Hush?» (solo en la página principal) ----------

  if (window.top !== window) return;

  const ICONS = {
    eye: '<svg viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8 12.1 12.5 8 12.5 1.5 8 1.5 8Z"/><circle cx="8" cy="8" r="2"/></svg>',
    eyeOff: '<svg viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><path d="M6.2 3.8A6.6 6.6 0 0 1 8 3.5c4.1 0 6.5 4.5 6.5 4.5a11 11 0 0 1-1.8 2.3M4.2 4.9A11 11 0 0 0 1.5 8s2.4 4.5 6.5 4.5c1 0 2-.3 2.8-.7M6.6 6.6a2 2 0 0 0 2.8 2.8M2 2l12 12"/></svg>',
    close: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8"/></svg>',
    check: '<svg viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-7"/></svg>',
    chevron: '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M6 4l4 4-4 4"/></svg>',
  };

  // Colores y radios de Theme.swift (tema oscuro), como la lista de cuentas.
  const STYLE = `
    :host { all: initial; }
    * { box-sizing: border-box; }
    .panel { width: 340px; max-width: calc(100vw - 32px); max-height: calc(100vh - 32px); overflow: auto;
      background: #101213; color: #fafafa; border: 1px solid #242424; border-radius: 16px; padding: 14px 16px 12px;
      box-shadow: 0 16px 48px rgba(0,0,0,.45), 0 2px 8px rgba(0,0,0,.3);
      font: 13px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
      animation: in .18s cubic-bezier(.2,.8,.2,1); }
    @keyframes in { from { opacity: 0; transform: translateY(-6px) scale(.98); } }
    @media (prefers-reduced-motion: reduce) { .panel { animation: none; } }
    .top { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
    .logo { width: 20px; height: 20px; border-radius: 5px; }
    .brand { color: #999; font-size: 12px; font-weight: 600; flex: 1; }
    .close { all: unset; display: grid; place-items: center; width: 24px; height: 24px; border-radius: 6px; color: #999; cursor: pointer; }
    .close:hover { background: #181818; color: #fafafa; }
    h2 { margin: 0; font-size: 15px; font-weight: 650; letter-spacing: -.01em; }
    .sub { margin: 3px 0 0; color: #b4b4b4; font-size: 12px; overflow-wrap: anywhere; }
    .sub:empty { display: none; }
    form { margin: 12px 0 0; display: grid; gap: 9px; }
    .field { display: grid; gap: 4px; }
    .field > span, .label { color: #999; font-size: 11px; font-weight: 600; }
    input, select, textarea { width: 100%; margin: 0; background: #181818; color: #fafafa; border: 1px solid #242424;
      border-radius: 10px; padding: 7px 10px; font: inherit; outline: none; }
    textarea { resize: vertical; min-height: 52px; }
    select { appearance: none; padding-right: 28px; cursor: pointer;
      background-image: linear-gradient(45deg, transparent 50%, #999 50%), linear-gradient(135deg, #999 50%, transparent 50%);
      background-position: calc(100% - 15px) 52%, calc(100% - 10px) 52%; background-size: 5px 5px; background-repeat: no-repeat; }
    input:focus, select:focus, textarea:focus { border-color: #383838; box-shadow: 0 0 0 3px rgba(116,185,232,.18); }
    .pw { position: relative; }
    .pw input { padding-right: 36px; font-family: ui-monospace, "SF Mono", Menlo, monospace; }
    .eye { all: unset; position: absolute; right: 4px; top: 50%; transform: translateY(-50%); width: 28px; height: 26px;
      display: grid; place-items: center; border-radius: 7px; color: #999; cursor: pointer; }
    .eye:hover { color: #fafafa; background: #232526; }
    .more { all: unset; display: inline-flex; align-items: center; gap: 4px; color: #b4b4b4; font-size: 12px; cursor: pointer; width: max-content; }
    .more svg { transition: transform .15s; }
    .more[aria-expanded="true"] svg { transform: rotate(90deg); }
    .extra { display: grid; gap: 9px; }
    .extra[hidden], [hidden] { display: none !important; }
    .status { margin: 0; font-size: 12px; color: #f1b35b; }
    .status:empty { display: none; }
    .actions { display: flex; gap: 8px; margin-top: 3px; }
    .button { all: unset; flex: 1; text-align: center; padding: 8px 12px; border-radius: 10px; font-weight: 600; cursor: pointer; }
    .primary { background: #fff; color: #050505; }
    .primary:hover { background: #e8e8e8; }
    .secondary { background: #181818; color: #fafafa; border: 1px solid #242424; }
    .secondary:hover { background: #232526; }
    .button[aria-disabled="true"] { opacity: .55; cursor: default; }
    .never { all: unset; justify-self: center; color: #999; font-size: 12px; cursor: pointer; padding: 2px 4px; border-radius: 6px; }
    .never:hover { color: #fafafa; text-decoration: underline; }
    .done { display: flex; align-items: center; gap: 10px; }
    .done .ok { width: 28px; height: 28px; border-radius: 50%; display: grid; place-items: center; background: rgba(98,194,138,.15); color: #62c28a; flex: none; }
    button:focus-visible, .close:focus-visible, .eye:focus-visible, .more:focus-visible, .never:focus-visible { outline: 2px solid #74b9e8; outline-offset: 2px; }
  `;

  const MARKUP = `
    <div class="panel" role="dialog" aria-labelledby="heading">
      <div class="top"><img class="logo" alt=""><span class="brand">Hush</span>
        <button type="button" class="close" aria-label="Cerrar">${ICONS.close}</button></div>
      <h2 id="heading"></h2>
      <p class="sub"></p>
      <form novalidate>
        <label class="field" data-new><span>Título</span><input name="title" autocomplete="off" spellcheck="false" maxlength="1024"></label>
        <label class="field" data-new><span>Usuario</span><input name="user" autocomplete="off" spellcheck="false" maxlength="1024"></label>
        <div class="field"><span class="label" id="pw-label">Contraseña</span>
          <div class="pw"><input name="password" type="password" autocomplete="off" spellcheck="false" aria-labelledby="pw-label" maxlength="4096">
          <button type="button" class="eye" aria-label="Mostrar contraseña">${ICONS.eye}</button></div></div>
        <label class="field" data-new><span>Web</span><input name="web" autocomplete="off" spellcheck="false" maxlength="1024"></label>
        <button type="button" class="more" aria-expanded="false" data-new>${ICONS.chevron}Más opciones</button>
        <div class="extra" hidden data-new>
          <label class="field" data-folder><span>Carpeta</span><select name="group"></select></label>
          <label class="field"><span>Nota</span><textarea name="notes" rows="2" maxlength="65536"></textarea></label>
        </div>
        <p class="status" role="status" aria-live="polite"></p>
        <div class="actions">
          <button type="button" class="button secondary later">Ahora no</button>
          <button type="submit" class="button primary save">Guardar</button>
        </div>
        <button type="button" class="never">No preguntar en esta web</button>
      </form>
    </div>`;

  let panel = null; // { host, root, offer, busy, timer }

  async function pull() {
    const offer = await send({ type: "save-offer" });
    if (offer?.id && offer.id !== panel?.offer.id) showPanel(offer);
  }

  api.runtime.onMessage.addListener((message) => {
    if (message?.type === "hush-save-offer") pull();
  });
  pull(); // tras entrar, la web suele cambiar de página: el panel sigue aquí

  function showPanel(offer) {
    removePanel();
    const host = document.createElement("hush-save");
    host.style.cssText = "all: initial; position: fixed; z-index: 2147483647; top: 16px; right: 16px; display: block;";
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>${STYLE}</style>${MARKUP}`;
    root.querySelector(".logo").src = APP_ICON;
    // Que la página no reciba lo que escribes en el panel (ni sus atajos de teclado lo intercepten).
    for (const type of ["keydown", "keyup", "keypress", "input", "beforeinput", "paste", "copy", "cut", "focusin", "focusout"]) {
      root.addEventListener(type, (event) => event.stopPropagation());
    }
    panel = { host, root, offer, busy: false };
    render();
    const $ = (s) => root.querySelector(s);
    const trusted = (fn) => (event) => { if (event.isTrusted) fn(event); };
    $(".close").addEventListener("click", trusted(() => dismiss(false)));
    $(".later").addEventListener("click", trusted(() => dismiss(false)));
    $(".never").addEventListener("click", trusted(() => dismiss(true)));
    $(".eye").addEventListener("click", trusted(() => {
      const input = $('input[name="password"]');
      const show = input.type === "password";
      input.type = show ? "text" : "password";
      $(".eye").innerHTML = show ? ICONS.eyeOff : ICONS.eye;
      $(".eye").setAttribute("aria-label", show ? "Ocultar contraseña" : "Mostrar contraseña");
    }));
    $(".more").addEventListener("click", trusted(() => {
      const open = $(".more").getAttribute("aria-expanded") !== "true";
      $(".more").setAttribute("aria-expanded", String(open));
      $(".extra").hidden = !open;
    }));
    $("form").addEventListener("submit", (event) => {
      event.preventDefault();
      // Enter en un campo del panel o clic en «Guardar»: tiene que venir de ti, no de la página.
      if (event.isTrusted) save();
    });
    $(".save").addEventListener("click", (event) => { if (!event.isTrusted) event.preventDefault(); }, true);
    // Lo que cambies a mano no se pisa al volver a pintar el panel (p. ej. tras desbloquear).
    root.addEventListener("input", (event) => {
      const field = event.composedPath()[0];
      if (field instanceof HTMLElement) field.dataset.touched = "1";
    });
    root.addEventListener("keydown", (event) => {
      if (event.isTrusted && event.key === "Escape") dismiss(false);
    });
    document.documentElement.appendChild(host);
  }

  /// Pone el panel según la oferta: cuenta nueva o actualizar la contraseña de una entrada.
  function render() {
    const { root, offer } = panel;
    const $ = (s) => root.querySelector(s);
    const update = offer.update;
    $("#heading").textContent = update ? "¿Actualizar la contraseña?" : "¿Guardar en Hush?";
    let sub = "";
    if (update) sub = `${update.title || offer.title} · ${offer.user || "sin usuario"}`;
    else if (offer.locked) sub = "Hush está bloqueada: al guardar te pedirá Touch ID o la contraseña.";
    $(".sub").textContent = sub;
    for (const el of root.querySelectorAll("[data-new]")) el.hidden = !!update;
    if (!update) $(".extra").hidden = $(".more").getAttribute("aria-expanded") !== "true";
    $(".save").textContent = update ? "Actualizar" : "Guardar";

    const fill = (name, value) => {
      const input = $(`[name="${name}"]`);
      if (!input.dataset.touched) input.value = value ?? "";
    };
    fill("title", offer.title);
    fill("user", offer.user);
    fill("password", offer.password);
    fill("web", offer.web);

    // Carpetas de la base (con Hush bloqueada no se ven: se guarda en la principal).
    const select = $('select[name="group"]');
    const previous = select.value;
    select.textContent = "";
    for (const group of offer.groups || []) {
      const option = document.createElement("option");
      option.value = group.id;
      option.textContent = `${" ".repeat(Math.min(group.level, 6))}${group.name}`;
      select.append(option);
    }
    if (previous && [...select.options].some((o) => o.value === previous)) select.value = previous;
    $("[data-folder]").hidden = !(offer.groups || []).length;
  }

  function setStatus(text) {
    panel.root.querySelector(".status").textContent = text;
  }

  function setBusy(label) {
    const button = panel.root.querySelector(".save");
    panel.busy = !!label;
    button.setAttribute("aria-disabled", String(!!label));
    button.textContent = label || (panel.offer.update ? "Actualizar" : "Guardar");
  }

  const ERRORS = {
    "other-site": "La web tiene que ser de este mismo sitio.",
    "not-found": "Ya no está la entrada o la carpeta. Vuelve a intentarlo.",
    busy: "Hush está ocupada ahora mismo. Prueba otra vez en un momento.",
    offline: "No se puede hablar con Hush. ¿Está abierta?",
    timeout: "Hush no responde. Prueba otra vez.",
    expired: "Ha pasado demasiado tiempo. Vuelve a entrar en la web para guardarla.",
    unpaired: "Conecta este navegador con Hush desde la extensión.",
  };

  async function save() {
    if (!panel || panel.busy) return;
    const current = panel;
    const $ = (s) => current.root.querySelector(s);
    const value = (name) => $(`[name="${name}"]`).value;
    if (!value("password")) {
      setStatus("Falta la contraseña.");
      return;
    }
    setStatus("");

    if (current.offer.locked) {
      setBusy("Desbloqueando…");
      const unlocked = await send({ type: "save-unlock" });
      if (panel !== current) return;
      if (unlocked.locked || unlocked.error) {
        setBusy(null);
        setStatus(ERRORS[unlocked.error] || "Desbloquea Hush y vuelve a pulsar Guardar.");
        return;
      }
      // Ya desbloqueada: se mira de nuevo si la cuenta ya estaba en Hush.
      const check = await send({ type: "save-recheck", user: value("user"), password: value("password") });
      if (panel !== current) return;
      if (check.known) return finish("Ya estaba guardada en Hush.");
      if (check.error) {
        setBusy(null);
        setStatus(ERRORS[check.error] || "No se ha podido comprobar. Prueba otra vez.");
        return;
      }
      current.offer = { ...current.offer, ...check, locked: false };
      render();
      if (check.update) {
        // Cambia lo que se va a hacer: mejor que lo confirmes.
        setBusy(null);
        setStatus("Ya tenías esta cuenta en Hush. Pulsa Actualizar para cambiar su contraseña.");
        return;
      }
    }

    setBusy(current.offer.update ? "Actualizando…" : "Guardando…");
    const update = current.offer.update;
    const reply = await send({
      type: "save-commit",
      password: value("password"),
      ...(update
        ? { uuid: update.uuid, vault: update.vault }
        : { title: value("title"), user: value("user"), web: value("web"), group: value("group") || undefined, notes: value("notes") }),
    });
    if (panel !== current) return;
    if (reply.ok) {
      finish(reply.saved
        ? (update ? "Contraseña actualizada en Hush." : "Guardado en Hush.")
        : "Está en Hush, pero no se ha podido escribir el archivo. Abre Hush para revisarlo.", !reply.saved);
    } else if (reply.locked) {
      current.offer.locked = true;
      setBusy(null);
      render();
      setStatus("Hush se ha bloqueado. Pulsa Guardar otra vez.");
    } else {
      setBusy(null);
      setStatus(ERRORS[reply.error] || "No se ha podido guardar. Prueba otra vez.");
    }
  }

  /// Muestra el resultado un momento y cierra.
  function finish(text, warning) {
    const current = panel;
    send({ type: "save-done", id: current.offer.id });
    wipe(current);
    const box = current.root.querySelector(".panel");
    box.innerHTML = `<div class="done"><span class="ok">${ICONS.check}</span><div><h2></h2></div></div>`;
    box.querySelector("h2").textContent = text;
    if (warning) box.querySelector(".ok").style.cssText = "background: rgba(241,179,91,.15); color: #f1b35b;";
    current.timer = setTimeout(() => { if (panel === current) removePanel(); }, warning ? 6000 : 2200);
  }

  function dismiss(never) {
    if (!panel) return;
    send({ type: "save-done", id: panel.offer.id, never });
    removePanel();
  }

  /// Borra la contraseña del panel y de la memoria de esta página.
  function wipe(current) {
    for (const input of current.root.querySelectorAll("input, textarea")) input.value = "";
    current.offer = { id: current.offer.id };
  }

  function removePanel() {
    if (!panel) return;
    clearTimeout(panel.timer);
    wipe(panel);
    panel.host.remove();
    panel = null;
  }
})();
