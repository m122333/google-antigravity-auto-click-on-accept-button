'use strict';

const path = require('path');
const { disableDebugPort } = require('./argv');

try {
  disableDebugPort(path.resolve(__dirname, '..', '..', 'argv.json'));
} catch (error) {
  process.stderr.write(`Auto Click could not clean up argv.json: ${error.message}\n`);
}
