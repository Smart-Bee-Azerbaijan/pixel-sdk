'use strict';

// The React Native API of SmartBee Pixel. It holds no logic of its own: every call is forwarded to the native SDK.
// Written as CommonJS on purpose, so that Metro, Jest and CommonJS TypeScript consumers load it without a build step.

/** The project key format (spec/PROTOCOL.md, section 2). */
const KEY_RE = /^[a-z0-9]{8,16}$/;

/** Returns a plain JSON object that can cross the bridge, or null when the value cannot be converted. */
function jsonObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  try {
    // Functions, undefined and infinite / NaN numbers are dropped, a Date becomes an ISO string,
    // a circular reference or a BigInt throws (the whole object is then dropped).
    const copy = JSON.parse(JSON.stringify(value, (_key, item) => (typeof item === 'number' && !Number.isFinite(item) ? undefined : item)));
    return copy && typeof copy === 'object' && !Array.isArray(copy) ? copy : null;
  } catch (_error) {
    return null;
  }
}

/**
 * Creates the API object. The dependencies are injected so that the logic can be tested without React Native.
 *
 * @param {object|null|undefined} native the native module (`NativeModules.SmartBeePixel`)
 * @param {object} [deps]
 * @param {(message: string) => void} [deps.warn] receives warnings (normally `console.warn`)
 * @param {boolean} [deps.dev] development build (`__DEV__`): argument mistakes and swallowed errors are reported through `warn`
 * @param {string} [deps.version] the wrapper version
 * @param {string} [deps.platform] `Platform.OS`
 * @param {{ getInitialURL(): Promise<string|null>, addEventListener(type: string, handler: (event: { url: string }) => void): unknown }} [deps.linking]
 */
function createSmartBee(native, deps) {
  const d = deps && typeof deps === 'object' ? deps : {};
  const warn = typeof d.warn === 'function' ? d.warn : () => {};
  const dev = d.dev === true;
  const version = typeof d.version === 'string' ? d.version : '';
  const platform = typeof d.platform === 'string' ? d.platform : '';
  const linking = d.linking || null;

  let missingWarned = false;
  let initCalled = false;
  let linksWatched = false;

  /** A warning that must never break the app, even when the logger itself throws. */
  function say(message) {
    try {
      warn('[SmartBee] ' + message);
    } catch (_error) {
      // Nothing else can be done.
    }
  }

  /** Integration mistakes and swallowed errors: reported in development builds only. */
  function debug(message) {
    if (dev) say(message);
  }

  function available(method) {
    if (native && typeof native[method] === 'function') return true;
    if (!missingWarned) {
      missingWarned = true;
      say(
        'the native module is not linked, so every call is a no-op. This is expected in Expo Go, on the web and in Jest; ' +
          'in an app, rebuild it after installing the package (run "pod install" for iOS).'
      );
    }
    return false;
  }

  // A missing native module or a throwing native call never breaks the app.
  function call(method, ...args) {
    try {
      if (!available(method)) return undefined;
      return native[method](...args);
    } catch (error) {
      debug(method + ' failed: ' + (error && error.message ? error.message : String(error)));
      return undefined;
    }
  }

  /** A non-empty string, or null (with a development warning) for anything else. */
  function name(value, what) {
    if (typeof value === 'string' && value !== '') return value;
    debug(what + ' must be a non-empty string; the call is ignored');
    return null;
  }

  /** Optional properties: an object is cleaned, null / undefined is fine, anything else is dropped with a warning. */
  function props(value, what) {
    if (value === null || value === undefined) return null;
    const cleaned = jsonObject(value);
    if (cleaned === null) debug(what + ' must be a plain JSON-serializable object; it is dropped');
    return cleaned;
  }

  /**
   * Consent fails closed: a purpose that is not an explicit boolean is treated as `false`.
   * Returns null when `value` is not an object at all.
   */
  function closedConsent(value, where) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
    const analytics = typeof value.analytics === 'boolean';
    const ads = typeof value.ads === 'boolean';
    if (!analytics || !ads) {
      say(where + ': consent needs boolean "analytics" and "ads"; the missing one is treated as false');
    }
    return { analytics: analytics ? value.analytics : false, ads: ads ? value.ads : false };
  }

  // In a wrapper the native SDK does not observe links itself (on iOS it cannot, on Android JavaScript starts after
  // the launch intent was delivered): on both platforms they are forwarded from React Native's Linking module.
  function watchLinks() {
    if (linksWatched || (platform !== 'ios' && platform !== 'android') || !linking || !native || typeof native.handleDeepLink !== 'function') return;
    linksWatched = true;
    // Linking.getInitialURL() keeps returning the launch link for as long as the process lives, also after a
    // JavaScript reload. The native side remembers which launch link was already reported and skips the repeat.
    const initial = typeof native.handleInitialLink === 'function' ? 'handleInitialLink' : 'handleDeepLink';
    try {
      Promise.resolve(linking.getInitialURL()).then(
        (url) => {
          if (typeof url === 'string' && url) call(initial, url);
        },
        () => {}
      );
      linking.addEventListener('url', (event) => {
        const url = event && event.url;
        if (typeof url === 'string' && url) call('handleDeepLink', url);
      });
    } catch (_error) {
      // Without Linking, links are simply not observed; handleDeepLink() still works.
    }
  }

  return {
    /** The SDK version (the wrapper and the native cores it contains are released together). */
    sdkVersion: version,

    /**
     * Starts the SDK. Resolves to `true` when the call was handed to the native SDK, `false` otherwise; never rejects.
     * A repeated call is passed on to the native SDK, which only applies its more restrictive options.
     */
    init(key, options) {
      try {
        if (!available('start')) return Promise.resolve(false);
        if (typeof key !== 'string' || !KEY_RE.test(key)) {
          say('init: the key must match ^[a-z0-9]{8,16}$; the SDK is not started');
          return Promise.resolve(false);
        }
        if (options !== undefined && options !== null && (typeof options !== 'object' || Array.isArray(options))) {
          debug('init: options must be an object; defaults are used');
        }
        const o = options && typeof options === 'object' && !Array.isArray(options) ? options : {};
        let consent = null;
        if (o.consent !== undefined && o.consent !== null) {
          consent = closedConsent(o.consent, 'init');
          if (consent === null) {
            say('init: consent must be an object { analytics, ads }; both purposes are treated as false');
            consent = { analytics: false, ads: false };
          }
        }
        if (initCalled) {
          say(
            'init was already called. Initialise in one place: the key and options of the first call stay in effect, ' +
              'only stricter consent and collectAdvertisingId=false from this call are applied.'
          );
        }
        native.start(key, {
          debug: o.debug === true,
          autoEvents: o.autoEvents !== false,
          endpoint: typeof o.endpoint === 'string' && o.endpoint ? o.endpoint : null,
          consent,
          // Only an explicit `false` turns it off; anything else (absent, not a boolean) means the default `true`.
          collectAdvertisingId: o.collectAdvertisingId !== false,
          wrapperVersion: version,
        });
        initCalled = true;
        if (o.autoEvents !== false) watchLinks();
        return Promise.resolve(true);
      } catch (error) {
        debug('init failed: ' + (error && error.message ? error.message : String(error)));
        return Promise.resolve(false);
      }
    },

    /**
     * Records an event. `options.eventId` is your own id for de-duplication with server-side events; a finite number
     * (an order number) is sent as its decimal string, any other non-string value is dropped with a development warning.
     */
    track(eventName, eventProps, options) {
      const checked = name(eventName, 'track: the event name');
      if (checked === null) return;
      const raw = options && typeof options === 'object' ? options.eventId : undefined;
      let eventId = null;
      if (typeof raw === 'string') eventId = raw;
      else if (typeof raw === 'number' && Number.isFinite(raw)) eventId = String(raw);
      else if (raw !== undefined && raw !== null) debug('track: eventId must be a string or a finite number; it is dropped');
      call('track', checked, props(eventProps, 'track: props'), eventId);
    },

    /** Identifies the user. `email` and `phone` traits are hashed with SHA-256 on the device. */
    identify(userId, traits) {
      // A numeric id is accepted for convenience and sent as its decimal string.
      const id = typeof userId === 'number' && Number.isFinite(userId) ? String(userId) : userId;
      const checked = name(id, 'identify: the user id');
      if (checked === null) return;
      call('identify', checked, props(traits, 'identify: traits'));
    },

    /** Records a screen view. */
    screen(screenName, screenProps) {
      const checked = name(screenName, 'screen: the screen name');
      if (checked === null) return;
      call('screen', checked, props(screenProps, 'screen: props'));
    },

    /**
     * Changes and stores consent. A purpose that is not an explicit boolean is treated as `false` (with a warning);
     * a call without an object is ignored.
     */
    setConsent(consent) {
      const closed = closedConsent(consent, 'setConsent');
      if (closed === null) {
        say('setConsent: expected an object { analytics, ads }; the call is ignored');
        return;
      }
      call('setConsent', closed.analytics, closed.ads);
    },

    /** Sign-out: the user is cleared and a new anonymous id is generated. */
    reset() {
      call('reset');
    },

    /** Sends the queue now. */
    flush() {
      call('flush');
    },

    /**
     * Reports a deep link that opened the app. Links from React Native's `Linking` module are forwarded automatically
     * (unless `autoEvents` is `false`); use this for links that reach the app another way.
     */
    handleDeepLink(url) {
      const checked = name(url, 'handleDeepLink: the url');
      if (checked === null) return;
      call('handleDeepLink', checked);
    },

    /** The current anonymous id; null when the SDK has not started yet or analytics consent is missing. */
    async getAnonymousId() {
      try {
        const value = await call('getAnonymousId');
        return typeof value === 'string' ? value : null;
      } catch (error) {
        debug('getAnonymousId failed: ' + (error && error.message ? error.message : String(error)));
        return null;
      }
    },
  };
}

exports.createSmartBee = createSmartBee;
