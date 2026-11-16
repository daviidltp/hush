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

  // Si Hush tiene apagado «Ofrecer guardar contraseñas nuevas» (o esta web está en «No preguntar»), no se
  // captura nada. Se pregunta al cargar y al entrar en un campo, para tener la respuesta antes de enviar:
  // al entrar, la web suele cambiar de página y no daría tiempo a preguntar en ese momento.
  let enabled = false;
  let askedAt = 0;
  function refreshEnabled() {
    if (Date.now() - askedAt < 5000) return;
    askedAt = Date.now();
    send({ type: "save-enabled" }).then((reply) => { enabled = reply?.enabled === true; });
  }
  refreshEnabled();
  document.addEventListener("focusin", (event) => {
    if (event.composedPath()[0] instanceof HTMLInputElement) refreshEnabled();
  }, true);

  let lastSent = "";
  let lastTimer;

  function trigger(origin) {
    if (!enabled) return;
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
  //
  // Tarjeta arriba a la derecha: cabecera (logo, pregunta, cerrar), la cuenta en una fila (con lápiz para
  // editar los datos), y abajo «Guardar» con la carpeta a la derecha. Para actualizar, la fila lleva el botón.
  // Entra deslizándose desde el borde derecho (150 ms, ease-out) y la sombra aparece al terminar; si vuelve a
  // salir tras cambiar de página, solo aparece con un fundido. Al cerrarse desaparece sin animación.

  if (window.top !== window) return;

  const ICONS = {
    eye: '<svg viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8 12.1 12.5 8 12.5 1.5 8 1.5 8Z"/><circle cx="8" cy="8" r="2"/></svg>',
    eyeOff: '<svg viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><path d="M6.2 3.8A6.6 6.6 0 0 1 8 3.5c4.1 0 6.5 4.5 6.5 4.5a11 11 0 0 1-1.8 2.3M4.2 4.9A11 11 0 0 0 1.5 8s2.4 4.5 6.5 4.5c1 0 2-.3 2.8-.7M6.6 6.6a2 2 0 0 0 2.8 2.8M2 2l12 12"/></svg>',
    close: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8"/></svg>',
    check: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
    warning: '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M12 4 2.8 19.5h18.4L12 4Z" stroke-linejoin="round"/><path d="M12 10v4.2M12 16.9v.1"/></svg>',
    pencil: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><path d="M10.6 2.6a1.5 1.5 0 0 1 2.1 0l.7.7a1.5 1.5 0 0 1 0 2.1L6 12.8l-3.3.6.6-3.3 7.3-7.5Z"/><path d="M9.5 3.8l2.7 2.7"/></svg>',
    folder: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><path d="M1.8 4.2c0-.7.5-1.2 1.2-1.2h3l1.4 1.6h5.6c.7 0 1.2.5 1.2 1.2v6c0 .7-.5 1.2-1.2 1.2H3c-.7 0-1.2-.5-1.2-1.2v-7.6Z"/></svg>',
    chevron: '<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 6.5 8 10l3.5-3.5"/></svg>',
  };

  // Tokens de Theme.swift (oscuro y claro, según el sistema).
  const STYLE = `
    :host { all: initial; }
    * { box-sizing: border-box; }
    .clip {
      --bg: #050505; --subtle: #111111; --sheet: #101213; --fill: #181818; --hover: #232526;
      --border: #242424; --strong: #383838; --text: #fafafa; --text2: #b4b4b4; --text3: #999999;
      --primary: #ffffff; --on-primary: #050505; --primary-hover: #e8e8e8;
      --green: #62c28a; --amber: #f1b35b; --blue: #74b9e8;
      --shadow: 0 12px 32px rgba(0,0,0,.45), 0 2px 6px rgba(0,0,0,.3);
      color-scheme: dark;
    }
    @media (prefers-color-scheme: light) {
      .clip {
        --bg: #ffffff; --subtle: #f7f7f7; --sheet: #ffffff; --fill: #f2f2f2; --hover: #e8e8e8;
        --border: #ececec; --strong: #d4d4d4; --text: #0d0d0d; --text2: #595959; --text3: #6d6d6d;
        --primary: #0d0d0d; --on-primary: #ffffff; --primary-hover: #2a2a2a;
        --green: #1a7f37; --amber: #8f5f00; --blue: #0a6cff;
        --shadow: 0 12px 32px rgba(0,0,0,.14), 0 2px 6px rgba(0,0,0,.08);
        color-scheme: light;
      }
    }
    /* El recorte evita que la tarjeta, mientras entra, saque una barra de desplazamiento horizontal en la página.
       Deja sitio a la sombra y no captura clics fuera de la tarjeta. */
    .clip { width: 468px; max-width: 100vw; padding: 0 20px 56px 48px; overflow: hidden; pointer-events: none;
      font: 13px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; color: var(--text); }
    .slide { transition: transform .15s ease-out, opacity .15s ease; }
    .slide.from-edge { transform: translateX(calc(100% + 20px)); }
    .slide.faded { opacity: 0; }
    .card { pointer-events: auto; width: 400px; max-width: 100%; max-height: calc(100vh - 76px); overflow: auto; border: 1px solid var(--border);
      border-radius: 16px; background: var(--subtle); box-shadow: none; transition: box-shadow .15s ease .15s; }
    .card.lifted { box-shadow: var(--shadow); }
    @media (prefers-reduced-motion: reduce) {
      .slide.from-edge { transform: none; opacity: 0; }
      .card { transition: none; }
    }

    header { display: flex; align-items: center; gap: 8px; padding: 12px 12px 10px 16px; background: var(--sheet);
      border-bottom: .5px solid var(--border); border-radius: 16px 16px 0 0; }
    .logo { width: 22px; height: 22px; border-radius: 6px; flex: none; }
    h2 { margin: 0; flex: 1; min-width: 0; font-size: 14px; font-weight: 650; letter-spacing: -.01em;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .icon-button { all: unset; display: grid; place-items: center; width: 28px; height: 28px; border-radius: 8px;
      color: var(--text3); cursor: pointer; flex: none; }
    .icon-button:hover { background: var(--fill); color: var(--text); }

    .body { padding: 12px 12px 0; display: grid; gap: 10px; }
    .item { display: flex; align-items: center; gap: 10px; padding: 8px 8px 8px 10px; border-radius: 12px; background: var(--sheet);
      border: 1px solid var(--border); }
    .avatar { width: 32px; height: 32px; border-radius: 9px; background: var(--primary); color: var(--on-primary);
      display: grid; place-items: center; font-weight: 700; font-size: 14px; flex: none; }
    .info { flex: 1; min-width: 0; }
    .name { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .user { color: var(--text3); font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .icon-button[aria-expanded="true"] { background: var(--fill); color: var(--text); }
    .badge { all: unset; padding: 6px 12px; border-radius: 999px; background: var(--primary); color: var(--on-primary);
      font-weight: 600; font-size: 12px; cursor: pointer; flex: none; }
    .badge:hover { background: var(--primary-hover); }
    .hint { margin: 0; color: var(--text2); font-size: 12px; }
    .hint:empty { display: none; }

    form { display: grid; gap: 9px; margin: 0; }
    .field { display: grid; gap: 4px; }
    .field > span, .label { color: var(--text3); font-size: 11px; font-weight: 600; }
    input, textarea { width: 100%; margin: 0; background: var(--fill); color: var(--text); border: 1px solid var(--border);
      border-radius: 10px; padding: 7px 10px; font: inherit; outline: none; }
    textarea { resize: vertical; min-height: 52px; }
    input:focus, textarea:focus { border-color: var(--strong); box-shadow: 0 0 0 3px color-mix(in srgb, var(--blue) 22%, transparent); }
    .pw { position: relative; }
    .pw input { padding-right: 36px; font-family: ui-monospace, "SF Mono", Menlo, monospace; }
    .pw .icon-button { position: absolute; right: 3px; top: 50%; transform: translateY(-50%); width: 28px; height: 26px; }

    footer { padding: 12px; display: grid; gap: 8px; }
    .row { display: flex; align-items: center; gap: 8px; }
    .button { all: unset; padding: 8px 16px; border-radius: 10px; font-weight: 600; cursor: pointer; white-space: nowrap; }
    .primary { background: var(--primary); color: var(--on-primary); }
    .primary:hover { background: var(--primary-hover); }
    .ghost { color: var(--text2); padding: 8px 10px; }
    .ghost:hover { background: var(--fill); color: var(--text); }
    .button[aria-disabled="true"] { opacity: .55; cursor: default; }
    .chip { margin-left: auto; position: relative; display: flex; align-items: center; gap: 6px; min-width: 0; max-width: 170px;
      padding: 6px 8px 6px 10px; border-radius: 999px; border: 1px solid var(--border); background: var(--sheet); color: var(--text2); }
    .chip:hover { border-color: var(--strong); color: var(--text); }
    .chip svg { flex: none; }
    .chip span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 12px; }
    /* El selector de verdad va encima, transparente: así se abre el menú nativo del navegador. */
    .chip select { position: absolute; inset: 0; opacity: 0; cursor: pointer; font: inherit; width: 100%; }
    .never { all: unset; justify-self: start; color: var(--text3); font-size: 12px; cursor: pointer; padding: 2px 4px; margin-left: -4px; border-radius: 6px; }
    .never:hover { color: var(--text); text-decoration: underline; }
    .status { margin: 0; padding: 0 16px 12px; font-size: 12px; color: var(--amber); }
    .status:empty { display: none; }

    .done { display: flex; align-items: center; gap: 14px; padding: 16px; }
    .done .mark { width: 44px; height: 44px; border-radius: 50%; display: grid; place-items: center; flex: none;
      background: color-mix(in srgb, var(--green) 16%, transparent); color: var(--green); }
    .done.warning .mark { background: color-mix(in srgb, var(--amber) 16%, transparent); color: var(--amber); }
    .done p { margin: 0; }
    .done .what { font-weight: 600; }
    .done .detail { color: var(--text3); font-size: 12px; overflow-wrap: anywhere; }

    [hidden] { display: none !important; }
    button:focus-visible, .icon-button:focus-visible, .badge:focus-visible, .never:focus-visible { outline: 2px solid var(--blue); outline-offset: 2px; }
    .chip:focus-within { outline: 2px solid var(--blue); outline-offset: 2px; }
  `;

  const MARKUP = `
    <div class="clip"><div class="slide">
      <section class="card" role="dialog" aria-labelledby="heading">
        <header>
          <img class="logo" alt="">
          <h2 id="heading"></h2>
          <button type="button" class="icon-button close" aria-label="Ahora no" title="Ahora no">${ICONS.close}</button>
        </header>
        <div class="content">
          <div class="body">
            <div class="item">
              <span class="avatar" aria-hidden="true"></span>
              <div class="info"><div class="name"></div><div class="user"></div></div>
              <button type="button" class="icon-button edit" aria-expanded="false" aria-label="Editar antes de guardar" title="Editar">${ICONS.pencil}</button>
              <button type="button" class="badge update">Actualizar</button>
            </div>
            <p class="hint"></p>
            <form class="editor" novalidate hidden>
              <label class="field" data-new><span>Título</span><input name="title" autocomplete="off" spellcheck="false" maxlength="1024"></label>
              <label class="field" data-new><span>Usuario</span><input name="user" autocomplete="off" spellcheck="false" maxlength="1024"></label>
              <div class="field"><span class="label" id="pw-label">Contraseña</span>
                <div class="pw"><input name="password" type="password" autocomplete="off" spellcheck="false" aria-labelledby="pw-label" maxlength="4096">
                <button type="button" class="icon-button eye" aria-label="Mostrar contraseña">${ICONS.eye}</button></div></div>
              <label class="field" data-new><span>Web</span><input name="web" autocomplete="off" spellcheck="false" maxlength="1024"></label>
              <label class="field" data-new><span>Nota</span><textarea name="notes" rows="2" maxlength="65536"></textarea></label>
              <button type="submit" hidden></button>
            </form>
          </div>
          <footer>
            <div class="row" data-new>
              <button type="button" class="button primary save">Guardar</button>
              <button type="button" class="button ghost later">Ahora no</button>
              <label class="chip" data-folder title="Carpeta">${ICONS.folder}<span class="folder-name"></span>${ICONS.chevron}
                <select name="group" aria-label="Carpeta"></select></label>
            </div>
            <button type="button" class="never">No preguntar en esta web</button>
          </footer>
          <p class="status" role="status" aria-live="polite"></p>
        </div>
      </section>
    </div></div>`;

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
    host.style.cssText = "all: initial; position: fixed; z-index: 2147483647; top: 10px; right: 0; display: block;";
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
    $(".save").addEventListener("click", trusted(() => save()));
    $(".update").addEventListener("click", trusted(() => save()));
    $(".edit").addEventListener("click", trusted(() => {
      const open = $(".edit").getAttribute("aria-expanded") !== "true";
      $(".edit").setAttribute("aria-expanded", String(open));
      $(".editor").hidden = !open;
      if (open) $('[name="title"]').focus();
    }));
    $(".eye").addEventListener("click", trusted(() => {
      const input = $('input[name="password"]');
      const show = input.type === "password";
      input.type = show ? "text" : "password";
      $(".eye").innerHTML = show ? ICONS.eyeOff : ICONS.eye;
      $(".eye").setAttribute("aria-label", show ? "Ocultar contraseña" : "Mostrar contraseña");
    }));
    $('select[name="group"]').addEventListener("change", () => showFolder());
    $(".editor").addEventListener("submit", (event) => {
      event.preventDefault();
      if (event.isTrusted) save(); // Enter en un campo del panel; la página no puede enviarlo
    });
    root.addEventListener("input", (event) => {
      const field = event.composedPath()[0];
      if (field instanceof HTMLElement) field.dataset.touched = "1"; // lo cambiado a mano no se pisa al repintar
      if (field?.name === "title" || field?.name === "user") showItem();
    });
    root.addEventListener("keydown", (event) => {
      if (event.isTrusted && event.key === "Escape") dismiss(false);
    });

    document.documentElement.appendChild(host);
    enter(offer.animate === "slide");
  }

  /// Entrada: desde el borde derecho la primera vez; con un fundido si reaparece tras cambiar de página.
  function enter(slide) {
    const { root } = panel;
    const box = root.querySelector(".slide");
    const card = root.querySelector(".card");
    box.classList.add(slide ? "from-edge" : "faded");
    box.getBoundingClientRect(); // fija el punto de partida antes de animar
    requestAnimationFrame(() => {
      box.classList.remove("from-edge", "faded");
      card.classList.add("lifted"); // la sombra llega cuando la tarjeta ya está en su sitio
    });
  }

  /// Fila de la cuenta: título y usuario tal como se van a guardar.
  function showItem() {
    const { root, offer } = panel;
    const $ = (s) => root.querySelector(s);
    const title = offer.update ? (offer.update.title || offer.title) : $('[name="title"]').value.trim() || offer.title;
    const user = offer.update ? offer.user : $('[name="user"]').value.trim();
    $(".name").textContent = title || "Sin título";
    $(".user").textContent = user || "Sin usuario";
    $(".avatar").textContent = (title || "?").charAt(0).toUpperCase();
  }

  function showFolder() {
    const select = panel.root.querySelector('select[name="group"]');
    const name = select.selectedOptions[0]?.dataset.name ?? "";
    panel.root.querySelector(".folder-name").textContent = name;
  }

  /// Pone el panel según la oferta: cuenta nueva o actualizar la contraseña de una entrada.
  function render() {
    const { root, offer } = panel;
    const $ = (s) => root.querySelector(s);
    const update = offer.update;
    $("#heading").textContent = update ? "¿Actualizar la contraseña?" : "¿Guardar en Hush?";
    for (const el of root.querySelectorAll("[data-new]")) el.hidden = !!update;
    $(".edit").hidden = !!update;
    $(".update").hidden = !update;
    // Al actualizar se ve la contraseña nueva (con el ojo); para guardar, los datos se editan con el lápiz.
    if (update) $(".editor").hidden = false;
    else $(".editor").hidden = $(".edit").getAttribute("aria-expanded") !== "true";
    $(".hint").textContent = offer.locked ? "Hush está bloqueada: al guardar te pedirá Touch ID o la contraseña." : "";

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
      option.dataset.name = group.name;
      option.textContent = `${" ".repeat(Math.min(group.level, 6))}${group.name}`;
      select.append(option);
    }
    if (previous && [...select.options].some((o) => o.value === previous)) select.value = previous;
    $("[data-folder]").hidden = !!update || !(offer.groups || []).length;
    showFolder();
    showItem();
  }

  function setStatus(text) {
    panel.root.querySelector(".status").textContent = text;
  }

  function setBusy(label) {
    const button = panel.root.querySelector(panel.offer.update ? ".update" : ".save");
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
      if (check.known) return finish("Ya estaba en Hush", value("title") || current.offer.title);
      if (check.error) {
        setBusy(null);
        setStatus(ERRORS[check.error] || "No se ha podido comprobar. Prueba otra vez.");
        return;
      }
      current.offer = { ...current.offer, ...check, locked: false };
      setBusy(null);
      render();
      if (check.update) {
        // Cambia lo que se va a hacer: mejor que lo confirmes.
        setStatus("Ya tenías esta cuenta en Hush. Pulsa Actualizar para cambiar su contraseña.");
        return;
      }
    }

    const update = current.offer.update;
    setBusy(update ? "Actualizando…" : "Guardando…");
    const reply = await send({
      type: "save-commit",
      password: value("password"),
      ...(update
        ? { uuid: update.uuid, vault: update.vault }
        : { title: value("title"), user: value("user"), web: value("web"), group: value("group") || undefined, notes: value("notes") }),
    });
    if (panel !== current) return;
    const what = update ? (update.title || current.offer.title) : (value("title").trim() || current.offer.title);
    if (reply.ok && reply.saved) {
      finish(update ? "Contraseña actualizada" : "Guardado en Hush", what);
    } else if (reply.ok) {
      finish("No se ha podido escribir el archivo", "Está en Hush, pero sin guardar en disco. Abre Hush para revisarlo.", true);
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

  /// La misma tarjeta pasa a confirmar lo que ha pasado y se cierra sola.
  function finish(text, detail, warning) {
    const current = panel;
    send({ type: "save-done", id: current.offer.id });
    wipe(current);
    const content = current.root.querySelector(".content");
    content.innerHTML = `<div class="done${warning ? " warning" : ""}"><span class="mark">${warning ? ICONS.warning : ICONS.check}</span>
      <div><p class="what"></p><p class="detail"></p></div></div>`;
    content.querySelector(".what").textContent = text;
    content.querySelector(".detail").textContent = detail || "";
    current.root.querySelector("#heading").textContent = "Hush";
    current.timer = setTimeout(() => { if (panel === current) removePanel(); }, warning ? 6000 : 2600);
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
