/** Consent state for the two purposes the SDK distinguishes. */
export interface SmartBeeConsent {
  /** When `false` nothing is collected, stored or sent, and the queue and all identifiers are erased. */
  analytics: boolean;
  /** When `false` events are still sent, but no advertising / device identifier or click id leaves the device. */
  ads: boolean;
}

export interface SmartBeeOptions {
  /**
   * Consent stated by the app at start. When omitted, a choice stored by an earlier `setConsent` applies, and
   * otherwise the default of the key's remote configuration. When both this value and a stored choice exist, the
   * more restrictive one wins for each purpose.
   *
   * Consent fails closed: if the object is incomplete, the missing purpose is treated as `false`.
   */
  consent?: SmartBeeConsent;
  /** Verbose native logging (Logcat tag `SmartBee`, Xcode console prefix `[SmartBee]`). */
  debug?: boolean;
  /** `false` turns every automatic event off and stops the automatic forwarding of deep links. */
  autoEvents?: boolean;
  /** Base URL of the collection server; only for tests or a first-party proxy. */
  endpoint?: string;
  /**
   * Advertising identifier (Android: GAID; iOS: IDFA, together with the vendor identifier and the tracking
   * permission status). Default `true`: read only while advertising consent is given and, on iOS, sent only when the
   * user has authorized tracking (ATT). `false`: never read.
   */
  collectAdvertisingId?: boolean;
}

export type SmartBeeProps = Record<string, unknown>;

export interface SmartBeeApi {
  /** The SDK version (the wrapper and the native cores it contains are released together). */
  readonly sdkVersion: string;
  /**
   * Starts the SDK. Call it once, in one place, as early as possible.
   *
   * Resolves to `true` when the wrapper accepted the call and handed it to the native SDK (native module present,
   * key well-formed), and to `false` otherwise; it never rejects. `true` does not mean the SDK has finished starting
   * (start-up is asynchronous, so `getAnonymousId()` may still resolve to `null` right afterwards), nor that it will:
   * in a process of a multi-process Android app that is not the main process the SDK stays disabled.
   *
   * A repeated call does not restart the SDK or change the key; only the more restrictive parts of its options are
   * applied (purposes set to `false` in `consent`, and `collectAdvertisingId: false`), and a warning is logged.
   */
  init(key: string, options?: SmartBeeOptions): Promise<boolean>;
  /**
   * Records an event. A name that is not a non-empty string is ignored (with a warning in development builds).
   * `options.eventId` is your own id for de-duplication with server-side events (for example an order number); a
   * finite number is sent as its decimal string.
   */
  track(name: string, props?: SmartBeeProps | null, options?: { eventId?: string | number }): void;
  /**
   * Identifies the user. `email` and `phone` traits are hashed with SHA-256 on the device. A finite numeric id is
   * sent as its decimal string.
   */
  identify(userId: string | number, traits?: SmartBeeProps | null): void;
  /** Records a screen view. Call it from your navigation library's state-change listener. */
  screen(name: string, props?: SmartBeeProps | null): void;
  /**
   * Changes and stores consent. Fails closed: a purpose that is not an explicit boolean is treated as `false`
   * (with a warning). A call without an object is ignored.
   */
  setConsent(consent: SmartBeeConsent): void;
  /** Sign-out: the user is cleared and a new anonymous id and session are created. */
  reset(): void;
  /** Sends the queue now instead of waiting for the next periodic flush. */
  flush(): void;
  /**
   * Reports a deep link that opened the app. Links delivered by React Native's `Linking` module are forwarded
   * automatically unless `autoEvents` is `false`; call this for links that reach the app another way, or when
   * automatic events are off. Only `http`, `https` and `scheme://…` URLs up to 4096 characters are counted.
   */
  handleDeepLink(url: string): void;
  /**
   * The current anonymous id, or `null` when the SDK has not finished starting, analytics consent is missing or not
   * known yet, or the native module is not linked.
   */
  getAnonymousId(): Promise<string | null>;
}

/** The version of this package. */
export const VERSION: string;
export const SmartBee: SmartBeeApi;
export default SmartBee;
