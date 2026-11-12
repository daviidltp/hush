// Hush: claves de acceso (passkeys). Corre en el mundo de la página para poder atender navigator.credentials.
// Solo hace de mensajero: el origen lo pone el navegador en la extensión y Hush pide confirmación.
// Si Hush no tiene la clave, no está conectado o no puede, sigue el navegador como siempre.
(() => {
  if (window.top !== window || !navigator.credentials || typeof PublicKeyCredential === "undefined") return;

  const CHANNEL = "hush-passkey";
  const credentials = navigator.credentials;
  const original = { create: credentials.create.bind(credentials), get: credentials.get.bind(credentials) };
  const waiting = new Map();
  let next = 1;

  window.addEventListener("message", (event) => {
    if (event.source !== window || event.origin !== location.origin) return;
    const data = event.data;
    if (data?.channel !== CHANNEL || data.direction !== "to-page") return;
    const resolve = waiting.get(data.id);
    if (resolve) {
      waiting.delete(data.id);
      resolve(data.reply);
    }
  });

  function ask(type, options) {
    return new Promise((resolve) => {
      const id = `${next++}-${Math.random().toString(36).slice(2)}`;
      waiting.set(id, resolve);
      window.postMessage({ channel: CHANNEL, direction: "to-extension", id, type, options }, location.origin);
      // Si nadie contesta (extensión desactivada a medias), se devuelve el control al navegador.
      setTimeout(() => {
        if (waiting.delete(id)) resolve({ error: "timeout" });
      }, 130000);
    });
  }

  // MARK: Conversión de datos

  function bytes(value) {
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    return null;
  }

  function encode(value) {
    const data = bytes(value);
    if (!data) return typeof value === "string" ? value : "";
    let text = "";
    for (const byte of data) text += String.fromCharCode(byte);
    return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function decode(text) {
    const base = text.replace(/-/g, "+").replace(/_/g, "/");
    const raw = atob(base + "===".slice((base.length + 3) % 4));
    const out = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out.buffer;
  }

  const descriptors = (list) => (Array.isArray(list) ? list.map((item) => ({ id: encode(item.id), type: item.type })) : []);

  function createOptions(pk) {
    return {
      challenge: encode(pk.challenge),
      rp: { id: pk.rp?.id, name: pk.rp?.name },
      user: { id: encode(pk.user?.id), name: pk.user?.name, displayName: pk.user?.displayName },
      pubKeyCredParams: Array.isArray(pk.pubKeyCredParams) ? pk.pubKeyCredParams.map((p) => ({ type: p.type, alg: p.alg })) : [],
      excludeCredentials: descriptors(pk.excludeCredentials),
    };
  }

  function getOptions(pk) {
    return { challenge: encode(pk.challenge), rpId: pk.rpId, allowCredentials: descriptors(pk.allowCredentials) };
  }

  // MARK: Respuestas con la forma de las del navegador

  function define(target, values) {
    for (const [key, value] of Object.entries(values)) {
      Object.defineProperty(target, key, { value, enumerable: typeof value !== "function", configurable: true });
    }
    return target;
  }

  function credential(reply, response, responseJSON, extensions) {
    const json = {
      id: reply.id, rawId: reply.id, type: "public-key", authenticatorAttachment: "platform",
      response: responseJSON, clientExtensionResults: extensions,
    };
    return define(Object.create(PublicKeyCredential.prototype), {
      id: reply.id,
      rawId: decode(reply.id),
      type: "public-key",
      authenticatorAttachment: "platform",
      response,
      getClientExtensionResults: () => extensions,
      toJSON: () => json,
    });
  }

  function registration(reply, pk) {
    const transports = ["hybrid", "internal"];
    const response = define(Object.create(AuthenticatorAttestationResponse.prototype), {
      clientDataJSON: decode(reply.clientDataJSON),
      attestationObject: decode(reply.attestationObject),
      getTransports: () => transports.slice(),
      getAuthenticatorData: () => decode(reply.authenticatorData),
      getPublicKey: () => decode(reply.publicKey),
      getPublicKeyAlgorithm: () => reply.publicKeyAlgorithm,
    });
    const json = {
      clientDataJSON: reply.clientDataJSON, attestationObject: reply.attestationObject, transports,
      authenticatorData: reply.authenticatorData, publicKey: reply.publicKey, publicKeyAlgorithm: reply.publicKeyAlgorithm,
    };
    const extensions = pk.extensions?.credProps ? { credProps: { rk: true } } : {};
    return credential(reply, response, json, extensions);
  }

  function assertion(reply) {
    const response = define(Object.create(AuthenticatorAssertionResponse.prototype), {
      clientDataJSON: decode(reply.clientDataJSON),
      authenticatorData: decode(reply.authenticatorData),
      signature: decode(reply.signature),
      userHandle: reply.userHandle ? decode(reply.userHandle) : null,
    });
    const json = {
      clientDataJSON: reply.clientDataJSON, authenticatorData: reply.authenticatorData,
      signature: reply.signature, userHandle: reply.userHandle || undefined,
    };
    return credential(reply, response, json, {});
  }

  function failure(reply) {
    switch (reply?.error) {
      case "cancelled": return new DOMException("The operation either timed out or was not allowed.", "NotAllowedError");
      case "exists": return new DOMException("The authenticator already contains one of the credentials.", "InvalidStateError");
      case "security": return new DOMException("The relying party ID is not a registrable domain suffix of the origin.", "SecurityError");
      default: return null;
    }
  }

  // MARK: navigator.credentials

  credentials.create = async function create(options) {
    const pk = options?.publicKey;
    if (!pk) return original.create(options);
    const reply = await ask("passkey-create", createOptions(pk));
    const error = failure(reply);
    if (error) throw error;
    if (!reply || reply.error) return original.create(options);
    return registration(reply, pk);
  };

  credentials.get = async function get(options) {
    const pk = options?.publicKey;
    // El autorrelleno de passkeys del navegador («conditional») sigue siendo suyo.
    if (!pk || options.mediation === "conditional") return original.get(options);
    const reply = await ask("passkey-get", getOptions(pk));
    const error = failure(reply);
    if (error) throw error;
    if (!reply || reply.error) return original.get(options);
    return assertion(reply);
  };
})();
