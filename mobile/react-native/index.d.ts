export interface SmartBeeConsent {
  analytics: boolean;
  ads: boolean;
}

export interface SmartBeeOptions {
  /** Başlanğıc razılıq; verilməyibsə mənbənin konfiqindən götürülür. */
  consent?: SmartBeeConsent;
  /** Ətraflı nativ log. */
  debug?: boolean;
  /** `false` olarsa bütün avtomatik eventlər sönür. */
  autoEvents?: boolean;
  /** Yalnız test və ya proksi üçün. */
  endpoint?: string;
}

export type SmartBeeProps = Record<string, unknown>;

export interface SmartBeeApi {
  init(key: string, options?: SmartBeeOptions): Promise<void>;
  track(name: string, props?: SmartBeeProps | null, options?: { eventId?: string }): void;
  identify(userId: string, traits?: SmartBeeProps | null): void;
  screen(name: string, props?: SmartBeeProps | null): void;
  setConsent(consent: SmartBeeConsent): void;
  reset(): void;
  flush(): void;
  getAnonymousId(): Promise<string | null>;
}

export const VERSION: string;
export const SmartBee: SmartBeeApi;
export default SmartBee;
