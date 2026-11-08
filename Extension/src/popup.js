// Ventanita de la extensión: cuentas de esta web, buscador y botones para rellenar o copiar.
const api = globalThis.browser ?? globalThis.chrome;
const view = document.getElementById("view");

// Iconos (trazos simples, mismo color que el texto).
const ICONS = {
  user: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="5.5" r="2.75"/><path d="M2.75 14c.6-2.6 2.7-4 5.25-4s4.65 1.4 5.25 4" stroke-linecap="round"/></svg>',
  key: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="5.5" cy="8" r="3"/><path d="M8.5 8h6M12.5 8v2.5M14.5 8v2" stroke-linecap="round"/></svg>',
  code: '<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6"/><path d="M8 4.75V8l2.25 1.5" stroke-linecap="round"/></svg>',
};

function iconButton(name, title) {
  const button = el("button", "icon");
  button.innerHTML = ICONS[name];
  button.title = title;
  button.setAttribute("aria-label", title);
  return button;
}

const send = (message) => api.runtime.sendMessage(message).catch(() => ({ error: "offline" }));

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function stateView(title, body, buttonLabel, action, extra) {
  view.textContent = "";
  const box = el("div", "state");
  box.append(el("h2", null, title), el("p", null, body));
  if (extra) box.append(extra);
  if (buttonLabel) {
    const button = el("button", "button", buttonLabel);
    button.addEventListener("click", () => action(button));
    box.append(button);
  }
  view.append(box);
}

async function start() {
  const state = await send({ type: "state" });
  if (state.error === "offline" || state.error === "timeout") {
    stateView("No se puede hablar con Hush", "Abre Hush en el Mac. Si acabas de instalarla, ábrela una vez para que el navegador la encuentre.", "Reintentar", start);
  } else if (state.error === "unpaired") {
    stateView("Conecta el navegador", "Hush te pedirá permiso. Comprueba que el código coincide:", "Conectar con Hush", async (button) => {
      button.disabled = true;
      button.textContent = "Esperando a Hush…";
      const reply = await send({ type: "pair" });
      if (reply.paired) start();
      else stateView("No se ha conectado", "Has dicho que no en Hush, o se ha cerrado el aviso.", "Volver a intentarlo", start);
    }, el("div", "code", state.code));
  } else if (state.locked) {
    stateView("Hush está bloqueada", "Desbloquéala para ver tus contraseñas.", "Desbloquear Hush", async () => {
      await send({ type: "unlock" });
      window.close();
    });
  } else if (state.error) {
    stateView("Algo ha fallado", "Vuelve a abrir la extensión.", "Reintentar", start);
  } else {
    showVault();
  }
}

let rows = [];
let highlighted = 0;
let toastTimer;

async function showVault() {
  view.textContent = "";
  const search = el("input", "search");
  search.placeholder = "Buscar en Hush";
  search.autofocus = true;
  const section = el("div", "section");
  const list = el("div", "list");
  const toast = el("div", "toast");
  view.append(search, section, list, toast);

  const here = (await send({ type: "list" })).entries || [];

  function render(entries, title) {
    section.textContent = "";
    section.append(el("span", null, title), el("span", null, entries.length ? String(entries.length) : ""));
    list.textContent = "";
    rows = entries;
    highlighted = 0;
    if (!entries.length) {
      list.append(el("div", "empty", search.value ? `Nada coincide con «${search.value}»` : "No tienes cuentas de esta web. Búscala arriba."));
      return;
    }
    entries.forEach((entry, index) => list.append(row(entry, index)));
  }

  function row(entry, index) {
    const item = el("div", "row" + (index === highlighted ? " on" : ""));
    const badge = el("div", "badge", (entry.title || "?").trim().charAt(0).toUpperCase());
    const text = el("div", "text");
    text.append(el("div", "title", entry.title), el("div", "user", entry.user || "Sin usuario"));
    const actions = el("div", "actions");
    const copyUser = iconButton("user", "Copiar usuario");
    const copyPassword = iconButton("key", "Copiar contraseña");
    actions.append(copyUser, copyPassword);
    if (entry.totp) {
      const copyCode = iconButton("code", "Copiar código 2FA");
      copyCode.addEventListener("click", (event) => { event.stopPropagation(); copy(entry, "totp", "Código copiado"); });
      actions.append(copyCode);
    }
    copyUser.addEventListener("click", (event) => { event.stopPropagation(); copy(entry, "user", "Usuario copiado"); });
    copyPassword.addEventListener("click", (event) => { event.stopPropagation(); copy(entry, "password", "Contraseña copiada"); });
    item.title = "Rellenar en esta página";
    item.append(badge, text, actions);
    item.addEventListener("click", () => fill(entry));
    return item;
  }

  function say(message, error) {
    toast.textContent = message;
    toast.className = "toast" + (error ? " error" : "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (toast.textContent = ""), 2500);
  }

  async function copy(entry, field, message) {
    const reply = await send({ type: "copy", entry, field });
    say(reply.error ? "No se ha podido copiar" : message, !!reply.error);
  }

  async function fill(entry) {
    const reply = await send({ type: "fill", entry });
    if (reply.error === "no-page") return say("En esta página no se puede rellenar", true);
    if (reply.error) return say("No se ha podido rellenar", true);
    window.close();
  }

  let searchTimer;
  search.addEventListener("input", () => {
    clearTimeout(searchTimer);
    const query = search.value.trim();
    if (!query) return render(here, "En esta web");
    searchTimer = setTimeout(async () => {
      const reply = await send({ type: "search", query });
      if (search.value.trim() === query) render(reply.entries || [], "Resultados");
    }, 120);
  });

  search.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (!rows.length) return;
      highlighted = event.key === "ArrowDown" ? Math.min(highlighted + 1, rows.length - 1) : Math.max(highlighted - 1, 0);
      [...list.children].forEach((child, index) => child.classList.toggle("on", index === highlighted));
      list.children[highlighted]?.scrollIntoView({ block: "nearest" });
    } else if (event.key === "Enter" && rows[highlighted]) {
      fill(rows[highlighted]);
    }
  });

  render(here, "En esta web");
  search.focus();
}

start();
