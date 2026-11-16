// Hush: relé entre page.js (mundo de la página) y la extensión para las claves de acceso.
// Solo acepta mensajes de la propia ventana y de su mismo origen; la extensión vuelve a comprobar
// el origen con la dirección que da el navegador.
(() => {
  if (window.top !== window) return;
  const api = globalThis.browser ?? globalThis.chrome;
  const CHANNEL = "hush-passkey";
  let busy = false;

  window.addEventListener("message", async (event) => {
    if (event.source !== window || event.origin !== location.origin) return;
    const data = event.data;
    if (data?.channel !== CHANNEL || data.direction !== "to-extension") return;
    if (data.type !== "passkey-create" && data.type !== "passkey-get") return;
    let reply;
    // Una petición a la vez: una página no puede amontonar confirmaciones en Hush.
    if (busy) {
      reply = { error: "busy" };
    } else {
      busy = true;
      try {
        reply = await api.runtime.sendMessage({ type: data.type, options: data.options });
      } catch {
        reply = { error: "offline" };
      } finally {
        busy = false;
      }
    }
    window.postMessage({ channel: CHANNEL, direction: "to-page", id: data.id, reply }, location.origin);
  });
})();
