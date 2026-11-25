import { Linking, NativeModules, Platform } from 'react-native';
import { createSmartBee } from './api.js';

/** package.json-dakı versiya ilə eyni olmalıdır (testlə yoxlanır). */
export const VERSION = '1.0.0';

const SmartBee = createSmartBee(NativeModules.SmartBeePixel, {
  // eslint-disable-next-line no-console
  warn: (message) => console.warn(message),
  version: VERSION,
  platform: Platform.OS,
  linking: Linking,
});

export default SmartBee;
export { SmartBee };
