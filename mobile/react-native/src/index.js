'use strict';

const { Linking, NativeModules, Platform } = require('react-native');
const { createSmartBee } = require('./api.js');

/*
The version is read from package.json, so it cannot drift from the published package. The release script
(mobile/release.mjs) still expects the version in this file in the form below and rewrites it on every release;
a test checks that it equals package.json. Keep the next line exactly in this shape:
export const VERSION = '1.0.0'
*/
const VERSION = require('../package.json').version;

const SmartBee = createSmartBee(NativeModules.SmartBeePixel, {
  // eslint-disable-next-line no-console
  warn: (message) => console.warn(message),
  // eslint-disable-next-line no-undef
  dev: typeof __DEV__ !== 'undefined' && __DEV__ === true,
  version: VERSION,
  platform: Platform.OS,
  linking: Linking,
});

// `import SmartBee from '@smartbee/pixel'`, `import { SmartBee } from '@smartbee/pixel'` (Babel / TypeScript interop)
// and `const { SmartBee } = require('@smartbee/pixel')` all work.
module.exports = { __esModule: true, default: SmartBee, SmartBee, VERSION };
