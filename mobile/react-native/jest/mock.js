'use strict';

// A Jest mock of @smartbee/pixel for the unit tests of an app. The real package needs the native module, which does
// not exist in Jest (there every call is a no-op with one warning). Use it like this:
//
//   jest.mock('@smartbee/pixel', () => require('@smartbee/pixel/jest/mock'));
//
// Every method is a jest.fn(), so calls can be asserted: expect(SmartBee.track).toHaveBeenCalledWith('Purchase', ...).

// eslint-disable-next-line no-undef
const fn = typeof jest !== 'undefined' && jest && typeof jest.fn === 'function' ? (impl) => jest.fn(impl) : (impl) => impl;

const VERSION = require('../package.json').version;

const SmartBee = {
  sdkVersion: VERSION,
  init: fn(() => Promise.resolve(true)),
  track: fn(() => {}),
  identify: fn(() => {}),
  screen: fn(() => {}),
  setConsent: fn(() => {}),
  reset: fn(() => {}),
  flush: fn(() => {}),
  handleDeepLink: fn(() => {}),
  getAnonymousId: fn(() => Promise.resolve(null)),
};

module.exports = { __esModule: true, default: SmartBee, SmartBee, VERSION };
