// SmartBee Pixel-in React Native API-si. Öz məntiqi yoxdur: hər çağırış nativ SDK-ya ötürülür.

/** Körpüdən keçə bilən təmiz JSON obyekti qaytarır; alınmırsa null. */
function jsonObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  try {
    // Funksiyalar, undefined və sonsuz / NaN ədədlər atılır, Date ISO sətirinə çevrilir,
    // dövri istinad və BigInt xəta verir (bu halda bütün obyekt atılır).
    const copy = JSON.parse(JSON.stringify(value, (_key, item) => (typeof item === 'number' && !Number.isFinite(item) ? undefined : item)));
    return copy && typeof copy === 'object' && !Array.isArray(copy) ? copy : null;
  } catch {
    return null;
  }
}

/**
 * @param {object|null|undefined} native nativ modul (`NativeModules.SmartBeePixel`)
 * @param {object} [deps]
 * @param {(message: string) => void} [deps.warn]
 * @param {string} [deps.version] örtüyün versiyası
 * @param {string} [deps.platform] `Platform.OS`
 * @param {{ getInitialURL(): Promise<string|null>, addEventListener(type: string, handler: (event: { url: string }) => void): unknown }} [deps.linking]
 */
export function createSmartBee(native, { warn = () => {}, version = '', platform = '', linking = null } = {}) {
  let warned = false;
  let linksWatched = false;

  // Nativ modul qoşulmayıbsa və ya çağırış xəta verərsə tətbiq sınmır.
  function call(method, ...args) {
    try {
      if (!native || typeof native[method] !== 'function') {
        if (!warned) {
          warned = true;
          warn('[SmartBee] nativ modul qoşulmayıb; çağırışlar nəzərə alınmır');
        }
        return undefined;
      }
      return native[method](...args);
    } catch {
      return undefined;
    }
  }

  const text = (value) => (typeof value === 'string' ? value : value === null || value === undefined ? '' : String(value));

  // iOS-da nativ SDK keçidləri özü tuta bilmir; React Native-in Linking modulu ilə ötürülür.
  // Android-də nativ SDK Activity intent-indən özü oxuyur, ona görə burada təkrarlanmır.
  function watchLinks() {
    if (linksWatched || platform !== 'ios' || !linking || !native || typeof native.handleDeepLink !== 'function') return;
    linksWatched = true;
    const forward = (url) => {
      if (typeof url === 'string' && url) call('handleDeepLink', url);
    };
    try {
      Promise.resolve(linking.getInitialURL()).then(forward, () => {});
      linking.addEventListener('url', (event) => forward(event && event.url));
    } catch {
      // Linking əlçatmazdırsa keçidlər sadəcə izlənmir.
    }
  }

  return {
    /** SDK-nı başladır. Təkrar çağırış nəzərə alınmır. */
    init(key, options) {
      const o = options && typeof options === 'object' ? options : {};
      const consent =
        o.consent && typeof o.consent.analytics === 'boolean' && typeof o.consent.ads === 'boolean'
          ? { analytics: o.consent.analytics, ads: o.consent.ads }
          : null;
      call('start', text(key), {
        debug: o.debug === true,
        autoEvents: o.autoEvents !== false,
        endpoint: typeof o.endpoint === 'string' && o.endpoint ? o.endpoint : null,
        consent,
        wrapperVersion: version,
      });
      if (o.autoEvents !== false) watchLinks();
      return Promise.resolve();
    },

    /** Event göndərir. `options.eventId` server tərəfi ilə dedup üçündür. */
    track(name, props, options) {
      const eventId = options && typeof options.eventId === 'string' ? options.eventId : null;
      call('track', text(name), jsonObject(props), eventId);
    },

    /** İstifadəçini tanıdır. `email` və `phone` cihazda SHA-256 ilə hash olunur. */
    identify(userId, traits) {
      call('identify', text(userId), jsonObject(traits));
    },

    /** Ekran baxışı. */
    screen(name, props) {
      call('screen', text(name), jsonObject(props));
    },

    /** Razılığı dəyişir. Hər iki dəyər boolean olmalıdır; əks halda çağırış nəzərə alınmır. */
    setConsent(consent) {
      if (!consent || typeof consent.analytics !== 'boolean' || typeof consent.ads !== 'boolean') {
        warn('[SmartBee] setConsent: analytics və ads boolean olmalıdır');
        return;
      }
      call('setConsent', consent.analytics, consent.ads);
    },

    /** Çıxış: istifadəçi silinir, yeni anonim ID yaradılır. */
    reset() {
      call('reset');
    },

    /** Növbəni dərhal göndərir. */
    flush() {
      call('flush');
    },

    /** Cari anonim ID; SDK başlamayıbsa və ya razılıq yoxdursa null. */
    async getAnonymousId() {
      try {
        const value = await call('getAnonymousId');
        return typeof value === 'string' ? value : null;
      } catch {
        return null;
      }
    },
  };
}
